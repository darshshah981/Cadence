import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeProviderRuntimeTests {
    @Test
    func openRouterSetupRequiresExactLiveTextZDRIntersectionBeforeCommit() async throws {
        let model = "vendor/text-model"
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/models/user")!,
                body: #"{"data":[{"id":"vendor/text-model","architecture":{"output_modalities":["text"]}}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!,
                body: #"{"data":[{"model_id":"vendor/text-model"}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                body: #"{"model":"vendor/text-model","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"OK"}}]}"#
            ))
        ])
        let library = U5LibraryStore()
        let vault = U5Vault()
        let runtime = ScribeProviderRuntime(
            libraryStore: library,
            legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(),
            vault: vault,
            transport: transport
        )
        await runtime.switchSetupProvider(to: .openRouter)
        let receipt = await runtime.consentAuthority.issueEphemeral(
            providerKind: .openRouter,
            recipientOrigin: "https://openrouter.ai",
            routingPolicy: .zeroDataRetentionSingleModel,
            retentionPolicy: .zeroDataRetentionRequired,
            dataPolicy: .collectionDenied
        )
        let candidate = ScribeProviderConnectionCandidate(
            id: UUID(), kind: .openRouter, displayName: "OpenRouter",
            normalizedOrigin: "https://openrouter.ai",
            baseURL: URL(string: "https://openrouter.ai")!,
            requestURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            selectedModelID: model, catalogID: nil,
            consentReceipt: receipt, acceptedAt: receipt.acceptedAt
        )

        let committed = try await runtime.connectCatalogValidated(
            candidate: candidate, credential: "secret"
        )

        #expect(committed.baseURL.absoluteString == "https://openrouter.ai")
        #expect(committed.requestURL.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(ScribeProviderLibraryConfigurationValidator.isValid(committed))
        #expect(library.saveCount == 1)
        #expect(await transport.requests.map(\.url?.absoluteString) == [
            "https://openrouter.ai/api/v1/models/user",
            "https://openrouter.ai/api/v1/endpoints/zdr",
            "https://openrouter.ai/api/v1/chat/completions"
        ])
    }

    @Test
    func openRouterIntersectionFailureNeverStagesOrWrites() async throws {
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/models/user")!,
                body: #"{"data":[{"id":"vendor/model","architecture":{"output_modalities":["text"]}}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!,
                body: #"{"data":[{"model_id":"different/model"}]}"#
            ))
        ])
        let library = U5LibraryStore()
        let vault = U5Vault()
        let runtime = ScribeProviderRuntime(
            libraryStore: library, legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(), vault: vault, transport: transport
        )
        await runtime.switchSetupProvider(to: .openRouter)
        let receipt = await runtime.consentAuthority.issueEphemeral(
            providerKind: .openRouter, recipientOrigin: "https://openrouter.ai",
            routingPolicy: .zeroDataRetentionSingleModel,
            retentionPolicy: .zeroDataRetentionRequired, dataPolicy: .collectionDenied
        )
        let candidate = ScribeProviderConnectionCandidate(
            id: UUID(), kind: .openRouter, displayName: "OpenRouter",
            normalizedOrigin: "https://openrouter.ai",
            baseURL: URL(string: "https://openrouter.ai")!,
            requestURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            selectedModelID: "vendor/model", catalogID: nil,
            consentReceipt: receipt, acceptedAt: receipt.acceptedAt
        )

        await #expect(throws: ScribeProviderConnectionError.validationFailed) {
            _ = try await runtime.connectCatalogValidated(candidate: candidate, credential: "secret")
        }
        #expect(library.saveCount == 0)
        #expect(await vault.staged.isEmpty)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func openAISetupRequiresLiveVisibilityAndSyntheticAdapterBeforeCommit() async throws {
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/models")!,
                body: #"{"data":[{"id":"gpt-exact"}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/responses")!,
                body: #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#
            ))
        ])
        let library = U5LibraryStore()
        let runtime = ScribeProviderRuntime(
            libraryStore: library, legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(), vault: U5Vault(), transport: transport
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
            selectedModelID: "gpt-exact", catalogID: nil,
            consentReceipt: receipt, acceptedAt: receipt.acceptedAt
        )

        _ = try await runtime.connectCatalogValidated(candidate: candidate, credential: "secret")
        #expect(library.saveCount == 1)
        #expect(await transport.requests.map(\.url?.absoluteString) == [
            "https://api.openai.com/v1/models", "https://api.openai.com/v1/responses"
        ])

        await runtime.switchSetupProvider(to: .openAIDirect)
        let offlineReceipt = await runtime.consentAuthority.issueEphemeral(
            providerKind: .openAIDirect, recipientOrigin: "https://api.openai.com",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled, dataPolicy: .providerPolicyApplies
        )
        let offlineCandidate = ScribeProviderConnectionCandidate(
            id: UUID(), kind: .openAIDirect, displayName: "OpenAI",
            normalizedOrigin: "https://api.openai.com",
            baseURL: URL(string: "https://api.openai.com")!,
            requestURL: URL(string: "https://api.openai.com/v1/responses")!,
            selectedModelID: "gpt-exact", catalogID: nil,
            consentReceipt: offlineReceipt, acceptedAt: offlineReceipt.acceptedAt
        )
        await #expect(throws: ScribeProviderConnectionError.validationFailed) {
            _ = try await runtime.connectCatalogValidated(
                candidate: offlineCandidate, credential: "secret"
            )
        }
        #expect(library.saveCount == 1)
    }

    @Test
    func retainedLegacySingleConfigurationIsDecodeEvidenceOnlyAndCannotDispatch() async throws {
        let library = U5LibraryStore()
        let legacy = U5LegacyStore()
        legacy.result = .valid(try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "legacy-only"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        ))
        let runtime = ScribeProviderRuntime(
            libraryStore: library,
            legacyStore: legacy,
            ledgerStore: U5LedgerStore(),
            vault: U5Vault(),
            legacyLocalProvider: MockScribeProvider()
        )

        await runtime.controller.reloadReadiness()
        #expect(runtime.controller.readiness == .setupRequired)
        await #expect(throws: ScribeProviderFailure.self) {
            try await runtime.controller.actionForNewRequest()
        }
    }

    @Test
    func sameProductionGraphPublishesCommittedReadinessAndDismissalCancelsValidation() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let runtime = ScribeProviderRuntime(
            libraryStore: library,
            legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(),
            vault: vault
        )
        await runtime.switchSetupProvider(to: .advanced)
        let receipt = await runtime.consentAuthority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        let candidate = ScribeProviderConnectionCandidate(
            id: UUID(), kind: .advanced, displayName: "Custom",
            normalizedOrigin: "https://custom.example",
            baseURL: URL(string: "https://custom.example")!,
            requestURL: URL(string: "https://custom.example/chat/completions")!,
            selectedModelID: "custom-model", catalogID: nil,
            consentReceipt: receipt, acceptedAt: receipt.acceptedAt
        )
        let gate = RuntimeValidationGate()
        let task = Task {
            try await runtime.manager.connect(candidate: candidate, credential: "secret") { _, _ in
                await gate.wait()
            }
        }
        await gate.waitUntilEntered()
        await runtime.dismissSetup()
        await gate.release()
        await #expect(throws: ScribeProviderConnectionError.staleAttempt) { try await task.value }
        #expect(library.saveCount == 0)
        #expect(await vault.staged.isEmpty)

        await runtime.switchSetupProvider(to: .advanced)
        let committedReceipt = await runtime.consentAuthority.issueEphemeral(
            providerKind: .advanced,
            recipientOrigin: "https://custom.example",
            routingPolicy: .providerControlledSingleModel,
            retentionPolicy: .providerControlled,
            dataPolicy: .providerControlled
        )
        let committedCandidate = ScribeProviderConnectionCandidate(
            id: UUID(), kind: .advanced, displayName: "Custom",
            normalizedOrigin: "https://custom.example",
            baseURL: URL(string: "https://custom.example")!,
            requestURL: URL(string: "https://custom.example/chat/completions")!,
            selectedModelID: "custom-model", catalogID: nil,
            consentReceipt: committedReceipt, acceptedAt: committedReceipt.acceptedAt
        )
        _ = try await runtime.manager.connect(
            candidate: committedCandidate, credential: "secret"
        ) { _, _ in }
        #expect(runtime.controller.readiness == .ready(.advanced))
        #expect(try await runtime.controller.actionForNewRequest().destination.providerKind == .advanced)
    }
}

private actor RuntimeValidationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
