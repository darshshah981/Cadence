import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeProviderControllerV2Tests {
    @Test
    func activeActionMutationRequiresConfirmationBeforeLibraryChange() {
        let activeID = UUID()
        let identity = ScribeProviderActionIdentity(
            configurationID: activeID,
            libraryRevision: 3,
            consentReceiptID: UUID(),
            selectedModelID: "model"
        )
        #expect(ScribeProviderMutationPolicy.decision(
            activeAction: identity,
            mutatingConfigurationID: activeID
        ) == .confirmationRequired)
        #expect(ScribeProviderMutationPolicy.decision(
            activeAction: identity,
            mutatingConfigurationID: UUID()
        ) == .allowed)
        #expect(ScribeProviderMutationPolicy.activationDecision(activeAction: identity)
            == .confirmationRequired)
        #expect(ScribeProviderMutationPolicy.activationDecision(activeAction: nil) == .allowed)
    }

    @Test
    func missingAuthoritativeReceiptCausesZeroCredentialOrTransportAndNoLegacyFallback() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let legacy = U5LegacyStore()
        let ledger = U5LedgerStore()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library, legacyStore: legacy, ledgerStore: ledger, vault: vault
        )
        let reference = ScribeStoredCredentialReference(
            domain: .candidate, opaqueReference: .init(rawValue: "key")
        )
        await vault.insert(reference)
        let configuration = try U5Fixtures.configuration(
            kind: .openAIDirect, model: "gpt-test", receipt: nil, reference: reference
        )
        library.result = .valid(ScribeProviderLibrary(
            revision: 1, configurations: [configuration], activeConfigurationID: configuration.id
        ))
        let controller = ScribeProviderV2Controller(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            legacyLocalProvider: MockScribeProvider()
        )
        await controller.reloadReadiness()
        #expect(controller.readiness == .needsAttention(.openAIDirect))
        await #expect(throws: ScribeProviderFailure.self) { try await controller.actionForNewRequest() }
        #expect(await vault.loadCount == 0)

        library.result = .absent
        await controller.reloadReadiness()
        #expect(controller.readiness == .setupRequired)
        await #expect(throws: ScribeProviderFailure.self) { try await controller.actionForNewRequest() }
    }

    @Test
    func cancelledConfirmationLeavesLibraryByteSemanticsUnchanged() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let legacy = U5LegacyStore()
        let ledger = U5LedgerStore()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library, legacyStore: legacy, ledgerStore: ledger, vault: vault
        )
        let receipt = ScribeProviderConsentIssuer.issue(
            providerKind: .openAIDirect,
            recipientOrigin: "https://api.openai.com",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled,
            dataPolicy: .providerPolicyApplies,
            disclosureRevision: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let configuration = try U5Fixtures.configuration(
            kind: .openAIDirect, model: "gpt-test", receipt: receipt
        )
        let original = ScribeProviderLibrary(
            revision: 1, configurations: [configuration], activeConfigurationID: configuration.id
        )
        library.result = .valid(original)
        let controller = ScribeProviderV2Controller(
            libraryStore: library, vault: vault, consentAuthority: authority, reconciler: reconciler
        )
        let identity = ScribeProviderActionIdentity(
            configurationID: configuration.id,
            libraryRevision: 1,
            consentReceiptID: receipt.id,
            selectedModelID: "gpt-test"
        )
        let decision = try await controller.setEnabled(
            configurationID: configuration.id,
            enabled: false,
            activeAction: identity,
            confirmed: false,
            cancelActiveAction: { Issue.record("Must not cancel") }
        )
        #expect(decision == .confirmationRequired)
        #expect(library.result == .valid(original))
        #expect(library.saveCount == 0)
    }

    @Test
    func confirmedMutationAwaitsActiveActionCancellationBeforeSaving() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library,
            legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(),
            vault: vault
        )
        let receipt = Self.receipt(for: .openAIDirect)
        let configuration = try U5Fixtures.configuration(
            kind: .openAIDirect, model: "gpt-test", receipt: receipt
        )
        let configured = ScribeProviderLibrary(
            revision: 2, configurations: [configuration], activeConfigurationID: configuration.id
        )
        library.result = .valid(configured)
        await authority.bootstrap(from: configured)
        var cancellationFinished = false
        library.onSave = { #expect(cancellationFinished) }
        let controller = ScribeProviderV2Controller(
            libraryStore: library, vault: vault, consentAuthority: authority, reconciler: reconciler
        )

        let decision = try await controller.setEnabled(
            configurationID: configuration.id,
            enabled: false,
            activeAction: ScribeProviderActionIdentity(
                configurationID: configuration.id,
                libraryRevision: configured.revision,
                consentReceiptID: receipt.id,
                selectedModelID: configuration.selectedModelID,
                credentialReference: configuration.storedCredentialReference
            ),
            confirmed: true,
            cancelActiveAction: {
                await Task.yield()
                cancellationFinished = true
            }
        )
        #expect(decision == .allowed)
        #expect(cancellationFinished)
    }

    @Test
    func dispatchAuthorizationRequiresExactCurrentIdentityAndAuthoritativeConsent() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library,
            legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(),
            vault: vault
        )
        let receipt = Self.receipt(for: .openAIDirect)
        let reference = ScribeStoredCredentialReference(
            domain: .candidate, opaqueReference: .init(rawValue: "dispatch")
        )
        let configuration = try U5Fixtures.configuration(
            kind: .openAIDirect, model: "gpt-test", receipt: receipt, reference: reference
        )
        let configured = ScribeProviderLibrary(
            revision: 7, configurations: [configuration], activeConfigurationID: configuration.id
        )
        library.result = .valid(configured)
        await vault.insert(reference)
        await authority.bootstrap(from: configured)
        let controller = ScribeProviderV2Controller(
            libraryStore: library, vault: vault, consentAuthority: authority, reconciler: reconciler
        )
        let action = try await controller.actionForNewRequest()
        #expect(await controller.authorizeDispatch(action.actionIdentity))

        await authority.revoke(receipt.id)
        #expect(!(await controller.authorizeDispatch(action.actionIdentity)))
        #expect(await vault.loadCount == 2)
    }

    @Test
    func disableRetainsCredentialWhileRemoveCommitsBeforeDeletingIt() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let ledger = U5LedgerStore()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library,
            legacyStore: U5LegacyStore(),
            ledgerStore: ledger,
            vault: vault
        )
        let receipt = Self.receipt(for: .openAIDirect)
        let reference = ScribeStoredCredentialReference(
            domain: .candidate,
            opaqueReference: .init(rawValue: "retained-until-remove")
        )
        let configuration = try U5Fixtures.configuration(
            kind: .openAIDirect,
            model: "gpt-test",
            receipt: receipt,
            reference: reference
        )
        let configuredLibrary = ScribeProviderLibrary(
            revision: 1,
            configurations: [configuration],
            activeConfigurationID: configuration.id
        )
        library.result = .valid(configuredLibrary)
        await vault.insert(reference)
        await authority.bootstrap(from: configuredLibrary)
        let controller = ScribeProviderV2Controller(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler
        )

        _ = try await controller.setEnabled(
            configurationID: configuration.id,
            enabled: false,
            activeAction: nil,
            confirmed: false,
            cancelActiveAction: {}
        )
        #expect(await vault.staged == [reference])
        guard case let .valid(disabledLibrary) = library.result else {
            Issue.record("Expected disabled library"); return
        }
        #expect(disabledLibrary.activeConfigurationID == nil)
        #expect(disabledLibrary.configurations.first?.isEnabled == false)

        _ = try await controller.remove(
            configurationID: configuration.id,
            activeAction: nil,
            confirmed: false,
            cancelActiveAction: {}
        )
        guard case let .valid(removedLibrary) = library.result else {
            Issue.record("Expected committed empty library"); return
        }
        #expect(removedLibrary.configurations.isEmpty)
        #expect(await vault.staged.isEmpty)
        #expect(!(await authority.verify(receipt)))
    }

    @Test
    func removeProtectsSharedLegacyReferenceAndUnreadableLegacyBlocksDeletion() async throws {
        for unreadableLegacy in [false, true] {
            let library = U5LibraryStore()
            let legacy = U5LegacyStore()
            let vault = U5Vault()
            let authority = ScribeProviderConsentAuthority()
            let ledger = U5LedgerStore()
            let reconciler = ScribeCredentialReconciler(
                libraryStore: library, legacyStore: legacy, ledgerStore: ledger, vault: vault
            )
            let receipt = Self.receipt(for: .openAIDirect)
            let raw = ScribeCredentialReference(rawValue: unreadableLegacy ? "unreadable" : "shared")
            let reference = ScribeStoredCredentialReference(domain: .inherited, opaqueReference: raw)
            let configuration = try U5Fixtures.configuration(
                kind: .openAIDirect, model: "gpt-test", receipt: receipt, reference: reference
            )
            library.result = .valid(ScribeProviderLibrary(
                revision: 1, configurations: [configuration], activeConfigurationID: configuration.id
            ))
            legacy.result = unreadableLegacy
                ? .rejected(.malformed)
                : .valid(try ScribeProviderConfiguration.deepSeek(
                    credentialReference: raw, acceptedAt: Date(timeIntervalSince1970: 5)
                ))
            await vault.insert(reference)
            await authority.bootstrap(from: try #require({
                if case let .valid(value) = library.result { return value }
                return nil
            }()))
            let controller = ScribeProviderV2Controller(
                libraryStore: library, vault: vault, consentAuthority: authority, reconciler: reconciler
            )

            if unreadableLegacy {
                await #expect(throws: ScribeProviderConnectionError.retainedStoreUnreadable) {
                    _ = try await controller.remove(
                        configurationID: configuration.id,
                        activeAction: nil,
                        confirmed: false,
                        cancelActiveAction: {}
                    )
                }
            } else {
                _ = try await controller.remove(
                    configurationID: configuration.id,
                    activeAction: nil,
                    confirmed: false,
                    cancelActiveAction: {}
                )
            }
            #expect(await vault.staged.contains(reference))
            guard case let .valid(committed) = library.result else {
                Issue.record("Removal must remain committed"); continue
            }
            #expect(committed.configurations.isEmpty)
        }
    }

    @Test
    func allFiveKindsAreExplicitAndNoneIsAFallbackRecipient() async throws {
        for kind in [
            ScribeProviderKind.openAIDirect, .openRouter, .deepSeek, .advanced
        ] {
            let library = U5LibraryStore()
            let vault = U5Vault()
            let authority = ScribeProviderConsentAuthority()
            let reconciler = ScribeCredentialReconciler(
                libraryStore: library,
                legacyStore: U5LegacyStore(),
                ledgerStore: U5LedgerStore(),
                vault: vault
            )
            let receipt = Self.receipt(for: kind)
            let reference = ScribeStoredCredentialReference(
                domain: .candidate, opaqueReference: .init(rawValue: "\(kind.rawValue)-key")
            )
            let model = kind == .deepSeek ? "deepseek-v4-flash" : "model"
            let configuration = try U5Fixtures.configuration(
                kind: kind, model: model, receipt: receipt, reference: reference
            )
            let persisted = ScribeProviderLibrary(
                revision: 1, configurations: [configuration], activeConfigurationID: configuration.id
            )
            library.result = .valid(persisted)
            await vault.insert(reference)
            await authority.bootstrap(from: persisted)
            let controller = ScribeProviderV2Controller(
                libraryStore: library,
                vault: vault,
                consentAuthority: authority,
                reconciler: reconciler
            )
            let action = try await controller.actionForNewRequest()
            #expect(action.destination.providerKind == kind)
        }

        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library,
            legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(),
            vault: vault
        )
        let local = try ScribeProviderLibraryConfiguration(
            kind: .legacyLocal,
            displayName: "On-device provider",
            normalizedOrigin: "local://this-mac",
            baseURL: URL(string: "local://this-mac")!,
            requestURL: URL(string: "local://this-mac")!,
            selectedModelID: "local",
            catalogID: nil,
            disclosureVersion: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10),
            lastValidatedAt: Date(timeIntervalSince1970: 20),
            credentialReference: .init(rawValue: "local-placeholder"),
            isEnabled: true
        )
        library.result = .valid(ScribeProviderLibrary(
            revision: 1, configurations: [local], activeConfigurationID: local.id
        ))
        let localController = ScribeProviderV2Controller(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            legacyLocalProvider: MockScribeProvider()
        )
        let localAction = try await localController.actionForNewRequest()
        #expect(localAction.destination.providerKind == .legacyLocal)
        #expect(localAction.actionIdentity?.configurationID == local.id)
        #expect(localAction.actionIdentity?.consentReceiptID == nil)
    }

    private static func receipt(for kind: ScribeProviderKind) -> ScribeProviderConsentReceipt {
        let origin: String
        let routing: ScribeProviderRoutingPolicy
        let retention: ScribeProviderRetentionPolicy
        let data: ScribeProviderDataPolicy
        switch kind {
        case .openAIDirect:
            origin = "https://api.openai.com"; routing = .directSingleModel
            retention = .requestStorageDisabled; data = .providerPolicyApplies
        case .openRouter:
            origin = "https://openrouter.ai"; routing = .zeroDataRetentionSingleModel
            retention = .zeroDataRetentionRequired; data = .collectionDenied
        case .deepSeek:
            origin = "https://api.deepseek.com"; routing = .providerControlledSingleModel
            retention = .providerControlled; data = .providerControlled
        case .advanced:
            origin = "https://custom.example"; routing = .providerControlledSingleModel
            retention = .providerControlled; data = .providerControlled
        case .legacyLocal:
            fatalError("Legacy Local has no remote consent")
        }
        return ScribeProviderConsentIssuer.issue(
            providerKind: kind,
            recipientOrigin: origin,
            routingPolicy: routing,
            retentionPolicy: retention,
            dataPolicy: data,
            disclosureRevision: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
