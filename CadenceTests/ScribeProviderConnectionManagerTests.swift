import Foundation
import Testing
@testable import Cadence

struct ScribeProviderConnectionManagerV2Tests {
    @Test
    func genericEntryRejectsCatalogProvidersBeforeValidatorStageOrWrite() async throws {
        for kind in [ScribeProviderKind.openAIDirect, .openRouter] {
            let doubles = try U5ConnectionDoubles(securityAccepted: true)
            let receipt: ScribeProviderConsentReceipt
            switch kind {
            case .openAIDirect:
                receipt = await doubles.authority.issueEphemeral(
                    providerKind: kind, recipientOrigin: "https://api.openai.com",
                    routingPolicy: .directSingleModel,
                    retentionPolicy: .requestStorageDisabled,
                    dataPolicy: .providerPolicyApplies
                )
            case .openRouter:
                receipt = await doubles.authority.issueEphemeral(
                    providerKind: kind, recipientOrigin: "https://openrouter.ai",
                    routingPolicy: .zeroDataRetentionSingleModel,
                    retentionPolicy: .zeroDataRetentionRequired,
                    dataPolicy: .collectionDenied
                )
            default:
                fatalError("Catalog providers only")
            }
            let candidate = doubles.catalogCandidate(receipt: receipt)
            await #expect(throws: ScribeProviderConnectionError.validationFailed) {
                _ = try await doubles.manager.connect(
                    candidate: candidate, credential: "secret"
                ) { _, _ in Issue.record("Generic catalog validation must not run") }
            }
            #expect(doubles.library.saveCount == 0)
            #expect(await doubles.vault.staged.isEmpty)
        }
    }

    @Test @MainActor
    func consumedCatalogProofCommitsOnceAndReuseFailsBeforeSecondStageOrWrite() async throws {
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/models")!,
                body: #"{"data":[{"id":"gpt-proof"}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/responses")!,
                body: #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#
            ))
        ])
        let library = U5LibraryStore()
        let vault = U5Vault()
        let runtime = ScribeProviderRuntime(
            libraryStore: library, legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(), vault: vault, transport: transport
        )
        await runtime.switchSetupProvider(to: .openAIDirect)
        let receipt = await runtime.consentAuthority.issueEphemeral(
            providerKind: .openAIDirect, recipientOrigin: "https://api.openai.com",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled, dataPolicy: .providerPolicyApplies
        )
        let candidate = ScribeProviderConnectionCandidate(
            id: UUID(), kind: .openAIDirect, displayName: "OpenAI",
            normalizedOrigin: "https://api.openai.com",
            baseURL: URL(string: "https://api.openai.com")!,
            requestURL: URL(string: "https://api.openai.com/v1/responses")!,
            selectedModelID: "gpt-proof", catalogID: nil,
            consentReceipt: receipt, acceptedAt: receipt.acceptedAt
        )
        let revision = runtime.setupSession.prepareAttempt(
            providerKind: .openAIDirect, credential: "secret"
        )
        guard case let .ready(proof) = await runtime.modelCatalog.validateNewSetup(
            provider: .openAIDirect,
            selectedModelID: candidate.selectedModelID,
            consentReceipt: receipt,
            setupRevision: revision
        ) else { Issue.record("Expected catalog proof"); return }
        let consume: @Sendable () async -> Bool = { [modelCatalog = runtime.modelCatalog] in
            await modelCatalog.consume(proof, for: candidate, setupRevision: revision)
        }

        _ = try await runtime.manager.connectValidated(
            candidate: candidate, credential: "secret", proof: proof,
            setupRevision: revision, attemptFence: { true }, consumeProof: consume
        )
        await #expect(throws: ScribeProviderConnectionError.validationFailed) {
            _ = try await runtime.manager.connectValidated(
                candidate: candidate, credential: "secret", proof: proof,
                setupRevision: revision, attemptFence: { true }, consumeProof: consume
            )
        }
        #expect(library.saveCount == 1)
        #expect(await vault.staged.count == 1)
    }

    @Test
    func unacceptedSecurityDecisionStopsBeforeValidationOrStaging() async throws {
        let doubles = try U5ConnectionDoubles(securityAccepted: false)
        let receipt = await doubles.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        await #expect(throws: ScribeProviderConnectionError.securityDecisionRequired) {
            _ = try await doubles.manager.connect(
                candidate: doubles.candidate(receipt: receipt),
                credential: "secret"
            ) { _, _ in Issue.record("Validation must not run") }
        }
        #expect(await doubles.vault.staged.isEmpty)
        #expect(doubles.library.saveCount == 0)
    }

    @Test
    func successfulCommitStagesOnceWritesOneActiveEnvelopeAndPublishesReload() async throws {
        let doubles = try U5ConnectionDoubles(securityAccepted: true)
        let receipt = await doubles.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let connected = try await doubles.manager.connect(
            candidate: doubles.candidate(receipt: receipt),
            credential: "secret"
        ) { _, credential in #expect(credential == "secret") }

        #expect(doubles.library.saveCount == 1)
        guard case let .valid(library) = doubles.library.result else {
            Issue.record("Expected committed library"); return
        }
        #expect(library.activeConfigurationID == connected.id)
        #expect(library.configurations == [connected])
        #expect(connected.credentialStorageDomain == .candidate)
        #expect(await doubles.authority.verify(receipt))
        #expect(await doubles.vault.staged == [connected.storedCredentialReference])
    }

    @Test @MainActor
    func mandatoryPublisherDrivesTheRealControllerReadinessFromCommittedBytes() async throws {
        let library = U5LibraryStore()
        let legacy = U5LegacyStore()
        let ledger = U5LedgerStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library, legacyStore: legacy, ledgerStore: ledger, vault: vault
        )
        let controller = ScribeProviderV2Controller(
            libraryStore: library, vault: vault, consentAuthority: authority, reconciler: reconciler
        )
        let manager = ScribeProviderV2ConnectionManager(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            inheritedAccessibilityAccepted: true,
            publisher: { library in try await controller.publishCommittedLibrary(library) },
            committedFallbackPublisher: { library in await controller.publishCommittedFallback(library) }
        )
        let receipt = await authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        let helper = try U5ConnectionDoubles(securityAccepted: true)

        _ = try await manager.connect(
            candidate: helper.candidate(receipt: receipt), credential: "secret"
        ) { _, _ in }

        #expect(controller.readiness == .ready(.advanced))
        #expect(controller.configuredKind == .advanced)
    }

    @Test
    func invalidValidationAndUnreadableRetainedStoreNeverStage() async throws {
        let invalid = try U5ConnectionDoubles(securityAccepted: true)
        let receipt = await invalid.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        await #expect(throws: ScribeProviderConnectionError.validationFailed) {
            _ = try await invalid.manager.connect(
                candidate: invalid.candidate(receipt: receipt), credential: "bad"
            ) { _, _ in throw ScribeProviderConnectionError.validationFailed }
        }
        #expect(await invalid.vault.staged.isEmpty)

        let unreadable = try U5ConnectionDoubles(securityAccepted: true)
        unreadable.legacy.result = .rejected(.malformed)
        let secondReceipt = await unreadable.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        await #expect(throws: ScribeProviderConnectionError.retainedStoreUnreadable) {
            _ = try await unreadable.manager.connect(
                candidate: unreadable.candidate(receipt: secondReceipt), credential: "secret"
            ) { _, _ in }
        }
        #expect(await unreadable.vault.staged.isEmpty)
    }

    @Test
    func libraryWriteFailureDeletesTheUncommittedCandidateAndPreservesPriorState() async throws {
        let doubles = try U5ConnectionDoubles(securityAccepted: true)
        let priorReceipt = ScribeProviderConsentIssuer.issue(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled,
            disclosureRevision: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let priorReference = ScribeStoredCredentialReference(
            domain: .candidate,
            opaqueReference: .init(rawValue: "prior")
        )
        let priorConfiguration = try U5Fixtures.configuration(
            kind: .advanced,
            model: "gpt-prior",
            receipt: priorReceipt,
            reference: priorReference
        )
        let priorLibrary = ScribeProviderLibrary(
            revision: 4,
            configurations: [priorConfiguration],
            activeConfigurationID: priorConfiguration.id
        )
        doubles.library.result = .valid(priorLibrary)
        doubles.library.saveError = ScribeProviderConnectionError.persistenceFailed
        await doubles.vault.insert(priorReference)
        let receipt = await doubles.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )

        await #expect(throws: ScribeProviderConnectionError.persistenceFailed) {
            _ = try await doubles.manager.connect(
                candidate: doubles.candidate(receipt: receipt),
                credential: "replacement"
            ) { _, _ in }
        }

        #expect(doubles.library.result == .valid(priorLibrary))
        #expect(doubles.library.saveCount == 1)
        #expect(await doubles.vault.staged == [priorReference])
    }

    @Test
    func publicationFailureReloadsCommittedLibraryAndRetainsCandidateKey() async throws {
        let library = U5LibraryStore()
        let legacy = U5LegacyStore()
        let ledger = U5LedgerStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library, legacyStore: legacy, ledgerStore: ledger, vault: vault
        )
        let manager = ScribeProviderV2ConnectionManager(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            inheritedAccessibilityAccepted: true,
            publisher: { _ in throw ScribeProviderConnectionError.publicationFailed },
            committedFallbackPublisher: { _ in }
        )
        let receipt = await authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        let helper = try U5ConnectionDoubles(securityAccepted: true)
        await #expect(throws: ScribeProviderConnectionError.publicationFailed) {
            _ = try await manager.connect(
                candidate: helper.candidate(receipt: receipt), credential: "secret"
            ) { _, _ in }
        }
        #expect(library.saveCount == 1)
        guard case let .valid(committed) = library.result,
              let reference = committed.configurations.first?.storedCredentialReference else {
            Issue.record("Expected committed fallback"); return
        }
        #expect(await vault.staged.contains(reference))
        #expect(await manager.publishedLibrary?.semanticallyEquals(committed) == true)
        #expect(await authority.verify(receipt))
    }

    @Test @MainActor
    func primaryPublicationFailureUsesMandatoryFallbackToRealControllerState() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library, legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(), vault: vault
        )
        let controller = ScribeProviderV2Controller(
            libraryStore: library, vault: vault,
            consentAuthority: authority, reconciler: reconciler
        )
        let manager = ScribeProviderV2ConnectionManager(
            libraryStore: library, vault: vault,
            consentAuthority: authority, reconciler: reconciler,
            inheritedAccessibilityAccepted: true,
            publisher: { _ in throw ScribeProviderConnectionError.publicationFailed },
            committedFallbackPublisher: { library in
                await controller.publishCommittedFallback(library)
            }
        )
        let receipt = await authority.issueEphemeral(
            providerKind: .advanced, recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled, dataPolicy: .providerControlled
        )
        let helper = try U5ConnectionDoubles(securityAccepted: true)

        await #expect(throws: ScribeProviderConnectionError.publicationFailed) {
            _ = try await manager.connect(
                candidate: helper.candidate(receipt: receipt), credential: "secret"
            ) { _, _ in }
        }

        #expect(controller.readiness == .ready(.advanced))
        #expect(try await controller.actionForNewRequest().destination.providerKind == .advanced)
    }

    @Test
    func failedProvenOldDeleteCreatesBoundedTombstoneAfterCommit() async throws {
        let doubles = try U5ConnectionDoubles(securityAccepted: true)
        let oldReceipt = ScribeProviderConsentIssuer.issue(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled,
            disclosureRevision: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let oldReference = ScribeStoredCredentialReference(
            domain: .candidate, opaqueReference: .init(rawValue: "old")
        )
        let old = try U5Fixtures.configuration(
            kind: .advanced, model: "gpt-old", receipt: oldReceipt, reference: oldReference
        )
        doubles.library.result = .valid(ScribeProviderLibrary(
            revision: 1, configurations: [old], activeConfigurationID: old.id
        ))
        await doubles.vault.insert(oldReference)
        await doubles.vault.failDeletion(of: oldReference)
        let receipt = await doubles.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        _ = try await doubles.manager.connect(
            candidate: doubles.candidate(receipt: receipt), credential: "new"
        ) { _, _ in }
        guard case let .valid(ledger) = doubles.ledger.result else {
            Issue.record("Expected tombstone"); return
        }
        #expect(ledger.references == [oldReference])
        #expect(doubles.library.saveCount == 1)
        await doubles.vault.allowDeletion(of: oldReference)
        try await doubles.reconciler.reconcile()
        #expect(doubles.ledger.result == .absent)
        #expect(!(await doubles.vault.staged.contains(oldReference)))
    }

    @Test
    func replacementDoesNotDeleteReferenceStillOwnedByRetainedLegacyStore() async throws {
        let doubles = try U5ConnectionDoubles(securityAccepted: true)
        let sharedRaw = ScribeCredentialReference(rawValue: "shared-legacy")
        let shared = ScribeStoredCredentialReference(domain: .inherited, opaqueReference: sharedRaw)
        let oldReceipt = ScribeProviderConsentIssuer.issue(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled,
            disclosureRevision: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let old = try U5Fixtures.configuration(
            kind: .advanced, model: "gpt-old", receipt: oldReceipt, reference: shared
        )
        doubles.library.result = .valid(ScribeProviderLibrary(
            revision: 1, configurations: [old], activeConfigurationID: old.id
        ))
        doubles.legacy.result = .valid(try ScribeProviderConfiguration.deepSeek(
            credentialReference: sharedRaw, acceptedAt: Date(timeIntervalSince1970: 5)
        ))
        await doubles.vault.insert(shared)
        let receipt = await doubles.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )

        _ = try await doubles.manager.connect(
            candidate: doubles.candidate(receipt: receipt), credential: "new"
        ) { _, _ in }

        #expect(await doubles.vault.staged.contains(shared))
        #expect(doubles.ledger.result == .absent)
    }

    @Test
    func concurrentAttemptsCannotActivateOrDeleteEachOther() async throws {
        let doubles = try U5ConnectionDoubles(securityAccepted: true)
        let firstReceipt = await doubles.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        let secondReceipt = await doubles.authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        let gate = U5ValidationGate()
        let firstCandidate = doubles.candidate(receipt: firstReceipt)
        let secondCandidate = doubles.candidate(receipt: secondReceipt)
        let first = Task {
            try await doubles.manager.connect(candidate: firstCandidate, credential: "first") { _, _ in
                await gate.wait()
            }
        }
        await gate.waitUntilEntered()
        let second = try await doubles.manager.connect(
            candidate: secondCandidate, credential: "second"
        ) { _, _ in }
        await gate.release()
        await #expect(throws: ScribeProviderConnectionError.staleAttempt) { try await first.value }
        guard case let .valid(library) = doubles.library.result else {
            Issue.record("Expected second library"); return
        }
        #expect(library.activeConfigurationID == second.id)
        #expect(library.configurations.map(\.id) == [second.id])
        #expect(await doubles.vault.staged == [second.storedCredentialReference])
    }

    @Test
    func cancelledQueuedAttemptCannotWriteOrPublishAfterTheLockBecomesAvailable() async throws {
        let library = U5LibraryStore()
        let legacy = U5LegacyStore()
        let ledger = U5LedgerStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library, legacyStore: legacy, ledgerStore: ledger, vault: vault
        )
        let publicationGate = U5AsyncGate()
        let manager = ScribeProviderV2ConnectionManager(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            inheritedAccessibilityAccepted: true,
            publisher: { _ in await publicationGate.wait() },
            committedFallbackPublisher: { _ in }
        )
        let helper = try U5ConnectionDoubles(securityAccepted: true)
        let firstReceipt = await authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        let secondReceipt = await authority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        let first = Task {
            try await manager.connect(
                candidate: helper.candidate(receipt: firstReceipt), credential: "first"
            ) { _, _ in }
        }
        await publicationGate.waitUntilEntered()
        let second = Task {
            try await manager.connect(
                candidate: helper.candidate(receipt: secondReceipt), credential: "second"
            ) { _, _ in }
        }
        await Task.yield()
        second.cancel()
        await publicationGate.release()
        _ = try await first.value
        await #expect(throws: CancellationError.self) { try await second.value }

        #expect(library.saveCount == 1)
        #expect(await vault.staged.count == 1)
    }
}

private actor U5AsyncGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor U5ValidationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class U5LibraryStore: ScribeProviderLibraryPersisting, @unchecked Sendable {
    var result: ScribeProviderLibraryLoadResult = .absent
    var saveCount = 0
    var saveError: Error?
    var onSave: (() -> Void)?
    func load() -> ScribeProviderLibraryLoadResult { result }
    func save(_ library: ScribeProviderLibrary) throws {
        saveCount += 1
        onSave?()
        if let saveError { throw saveError }
        result = .valid(library.normalized())
    }
    func referencedCredentials() -> ScribeCredentialReferenceSet { .available([]) }
}

final class U5LegacyStore: ScribeProviderConfigurationPersisting, @unchecked Sendable {
    var result: ScribeProviderConfigurationLoadResult = .absent
    func load() -> ScribeProviderConfigurationLoadResult { result }
    func save(_ configuration: ScribeProviderConfiguration?) throws {}
}

final class U5LedgerStore: ScribeCredentialCleanupLedgerPersisting, @unchecked Sendable {
    var result: ScribeCleanupLedgerLoadResult = .absent
    func load() -> ScribeCleanupLedgerLoadResult { result }
    func save(_ ledger: ScribeCredentialCleanupLedger?) throws { result = ledger.map(ScribeCleanupLedgerLoadResult.valid) ?? .absent }
}

actor U5Vault: ScribeCredentialVaulting {
    var staged: Set<ScribeStoredCredentialReference> = []
    var loadCount = 0
    var deleteFailures: Set<ScribeStoredCredentialReference> = []
    func stageCandidate(_ credential: String) -> ScribeStoredCredentialReference {
        let ref = ScribeStoredCredentialReference(domain: .candidate, opaqueReference: .init(rawValue: UUID().uuidString))
        staged.insert(ref); return ref
    }
    func load(_ reference: ScribeStoredCredentialReference) -> String? {
        loadCount += 1
        return staged.contains(reference) ? "secret" : nil
    }
    func delete(_ reference: ScribeStoredCredentialReference) throws {
        if deleteFailures.contains(reference) { throw ScribeCredentialStoreError.keychain(-1) }
        staged.remove(reference)
    }
    func candidateReferences() -> Set<ScribeStoredCredentialReference> { staged }
    func insert(_ reference: ScribeStoredCredentialReference) { staged.insert(reference) }
    func failDeletion(of reference: ScribeStoredCredentialReference) { deleteFailures.insert(reference) }
    func allowDeletion(of reference: ScribeStoredCredentialReference) { deleteFailures.remove(reference) }
}

struct U5ConnectionDoubles {
    let library = U5LibraryStore()
    let legacy = U5LegacyStore()
    let ledger = U5LedgerStore()
    let vault = U5Vault()
    let authority = ScribeProviderConsentAuthority()
    let reconciler: ScribeCredentialReconciler
    let manager: ScribeProviderV2ConnectionManager

    init(securityAccepted: Bool) throws {
        reconciler = ScribeCredentialReconciler(
            libraryStore: library,
            legacyStore: legacy,
            ledgerStore: ledger,
            vault: vault
        )
        manager = ScribeProviderV2ConnectionManager(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            inheritedAccessibilityAccepted: securityAccepted,
            publisher: { _ in },
            committedFallbackPublisher: { _ in }
        )
    }

    func candidate(receipt: ScribeProviderConsentReceipt) -> ScribeProviderConnectionCandidate {
        ScribeProviderConnectionCandidate(
            id: UUID(), kind: .advanced, displayName: "Custom",
            normalizedOrigin: "https://custom.example",
            baseURL: URL(string: "https://custom.example")!,
            requestURL: URL(string: "https://custom.example/chat/completions")!,
            selectedModelID: "gpt-test", catalogID: nil,
            consentReceipt: receipt, acceptedAt: receipt.acceptedAt
        )
    }

    func catalogCandidate(
        receipt: ScribeProviderConsentReceipt
    ) -> ScribeProviderConnectionCandidate {
        switch receipt.providerKind {
        case .openAIDirect:
            return ScribeProviderConnectionCandidate(
                id: UUID(), kind: .openAIDirect, displayName: "OpenAI",
                normalizedOrigin: "https://api.openai.com",
                baseURL: URL(string: "https://api.openai.com")!,
                requestURL: URL(string: "https://api.openai.com/v1/responses")!,
                selectedModelID: "gpt-test", catalogID: nil,
                consentReceipt: receipt, acceptedAt: receipt.acceptedAt
            )
        case .openRouter:
            return ScribeProviderConnectionCandidate(
                id: UUID(), kind: .openRouter, displayName: "OpenRouter",
                normalizedOrigin: "https://openrouter.ai",
                baseURL: URL(string: "https://openrouter.ai")!,
                requestURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                selectedModelID: "vendor/model", catalogID: nil,
                consentReceipt: receipt, acceptedAt: receipt.acceptedAt
            )
        default:
            fatalError("Catalog provider required")
        }
    }
}
