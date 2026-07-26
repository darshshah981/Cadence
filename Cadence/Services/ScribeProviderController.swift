import Foundation

@MainActor
final class ScribeProviderController {
    var onReadinessChange: ((ScribeProviderReadiness) -> Void)?
    var onProviderRemoved: (() -> Void)?

    private(set) var readiness: ScribeProviderReadiness = .setupRequired {
        didSet {
            guard oldValue != readiness else { return }
            onReadinessChange?(readiness)
        }
    }

    private let configurationStore: any ScribeProviderConfigurationPersisting
    private let credentialStore: any ScribeCredentialStoring
    private let connectionManager: ScribeProviderConnectionManager
    private let transport: any ScribeHTTPTransporting
    private let legacyProvider: (any ScribeProvider)?

    init(
        configurationStore: any ScribeProviderConfigurationPersisting = ScribeProviderConfigurationStore(),
        credentialStore: any ScribeCredentialStoring = KeychainScribeCredentialStore(),
        transport: any ScribeHTTPTransporting = ScribeHTTPTransport(),
        legacyProvider: (any ScribeProvider)? = nil
    ) {
        self.configurationStore = configurationStore
        self.credentialStore = credentialStore
        self.connectionManager = ScribeProviderConnectionManager(
            configurationStore: configurationStore,
            credentialStore: credentialStore
        )
        self.transport = transport
        self.legacyProvider = legacyProvider
        refreshReadiness()
    }

    func refreshReadiness() {
        switch configurationStore.load() {
        case .absent:
            readiness = legacyProvider == nil ? .setupRequired : .ready(.legacyLocal)
        case .rejected:
            readiness = .configurationInvalid
        case let .valid(configuration):
            guard configuration.isEnabled else {
                readiness = .disabled
                return
            }
            guard configurationIsSupported(configuration) else {
                readiness = configuration.kind == .deepSeek
                    ? .deprecated(.deepSeek)
                    : .configurationInvalid
                return
            }
            do {
                readiness = try credentialStore.load(reference: configuration.credentialReference) == nil
                    ? .needsAttention(configuration.kind)
                    : .ready(configuration.kind)
            } catch {
                readiness = .needsAttention(configuration.kind)
            }
        }
    }

    func actionForNewRequest() throws -> ScribeProviderActionSnapshot {
        switch configurationStore.load() {
        case .absent:
            if let legacyProvider {
                return ScribeProviderActionSnapshot(
                    provider: legacyProvider,
                    destination: .legacyLocal
                )
            }
            throw ScribeProviderFailure(
                phase: .generation,
                category: .setupRequired,
                retryDisposition: .reconnect
            )
        case .rejected:
            throw ScribeProviderFailure(
                phase: .generation,
                category: .configurationInvalid,
                retryDisposition: .reconnect
            )
        case let .valid(configuration):
            guard configuration.isEnabled, configurationIsSupported(configuration) else {
                throw ScribeProviderFailure(
                    phase: .generation,
                    category: .configurationInvalid,
                    retryDisposition: configuration.kind == .deepSeek ? .updateCadence : .changeConfiguration
                )
            }
            let credential: String
            do {
                guard let loaded = try credentialStore.load(reference: configuration.credentialReference) else {
                    throw ScribeCredentialStoreError.invalidStoredValue
                }
                credential = loaded
            } catch {
                throw ScribeProviderFailure(
                    phase: .generation,
                    category: .configurationInvalid,
                    retryDisposition: .reconnect
                )
            }
            switch configuration.kind {
            case .openAIDirect, .openRouter:
                throw ScribeProviderFailure(
                    phase: .generation,
                    category: .configurationInvalid,
                    retryDisposition: .updateCadence
                )
            case .deepSeek:
                return ScribeProviderActionSnapshot(
                    provider: DeepSeekScribeProvider(
                        credentialLoader: { credential },
                        transport: transport
                    ),
                    destination: .deepSeek
                )
            case .advanced:
                let endpoint: AdvancedScribeEndpoint
                let model: ScribeModelIdentifier
                do {
                    endpoint = try AdvancedScribeEndpoint(configuration.baseURL.absoluteString)
                    model = try ScribeModelIdentifier(configuration.modelID)
                } catch {
                    throw ScribeProviderFailure(
                        phase: .generation,
                        category: .configurationInvalid,
                        retryDisposition: .changeConfiguration
                    )
                }
                return ScribeProviderActionSnapshot(
                    provider: OpenAICompatibleScribeProvider(
                        endpoint: endpoint,
                        model: model,
                        credentialLoader: { credential },
                        transport: transport
                    ),
                    destination: .advanced(
                        origin: endpoint.normalizedOrigin,
                        disclosureVersion: configuration.disclosureVersion
                    )
                )
            case .legacyLocal:
                guard let legacyProvider else {
                    throw ScribeProviderFailure(
                        phase: .generation,
                        category: .configurationInvalid,
                        retryDisposition: .updateCadence
                    )
                }
                return ScribeProviderActionSnapshot(
                    provider: legacyProvider,
                    destination: .legacyLocal
                )
            }
        }
    }

    func providerForNewAction() throws -> any ScribeProvider {
        try actionForNewRequest().provider
    }

    func connectDeepSeek(
        credential: String,
        acceptedAt: Date = Date()
    ) async throws {
        let candidate = try ScribeProviderCandidateConfiguration.deepSeek(acceptedAt: acceptedAt)
        try await connect(candidate: candidate, credential: credential)
    }

    func connectAdvanced(
        baseURL: String,
        model: String,
        credential: String,
        acceptedAt: Date = Date()
    ) async throws {
        let candidate = ScribeProviderCandidateConfiguration.advanced(
            endpoint: try AdvancedScribeEndpoint(baseURL),
            model: try ScribeModelIdentifier(model),
            acceptedAt: acceptedAt
        )
        try await connect(candidate: candidate, credential: credential)
    }

    func setEnabled(_ enabled: Bool) throws {
        guard case var .valid(configuration) = configurationStore.load() else {
            refreshReadiness()
            return
        }
        configuration.isEnabled = enabled
        try configurationStore.save(configuration)
        refreshReadiness()
    }

    func removeProvider() throws {
        onProviderRemoved?()
        do {
            try connectionManager.removeProvider()
            readiness = .removed
        } catch {
            refreshReadiness()
            throw error
        }
    }

    var statusText: String {
        switch readiness {
        case .disabled:
            return "Scribe is disabled · provider key retained"
        case .setupRequired:
            return "Provider setup required · literal Dictation remains available"
        case .validating:
            return "Validating the selected provider…"
        case let .ready(kind):
            return kind == .legacyLocal
                ? "On-device drafting · no network"
                : "\(kind.displayName) connected · review before insert"
        case let .temporarilyUnavailable(kind):
            return "\(kind.displayName) is temporarily unavailable"
        case .configurationInvalid:
            return "Provider configuration needs repair"
        case let .needsAttention(kind):
            return "\(kind.displayName) needs attention"
        case let .deprecated(kind):
            return "\(kind.displayName) needs a Cadence update"
        case .removed:
            return "Provider removed · provider setup required"
        }
    }

    var configuredKind: ScribeProviderKind? {
        guard case let .valid(configuration) = configurationStore.load() else { return nil }
        return configuration.kind
    }

    var configuredProviderIsEnabled: Bool {
        guard case let .valid(configuration) = configurationStore.load() else { return false }
        return configuration.isEnabled
    }

    var configuredRecipient: String? {
        guard case let .valid(configuration) = configurationStore.load() else { return nil }
        return configuration.normalizedOrigin
    }

    private func connect(
        candidate: ScribeProviderCandidateConfiguration,
        credential: String
    ) async throws {
        readiness = .validating
        do {
            _ = try await connectionManager.connect(
                candidate: candidate,
                credential: credential
            ) { [transport] candidate, candidateCredential in
                switch candidate.kind {
                case .openAIDirect, .openRouter:
                    throw ScribeProviderConnectionError.validationFailed
                case .deepSeek:
                    try await DeepSeekScribeProvider(
                        credentialLoader: { candidateCredential },
                        transport: transport
                    ).validateConnection()
                case .advanced:
                    try await OpenAICompatibleScribeProvider(
                        endpoint: try AdvancedScribeEndpoint(candidate.baseURL.absoluteString),
                        model: try ScribeModelIdentifier(candidate.modelID),
                        credentialLoader: { candidateCredential },
                        transport: transport
                    ).validateConnection()
                case .legacyLocal:
                    throw ScribeProviderConnectionError.validationFailed
                }
            }
            refreshReadiness()
        } catch {
            refreshReadiness()
            throw error
        }
    }

    private func configurationIsSupported(_ configuration: ScribeProviderConfiguration) -> Bool {
        guard configuration.disclosureVersion == ScribeProviderDisclosure.currentVersion else {
            return false
        }
        switch configuration.kind {
        case .openAIDirect, .openRouter:
            return false
        case .deepSeek:
            guard let entry = ScribeProviderCatalog.releaseOne.deepSeekEntries.first else { return false }
            return configuration.catalogID == entry.catalogID
                && configuration.modelID == entry.modelID
                && configuration.requestURL == entry.endpoint
                && configuration.normalizedOrigin == "https://api.deepseek.com"
        case .advanced:
            guard let endpoint = try? AdvancedScribeEndpoint(configuration.baseURL.absoluteString),
                  let model = try? ScribeModelIdentifier(configuration.modelID) else {
                return false
            }
            return endpoint.normalizedOrigin == configuration.normalizedOrigin
                && endpoint.normalizedBaseURL == configuration.baseURL
                && endpoint.requestURL == configuration.requestURL
                && model.rawValue == configuration.modelID
        case .legacyLocal:
            return legacyProvider != nil
        }
    }
}

@MainActor
final class ScribeProviderV2Controller {
    private(set) var readiness: ScribeProviderReadiness = .setupRequired
    private let libraryStore: any ScribeProviderLibraryPersisting
    private let vault: any ScribeCredentialVaulting
    private let consentAuthority: ScribeProviderConsentAuthority
    private let reconciler: ScribeCredentialReconciler
    private let transport: any ScribeHTTPTransporting
    private let legacyLocalProvider: (any ScribeProvider)?

    init(
        libraryStore: any ScribeProviderLibraryPersisting,
        vault: any ScribeCredentialVaulting,
        consentAuthority: ScribeProviderConsentAuthority,
        reconciler: ScribeCredentialReconciler,
        transport: any ScribeHTTPTransporting = ScribeHTTPTransport(),
        legacyLocalProvider: (any ScribeProvider)? = nil
    ) {
        self.libraryStore = libraryStore
        self.vault = vault
        self.consentAuthority = consentAuthority
        self.reconciler = reconciler
        self.transport = transport
        self.legacyLocalProvider = legacyLocalProvider
    }

    func reloadReadiness() async {
        switch libraryStore.load() {
        case .absent: readiness = .setupRequired
        case .rejected: readiness = .configurationInvalid
        case let .valid(library):
            guard let configuration = library.configurations.first(where: {
                $0.id == library.activeConfigurationID
            }) else { readiness = .setupRequired; return }
            guard configuration.isEnabled else { readiness = .disabled; return }
            if configuration.kind != .legacyLocal {
                guard let receipt = configuration.consentReceipt,
                      receipt.disclosureRevision == ScribeProviderDisclosure.currentVersion,
                      receipt.materiallyMatches(configuration),
                      await consentAuthority.verify(receipt) else {
                    readiness = .needsAttention(configuration.kind); return
                }
                do {
                    guard try await vault.load(configuration.storedCredentialReference) != nil else {
                        readiness = .needsAttention(configuration.kind); return
                    }
                } catch { readiness = .needsAttention(configuration.kind); return }
            }
            readiness = .ready(configuration.kind)
        }
    }

    func publishCommittedLibrary(_ library: ScribeProviderLibrary) async throws {
        guard case let .valid(reloaded) = libraryStore.load(),
              reloaded.semanticallyEquals(library) else {
            readiness = .configurationInvalid
            throw ScribeProviderConnectionError.publicationFailed
        }
        await consentAuthority.bootstrap(from: reloaded)
        await reloadReadiness()
    }

    func publishCommittedFallback(_ library: ScribeProviderLibrary) async {
        await consentAuthority.bootstrap(from: library)
        await reloadReadiness()
        if readiness == .configurationInvalid { readiness = .needsAttention(library.configurations.first?.kind ?? .legacyLocal) }
    }

    var configuredKind: ScribeProviderKind? {
        guard case let .valid(library) = libraryStore.load() else { return nil }
        return library.configurations.first(where: { $0.id == library.activeConfigurationID })?.kind
    }

    var activeConfigurationID: UUID? {
        guard case let .valid(library) = libraryStore.load() else { return nil }
        return library.activeConfigurationID
    }

    var configuredProviderIsEnabled: Bool {
        guard case let .valid(library) = libraryStore.load(),
              let configuration = library.configurations.first(where: { $0.id == library.activeConfigurationID })
        else { return false }
        return configuration.isEnabled
    }

    var configuredRecipient: String? {
        guard case let .valid(library) = libraryStore.load() else { return nil }
        return library.configurations.first(where: { $0.id == library.activeConfigurationID })?.normalizedOrigin
    }

    func actionForNewRequest() async throws -> ScribeProviderActionSnapshot {
        guard case let .valid(library) = libraryStore.load(),
              let configuration = library.configurations.first(where: {
                  $0.id == library.activeConfigurationID
              }), configuration.isEnabled else {
            throw failure(.setupRequired, .reconnect)
        }
        if configuration.kind == .legacyLocal {
            guard let legacyLocalProvider else { throw failure(.configurationInvalid, .updateCadence) }
            return ScribeProviderActionSnapshot(
                provider: legacyLocalProvider,
                destination: .legacyLocal,
                configurationID: configuration.id,
                libraryRevision: library.revision,
                selectedModelID: configuration.selectedModelID,
                credentialReference: configuration.storedCredentialReference
            )
        }
        // Consent authority is intentionally process-local. A saved receipt is
        // therefore bootstrapped again after every launch. Do this at the
        // request boundary as well as during startup reconciliation so an
        // immediately-invoked shortcut cannot race startup and misclassify a
        // valid saved provider as needing repair.
        await consentAuthority.bootstrap(from: library)
        guard let receipt = configuration.consentReceipt,
              receipt.disclosureRevision == ScribeProviderDisclosure.currentVersion,
              receipt.materiallyMatches(configuration),
              await consentAuthority.verify(receipt) else {
            throw failure(.configurationInvalid, .reconnect)
        }
        guard let credential = try await vault.load(configuration.storedCredentialReference) else {
            throw failure(.configurationInvalid, .reconnect)
        }
        return try makeAction(
            configuration: configuration,
            libraryRevision: library.revision,
            receipt: receipt,
            credential: credential
        )
    }

    func authorizeDispatch(_ identity: ScribeProviderActionIdentity?) async -> Bool {
        guard let identity,
              case let .valid(library) = libraryStore.load(),
              library.revision == identity.libraryRevision,
              let configuration = library.configurations.first(where: {
                  $0.id == identity.configurationID && $0.id == library.activeConfigurationID
              }),
              configuration.isEnabled,
              configuration.selectedModelID == identity.selectedModelID,
              configuration.storedCredentialReference == identity.credentialReference else { return false }
        if configuration.kind == .legacyLocal {
            return identity.consentReceiptID == nil && legacyLocalProvider != nil
        }
        guard let receipt = configuration.consentReceipt,
              receipt.id == identity.consentReceiptID,
              receipt.materiallyMatches(configuration),
              await consentAuthority.verify(receipt) else { return false }
        return (try? await vault.load(configuration.storedCredentialReference)) != nil
    }

    func setEnabled(
        configurationID: UUID,
        enabled: Bool,
        activeAction: ScribeProviderActionIdentity?,
        confirmed: Bool,
        cancelActiveAction: @MainActor () async -> Void
    ) async throws -> ScribeProviderMutationDecision {
        let decision = ScribeProviderMutationPolicy.decision(
            activeAction: activeAction,
            mutatingConfigurationID: configurationID
        )
        guard decision == .allowed || confirmed else { return .confirmationRequired }
        if decision == .confirmationRequired { await cancelActiveAction() }
        guard case let .valid(library) = libraryStore.load(),
              let index = library.configurations.firstIndex(where: { $0.id == configurationID })
        else { throw failure(.configurationInvalid, .reconnect) }
        var configurations = library.configurations
        configurations[index] = configurations[index].withEnabled(enabled)
        try libraryStore.save(ScribeProviderLibrary(
            revision: library.revision + 1,
            configurations: configurations,
            activeConfigurationID: enabled ? configurationID
                : (library.activeConfigurationID == configurationID ? nil : library.activeConfigurationID)
        ))
        guard case let .valid(committed) = libraryStore.load() else {
            await reloadReadiness()
            throw ScribeProviderConnectionError.persistenceFailed
        }
        try await publishCommittedLibrary(committed)
        return .allowed
    }

    func remove(
        configurationID: UUID,
        activeAction: ScribeProviderActionIdentity?,
        confirmed: Bool,
        cancelActiveAction: @MainActor () async -> Void
    ) async throws -> ScribeProviderMutationDecision {
        let decision = ScribeProviderMutationPolicy.decision(
            activeAction: activeAction,
            mutatingConfigurationID: configurationID
        )
        guard decision == .allowed || confirmed else { return .confirmationRequired }
        if decision == .confirmationRequired { await cancelActiveAction() }
        guard case let .valid(library) = libraryStore.load(),
              let removed = library.configurations.first(where: { $0.id == configurationID })
        else { throw failure(.configurationInvalid, .reconnect) }
        let remaining = library.configurations.filter { $0.id != configurationID }
        try libraryStore.save(ScribeProviderLibrary(
            revision: library.revision + 1,
            configurations: remaining,
            activeConfigurationID: library.activeConfigurationID == configurationID
                ? nil : library.activeConfigurationID
        ))
        guard case let .valid(committed) = libraryStore.load() else {
            await reloadReadiness()
            throw ScribeProviderConnectionError.persistenceFailed
        }
        try await publishCommittedLibrary(committed)
        if let receipt = removed.consentReceipt { await consentAuthority.revoke(receipt.id) }
        try await reconciler.deleteIfUnreferenced(removed.storedCredentialReference)
        await reloadReadiness()
        return .allowed
    }

    func reconcileAtStartup() async throws {
        try await reconciler.reconcile()
        if case let .valid(library) = libraryStore.load() {
            await consentAuthority.bootstrap(from: library)
        }
        await reloadReadiness()
    }

    private func makeAction(
        configuration: ScribeProviderLibraryConfiguration,
        libraryRevision: Int,
        receipt: ScribeProviderConsentReceipt,
        credential: String
    ) throws -> ScribeProviderActionSnapshot {
        let provider: any ScribeProvider
        let destination: ScribeEgressDestination
        switch configuration.kind {
        case .openAIDirect:
            provider = OpenAIDirectScribeProvider(
                model: try ScribeModelIdentifier(configuration.selectedModelID),
                credentialLoader: { credential }, transport: transport
            )
            destination = .openAIDirect
        case .openRouter:
            provider = OpenRouterScribeProvider(
                model: try ScribeModelIdentifier(configuration.selectedModelID),
                credentialLoader: { credential }, transport: transport
            )
            destination = .openRouter
        case .deepSeek:
            provider = DeepSeekScribeProvider(credentialLoader: { credential }, transport: transport)
            destination = .deepSeek
        case .advanced:
            let endpoint = try AdvancedScribeEndpoint(configuration.baseURL.absoluteString)
            provider = OpenAICompatibleScribeProvider(
                endpoint: endpoint,
                model: try ScribeModelIdentifier(configuration.selectedModelID),
                credentialLoader: { credential }, transport: transport
            )
            destination = .advanced(origin: endpoint.normalizedOrigin, disclosureVersion: receipt.disclosureRevision)
        case .legacyLocal:
            throw failure(.configurationInvalid, .updateCadence)
        }
        return ScribeProviderActionSnapshot(
            provider: provider,
            destination: destination,
            configurationID: configuration.id,
            libraryRevision: libraryRevision,
            consentReceiptID: receipt.id,
            selectedModelID: configuration.selectedModelID,
            credentialReference: configuration.storedCredentialReference
        )
    }

    private func failure(
        _ category: ScribeProviderFailureCategory,
        _ retry: ScribeProviderRetryDisposition
    ) -> ScribeProviderFailure {
        ScribeProviderFailure(phase: .generation, category: category, retryDisposition: retry)
    }
}
