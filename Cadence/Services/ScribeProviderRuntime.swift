import Foundation

@MainActor
final class ScribeProviderRuntime {
    let controller: ScribeProviderV2Controller
    let manager: ScribeProviderV2ConnectionManager
    let setupSession: ScribeProviderSetupSession
    let modelCatalog: ScribeModelCatalogService
    let consentAuthority: ScribeProviderConsentAuthority
    let vault: any ScribeCredentialVaulting

    init(
        libraryStore: any ScribeProviderLibraryPersisting,
        legacyStore: any ScribeProviderConfigurationPersisting,
        ledgerStore: any ScribeCredentialCleanupLedgerPersisting,
        vault: any ScribeCredentialVaulting,
        transport: any ScribeHTTPTransporting = ScribeHTTPTransport(),
        legacyLocalProvider: (any ScribeProvider)? = nil,
        inheritedAccessibilityAccepted: Bool =
            ScribeCredentialAccessibilityDecision.inheritedAfterFirstUnlockThisDeviceOnlyAccepted
    ) {
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: libraryStore,
            legacyStore: legacyStore,
            ledgerStore: ledgerStore,
            vault: vault
        )
        let controller = ScribeProviderV2Controller(
            libraryStore: libraryStore,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            transport: transport,
            legacyLocalProvider: legacyLocalProvider
        )
        let manager = ScribeProviderV2ConnectionManager(
            libraryStore: libraryStore,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            inheritedAccessibilityAccepted: inheritedAccessibilityAccepted,
            publisher: { [controller] library in
                try await controller.publishCommittedLibrary(library)
            },
            committedFallbackPublisher: { [controller] library in
                await controller.publishCommittedFallback(library)
            }
        )
        let setupSession = ScribeProviderSetupSession(
            consentAuthority: authority,
            cancelConnectionAttempt: { [manager] in await manager.cancelCurrentAttempt() }
        )

        self.controller = controller
        self.manager = manager
        self.setupSession = setupSession
        self.modelCatalog = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { kind in try await setupSession.credential(for: kind) },
            consentVerifier: authority.verifier()
        )
        self.consentAuthority = authority
        self.vault = vault
    }

    func dismissSetup() async {
        await setupSession.dismiss()
    }

    func switchSetupProvider(to kind: ScribeProviderKind) async {
        await setupSession.providerSwitched(to: kind)
    }

    func connectCatalogValidated(
        candidate: ScribeProviderConnectionCandidate,
        credential: String
    ) async throws -> ScribeProviderLibraryConfiguration {
        guard candidate.kind == .openAIDirect || candidate.kind == .openRouter else {
            throw ScribeProviderConnectionError.validationFailed
        }
        let revision = setupSession.prepareAttempt(
            providerKind: candidate.kind,
            credential: credential
        )
        let fence: @Sendable () async -> Bool = { [weak setupSession] in
            guard let setupSession else { return false }
            return await setupSession.acceptsCallback(revision: revision)
        }
        let validation = await modelCatalog.validateNewSetup(
            provider: candidate.kind,
            selectedModelID: candidate.selectedModelID,
            consentReceipt: candidate.consentReceipt,
            setupRevision: revision
        )
        guard case let .ready(proof) = validation else {
            setupSession.completeAttempt(revision: revision)
            throw ScribeProviderConnectionError.validationFailed
        }
        guard await fence() else {
            await modelCatalog.discard(proof)
            setupSession.completeAttempt(revision: revision)
            throw ScribeProviderConnectionError.validationFailed
        }
        defer { setupSession.completeAttempt(revision: revision) }
        do {
            let connected = try await manager.connectValidated(
                candidate: candidate,
                credential: credential,
                proof: proof,
                setupRevision: revision,
                attemptFence: fence,
                consumeProof: { [modelCatalog] in
                    await modelCatalog.consume(
                        proof,
                        for: candidate,
                        setupRevision: revision
                    )
                }
            )
            return connected
        } catch {
            await modelCatalog.discard(proof)
            throw error
        }
    }
}
