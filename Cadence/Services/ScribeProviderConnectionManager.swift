import Foundation

enum ScribeProviderConnectionError: Error, Equatable {
    case validationFailed
    case securityDecisionRequired
    case consentRequired
    case retainedStoreUnreadable
    case staleAttempt
    case persistenceFailed
    case publicationFailed
    case activeActionConfirmationRequired
}

@MainActor
final class ScribeProviderConnectionManager {
    typealias Validator = @Sendable (
        ScribeProviderCandidateConfiguration,
        String
    ) async throws -> Void

    private let configurationStore: any ScribeProviderConfigurationPersisting
    private let credentialStore: any ScribeCredentialStoring

    init(
        configurationStore: any ScribeProviderConfigurationPersisting,
        credentialStore: any ScribeCredentialStoring
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
    }

    func connect(
        candidate: ScribeProviderCandidateConfiguration,
        credential: String,
        validate: Validator
    ) async throws -> ScribeProviderConfiguration {
        try await validate(candidate, credential)
        try Task.checkCancellation()

        let oldConfiguration: ScribeProviderConfiguration?
        if case let .valid(configuration) = configurationStore.load() {
            oldConfiguration = configuration
        } else {
            oldConfiguration = nil
        }

        let stagedReference = try credentialStore.stage(credential)
        let connected = candidate.persisted(credentialReference: stagedReference)
        do {
            try Task.checkCancellation()
            try configurationStore.save(connected)
        } catch {
            try? credentialStore.delete(reference: stagedReference)
            throw error
        }

        if let oldReference = oldConfiguration?.credentialReference,
           oldReference != stagedReference {
            try? credentialStore.delete(reference: oldReference)
        }
        return connected
    }

    func removeProvider() throws {
        let activeReference: ScribeCredentialReference?
        if case let .valid(configuration) = configurationStore.load() {
            activeReference = configuration.credentialReference
        } else {
            activeReference = nil
        }
        try configurationStore.save(nil)
        if let activeReference {
            try credentialStore.delete(reference: activeReference)
        }
    }

    func removeUnreferencedCredentials() throws {
        let activeReference: ScribeCredentialReference?
        switch configurationStore.load() {
        case let .valid(configuration):
            activeReference = configuration.credentialReference
        case .absent:
            activeReference = nil
        case .rejected:
            return
        }
        for reference in try credentialStore.allReferences() where reference != activeReference {
            try credentialStore.delete(reference: reference)
        }
    }
}

struct ScribeProviderConnectionCandidate: Equatable, Sendable {
    let id: UUID
    let kind: ScribeProviderKind
    let displayName: String
    let normalizedOrigin: String
    let baseURL: URL
    let requestURL: URL
    let selectedModelID: String
    let catalogID: String?
    let consentReceipt: ScribeProviderConsentReceipt
    let acceptedAt: Date

    var hasValidMaterialConsent: Bool {
        guard consentReceipt.providerKind == kind,
              consentReceipt.recipientOrigin == normalizedOrigin,
              consentReceipt.disclosureRevision == ScribeProviderDisclosure.currentVersion else {
            return false
        }
        switch kind {
        case .openAIDirect:
            return consentReceipt.routingPolicy == .directSingleModel
                && consentReceipt.retentionPolicy == .requestStorageDisabled
                && consentReceipt.dataPolicy == .providerPolicyApplies
        case .openRouter:
            return consentReceipt.routingPolicy == .zeroDataRetentionSingleModel
                && consentReceipt.retentionPolicy == .zeroDataRetentionRequired
                && consentReceipt.dataPolicy == .collectionDenied
        case .deepSeek, .advanced:
            return consentReceipt.routingPolicy == .providerControlledSingleModel
                && consentReceipt.retentionPolicy == .providerControlled
                && consentReceipt.dataPolicy == .providerControlled
        case .legacyLocal:
            return false
        }
    }

    func configuration(
        reference: ScribeStoredCredentialReference,
        validatedAt: Date
    ) throws -> ScribeProviderLibraryConfiguration {
        try ScribeProviderLibraryConfiguration(
            id: id,
            kind: kind,
            displayName: displayName,
            normalizedOrigin: normalizedOrigin,
            baseURL: baseURL,
            requestURL: requestURL,
            selectedModelID: selectedModelID,
            catalogID: catalogID,
            disclosureVersion: consentReceipt.disclosureRevision,
            acceptedAt: acceptedAt,
            lastValidatedAt: validatedAt,
            credentialReference: reference.opaqueReference,
            isEnabled: true,
            credentialStorageDomain: reference.domain,
            consentReceipt: consentReceipt
        )
    }
}

actor ScribeProviderTransactionMutex {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var locked = false
    private var waiters: [Waiter] = []

    func lock() async throws {
        try Task.checkCancellation()
        if !locked { locked = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

actor ScribeProviderV2ConnectionManager {
    typealias Validator = @Sendable (
        ScribeProviderConnectionCandidate,
        String
    ) async throws -> Void
    typealias LibraryPublisher = @Sendable (ScribeProviderLibrary) async throws -> Void
    typealias CommittedFallbackPublisher = @Sendable (ScribeProviderLibrary) async -> Void

    private let libraryStore: any ScribeProviderLibraryPersisting
    private let vault: any ScribeCredentialVaulting
    private let consentAuthority: ScribeProviderConsentAuthority
    private let reconciler: ScribeCredentialReconciler
    private let inheritedAccessibilityAccepted: Bool
    private let publisher: LibraryPublisher
    private let committedFallbackPublisher: CommittedFallbackPublisher
    private let mutex = ScribeProviderTransactionMutex()
    private var currentAttempt: UUID?
    private(set) var publishedLibrary: ScribeProviderLibrary?

    init(
        libraryStore: any ScribeProviderLibraryPersisting,
        vault: any ScribeCredentialVaulting,
        consentAuthority: ScribeProviderConsentAuthority,
        reconciler: ScribeCredentialReconciler,
        inheritedAccessibilityAccepted: Bool,
        publisher: @escaping LibraryPublisher,
        committedFallbackPublisher: @escaping CommittedFallbackPublisher
    ) {
        self.libraryStore = libraryStore
        self.vault = vault
        self.consentAuthority = consentAuthority
        self.reconciler = reconciler
        self.inheritedAccessibilityAccepted = inheritedAccessibilityAccepted
        self.publisher = publisher
        self.committedFallbackPublisher = committedFallbackPublisher
    }

    func connectValidated(
        candidate: ScribeProviderConnectionCandidate,
        credential: String,
        proof: ScribeModelValidationProof,
        setupRevision: Int,
        attemptFence: @escaping @Sendable () async -> Bool,
        consumeProof: @escaping @Sendable () async -> Bool
    ) async throws -> ScribeProviderLibraryConfiguration {
        guard candidate.kind == .openAIDirect || candidate.kind == .openRouter,
              proof.matches(candidate, setupRevision: setupRevision),
              await attemptFence(),
              await consumeProof() else {
            throw ScribeProviderConnectionError.validationFailed
        }
        return try await connectCore(
            candidate: candidate,
            credential: credential,
            attemptFence: attemptFence,
            validate: nil
        )
    }

    func connect(
        candidate: ScribeProviderConnectionCandidate,
        credential: String,
        attemptFence: @escaping @Sendable () async -> Bool = { true },
        validate: @escaping Validator
    ) async throws -> ScribeProviderLibraryConfiguration {
        guard candidate.kind != .openAIDirect && candidate.kind != .openRouter else {
            throw ScribeProviderConnectionError.validationFailed
        }
        return try await connectCore(
            candidate: candidate,
            credential: credential,
            attemptFence: attemptFence,
            validate: validate
        )
    }

    private func connectCore(
        candidate: ScribeProviderConnectionCandidate,
        credential: String,
        attemptFence: @escaping @Sendable () async -> Bool,
        validate: Validator?
    ) async throws -> ScribeProviderLibraryConfiguration {
        guard inheritedAccessibilityAccepted else {
            throw ScribeProviderConnectionError.securityDecisionRequired
        }
        guard await consentAuthority.verify(candidate.consentReceipt),
              candidate.hasValidMaterialConsent else {
            throw ScribeProviderConnectionError.consentRequired
        }
        let attempt = UUID()
        currentAttempt = attempt
        guard await attemptFence() else { throw ScribeProviderConnectionError.staleAttempt }
        if let validate { try await validate(candidate, credential) }
        try Task.checkCancellation()
        guard currentAttempt == attempt, await attemptFence() else {
            throw ScribeProviderConnectionError.staleAttempt
        }

        try await mutex.lock()
        do {
            try Task.checkCancellation()
            guard currentAttempt == attempt, await attemptFence() else {
                throw ScribeProviderConnectionError.staleAttempt
            }
            let result = try await commitLocked(
                attempt: attempt,
                candidate: candidate,
                credential: credential,
                attemptFence: attemptFence
            )
            await mutex.unlock()
            return result
        } catch {
            await mutex.unlock()
            throw error
        }
    }

    func cancelCurrentAttempt() async {
        currentAttempt = nil
        await consentAuthority.revokeAllEphemeral()
    }

    private func commitLocked(
        attempt: UUID,
        candidate: ScribeProviderConnectionCandidate,
        credential: String,
        attemptFence: @escaping @Sendable () async -> Bool
    ) async throws -> ScribeProviderLibraryConfiguration {
        try Task.checkCancellation()
        guard currentAttempt == attempt, await attemptFence() else {
            throw ScribeProviderConnectionError.staleAttempt
        }
        guard case .available = await reconciler.protectedReferences() else {
            throw ScribeProviderConnectionError.retainedStoreUnreadable
        }
        let staged = try await vault.stageCandidate(credential)
        do {
            try Task.checkCancellation()
            guard currentAttempt == attempt, await attemptFence() else {
                throw ScribeProviderConnectionError.staleAttempt
            }
            let previous: ScribeProviderLibrary
            switch libraryStore.load() {
            case .absent: previous = ScribeProviderLibrary(revision: 0, configurations: [], activeConfigurationID: nil)
            case let .valid(library): previous = library
            case .rejected: throw ScribeProviderConnectionError.retainedStoreUnreadable
            }
            let connected = try candidate.configuration(reference: staged, validatedAt: Date())
            guard ScribeProviderLibraryConfigurationValidator.isValid(connected) else {
                throw ScribeProviderConnectionError.validationFailed
            }
            let replaced = previous.configurations.filter { $0.kind != candidate.kind }
            let candidateLibrary = ScribeProviderLibrary(
                revision: previous.revision + 1,
                configurations: replaced + [connected],
                activeConfigurationID: connected.id
            )
            try Task.checkCancellation()
            guard currentAttempt == attempt, await attemptFence() else {
                throw ScribeProviderConnectionError.staleAttempt
            }
            try libraryStore.save(candidateLibrary)
            guard case let .valid(reloaded) = libraryStore.load(),
                  reloaded.semanticallyEquals(candidateLibrary) else {
                throw ScribeProviderConnectionError.persistenceFailed
            }
            try Task.checkCancellation()
            guard currentAttempt == attempt, await attemptFence() else {
                throw ScribeProviderConnectionError.staleAttempt
            }
            try await publisher(reloaded)
            publishedLibrary = reloaded
            if !(await consentAuthority.commit(candidate.consentReceipt)) {
                await consentAuthority.bootstrap(from: reloaded)
                guard await consentAuthority.verify(candidate.consentReceipt) else {
                    throw ScribeProviderConnectionError.publicationFailed
                }
            }
            currentAttempt = nil
            for old in previous.configurations.map(\.storedCredentialReference)
                where !reloaded.configurations.map(\.storedCredentialReference).contains(old) {
                try await reconciler.deleteIfUnreferenced(old)
            }
            try await reconciler.reconcile()
            return connected
        } catch {
            if case .valid = libraryStore.load() {
                // A committed candidate must retain its key; reload is the publication fallback.
                if case let .valid(reloaded) = libraryStore.load(),
                   reloaded.configurations.contains(where: { $0.storedCredentialReference == staged }) {
                    publishedLibrary = reloaded
                    await consentAuthority.bootstrap(from: reloaded)
                    await committedFallbackPublisher(reloaded)
                    throw error
                }
            }
            try? await vault.delete(staged)
            throw error
        }
    }
}
