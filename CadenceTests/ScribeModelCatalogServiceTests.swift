import Foundation
import Testing
@testable import Cadence

struct ScribeModelCatalogServiceTests {
    @Test
    func exactPastedOpenRouterModelRemainsSelectableWhenDiscoveryHasNoMatch() async {
        let service = ScribeModelCatalogService(
            transport: U4RecordingTransport(results: []),
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )

        let results = await service.searchModels(
            for: .openRouter,
            matching: "deepseek/deepseek-v4-pro"
        )

        #expect(results.map(\.modelID) == ["deepseek/deepseek-v4-pro"])
        #expect(results.first?.source == .custom)
        #expect(results.first?.compatibility == .requiresValidation)
    }

    @Test
    func missingForgedAndRevokedReceiptsFailBeforeAnyIO() async throws {
        let transport = U4RecordingTransport(results: [])
        let issued = Self.receipt(provider: .openRouter)
        let forged = Self.receipt(provider: .openRouter)
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in Issue.record("Credential must remain unread"); return "key" },
            consentVerifier: { receipt in receipt.id == issued.id }
        )
        #expect(await service.refreshOpenRouter(
            selectedModelID: "model", consentReceipt: nil
        ) == .needsAttention(selectedModelID: "model"))
        #expect(await service.refreshOpenRouter(
            selectedModelID: "model", consentReceipt: forged
        ) == .needsAttention(selectedModelID: "model"))

        let denyingService = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in Issue.record("Credential must remain unread"); return "key" }
        )
        #expect(await denyingService.refreshOpenRouter(
            selectedModelID: "model", consentReceipt: issued
        ) == .needsAttention(selectedModelID: "model"))
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func wrongMaterialConsentFailsBeforeCredentialOrTransportIO() async throws {
        let transport = U4RecordingTransport(results: [])
        let credentialReads = U4CredentialReadRecorder()
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { provider in
                credentialReads.record(provider)
                return "key"
            },
            consentVerifier: { _ in true }
        )
        let invalidReceipts = [
            Self.receipt(provider: .openAIDirect, origin: "https://openrouter.ai"),
            Self.receipt(provider: .openRouter, origin: "https://wrong.example"),
            Self.receipt(provider: .openRouter, routing: .directSingleModel),
            Self.receipt(provider: .openRouter, disclosureRevision: 999),
            Self.receipt(
                provider: .openRouter,
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            ),
            Self.receipt(provider: .openRouter, acceptedAt: Date(timeIntervalSince1970: 0))
        ]
        for receipt in invalidReceipts {
            #expect(await service.refreshOpenRouter(
                selectedModelID: "openai/gpt-test",
                consentReceipt: receipt
            ) == .needsAttention(selectedModelID: "openai/gpt-test"))
        }
        #expect(credentialReads.values.isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func durablePriorValidationSurvivesRelaunchDiscoveryOutage() async throws {
        let transport = U4RecordingTransport(results: [
            .failure(ScribeHTTPTransportError.url(.notConnectedToInternet))
        ])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true },
            priorValidatedSelections: [Self.priorSelection(
                provider: .openRouter,
                modelID: "openai/gpt-test"
            )]
        )
        #expect(await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test",
            consentReceipt: Self.receipt(provider: .openRouter)
        ) == .offlinePreserved(selectedModelID: "openai/gpt-test"))
    }

    @Test(arguments: [
        Result<ScribeHTTPResponse, Error>.success(U4Fixtures.response(
            url: URL(string: "https://openrouter.ai/api/v1/models/user")!,
            body: #"{"data":"malformed"}"#
        )),
        .failure(ScribeHTTPTransportError.bodyTooLarge)
    ])
    func durablePriorValidationSurvivesMalformedOrOversizedDiscoveryFeed(
        result: Result<ScribeHTTPResponse, Error>
    ) async throws {
        let service = ScribeModelCatalogService(
            transport: U4RecordingTransport(results: [result]),
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true },
            priorValidatedSelections: [Self.priorSelection(
                provider: .openRouter,
                modelID: "openai/gpt-test"
            )]
        )
        #expect(await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test",
            consentReceipt: Self.receipt(provider: .openRouter)
        ) == .offlinePreserved(selectedModelID: "openai/gpt-test"))
    }

    @Test
    func duplicateLiveExactIDsRejectFeedWithoutLastWins() async throws {
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://openrouter.ai/api/v1/models/user")!,
            body: #"{"data":[{"id":"openai/gpt-test","name":"First","architecture":{"output_modalities":["text"]}},{"id":"openai/gpt-test","name":"Second","architecture":{"output_modalities":["text"]}}]}"#
        ))])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true },
            priorValidatedSelections: [Self.priorSelection(
                provider: .openRouter,
                modelID: "openai/gpt-test"
            )]
        )
        #expect(await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test",
            consentReceipt: Self.receipt(provider: .openRouter)
        ) == .offlinePreserved(selectedModelID: "openai/gpt-test"))
        #expect(await service.availableModels(for: .openRouter).isEmpty)
        #expect(await transport.requests.count == 2)
    }

    @Test
    func duplicateOpenAIExactIDsAndMalformedOpenRouterMetadataPreservePriorReadiness() async throws {
        let duplicateOpenAI = ScribeModelCatalogService(
            transport: U4RecordingTransport(results: [.success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/models")!,
                body: #"{"data":[{"id":"gpt-test"},{"id":"gpt-test"}]}"#
            ))]),
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true },
            priorValidatedSelections: [Self.priorSelection(provider: .openAIDirect, modelID: "gpt-test")]
        )
        #expect(await duplicateOpenAI.refreshOpenAI(
            selectedModelID: "gpt-test",
            consentReceipt: Self.receipt(provider: .openAIDirect)
        ) == .offlinePreserved(selectedModelID: "gpt-test"))

        let malformedOpenRouter = ScribeModelCatalogService(
            transport: U4RecordingTransport(results: [
                .success(U4Fixtures.response(
                    url: URL(string: "https://openrouter.ai/api/v1/models/user")!,
                    body: #"{"data":[{"id":"openai/gpt-test","name":"   ","architecture":{"output_modalities":["text"]}}]}"#
                )),
                .success(U4Fixtures.response(
                    url: URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!,
                    body: #"{"data":[{"model_id":"openai/gpt-test"}]}"#
                ))
            ]),
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true },
            priorValidatedSelections: [Self.priorSelection(provider: .openRouter, modelID: "openai/gpt-test")]
        )
        #expect(await malformedOpenRouter.refreshOpenRouter(
            selectedModelID: "openai/gpt-test",
            consentReceipt: Self.receipt(provider: .openRouter)
        ) == .offlinePreserved(selectedModelID: "openai/gpt-test"))
    }

    @Test
    func priorSeedUsesEverySharedLibraryConfigurationInvariant() {
        let invalid = [
            Self.configuration(provider: .openRouter, modelID: "model", displayName: ""),
            Self.configuration(provider: .openRouter, modelID: "model", credential: ""),
            Self.configuration(provider: .openRouter, modelID: "model", catalogID: String(repeating: "c", count: 257)),
            Self.configuration(provider: .openRouter, modelID: "model", origin: "https://wrong.example"),
            Self.configuration(provider: .openRouter, modelID: "model", requestURL: URL(string: "https://openrouter.ai/wrong")!),
            Self.configuration(provider: .openRouter, modelID: "model", enabled: false),
            Self.configuration(provider: .openRouter, modelID: "model", lastValidatedAt: Date(timeIntervalSince1970: 0))
        ]
        for configuration in invalid {
            #expect(ScribePriorValidatedModelSelection(configuration: configuration) == nil)
        }
    }

    @Test
    func searchableCatalogMergesBundledLiveAndCustomByExactID() async throws {
        let bundled = try ScribeBundledModelCatalog(
            revision: 1,
            entries: [
                ScribeSearchableModelEntry(
                    providerKind: .openAIDirect,
                    modelID: "gpt-shared",
                    displayName: "Shared recommended",
                    recommendation: .recommended,
                    source: .bundled,
                    compatibility: .requiresValidation
                )
            ]
        )
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/models")!,
                body: #"{"data":[{"id":"gpt-shared"},{"id":"gpt-live"}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/responses")!,
                body: #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#
            ))
        ])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true },
            bundledCatalog: bundled
        )
        _ = await service.refreshOpenAI(
            selectedModelID: "gpt-shared",
            consentReceipt: Self.receipt(provider: .openAIDirect)
        )
        let models = await service.availableModels(
            for: .openAIDirect,
            customModelID: "gpt-custom"
        )
        #expect(models.map(\.modelID) == ["gpt-custom", "gpt-live", "gpt-shared"])
        #expect(models.first(where: { $0.modelID == "gpt-shared" })?.recommendation == .recommended)
        #expect(models.first(where: { $0.modelID == "gpt-shared" })?.displayName == "Shared recommended")
        #expect(models.first(where: { $0.modelID == "gpt-custom" })?.source == .custom)
    }

    @Test
    func bundledCatalogRejectsUnsupportedDuplicateAndMalformedEntries() throws {
        let entry = ScribeSearchableModelEntry(
            providerKind: .openAIDirect,
            modelID: "gpt-test",
            displayName: "GPT Test",
            recommendation: .recommended,
            source: .bundled,
            compatibility: .requiresValidation
        )
        #expect(throws: ScribeBundledModelCatalogError.unsupportedRevision) {
            _ = try ScribeBundledModelCatalog(revision: 2, entries: [entry])
        }
        #expect(throws: ScribeBundledModelCatalogError.duplicateModel) {
            _ = try ScribeBundledModelCatalog(revision: 1, entries: [entry, entry])
        }
        let malformed = ScribeSearchableModelEntry(
            providerKind: .openAIDirect,
            modelID: "gpt-test",
            displayName: String(repeating: "x", count: 129),
            recommendation: .none,
            source: .bundled,
            compatibility: .requiresValidation
        )
        #expect(throws: ScribeBundledModelCatalogError.invalidEntry) {
            _ = try ScribeBundledModelCatalog(revision: 1, entries: [malformed])
        }
    }

    @Test
    func exactModelChangeUnderSameMaterialContractDoesNotInvalidateConsent() async throws {
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(url: URL(string: "https://api.openai.com/v1/models")!, body: #"{"data":[{"id":"gpt-one"},{"id":"gpt-two"}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://api.openai.com/v1/responses")!, body: #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://api.openai.com/v1/models")!, body: #"{"data":[{"id":"gpt-one"},{"id":"gpt-two"}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://api.openai.com/v1/responses")!, body: #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#))
        ])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )
        let receipt = Self.receipt(provider: .openAIDirect)
        #expect(await service.refreshOpenAI(
            selectedModelID: "gpt-one", consentReceipt: receipt
        ) == .ready(selectedModelID: "gpt-one"))
        #expect(await service.refreshOpenAI(
            selectedModelID: "gpt-two", consentReceipt: receipt
        ) == .ready(selectedModelID: "gpt-two"))
        let validationBodies = await transport.requests.compactMap(\.httpBody)
            .compactMap { String(data: $0, encoding: .utf8) }
            .filter { $0.contains("max_output_tokens") }
        #expect(validationBodies.count == 2)
        #expect(validationBodies[0].contains(#""model":"gpt-one""#))
        #expect(validationBodies[1].contains(#""model":"gpt-two""#))
    }

    @Test
    func discoveryRequiresExplicitAuthorizationAndDoesNoIOWithoutIt() async throws {
        let transport = U4RecordingTransport(results: [])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )
        let state = await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test", consentReceipt: nil
        )
        #expect(state == .needsAttention(selectedModelID: "openai/gpt-test"))
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func openRouterIntersectsTextModelsWithZDRAndNeverSwitchesSelection() async throws {
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/models/user")!,
                body: #"{"data":[{"id":"openai/gpt-test","canonical_slug":"openai/gpt-test-2026","name":"GPT Test","context_length":128000,"supported_parameters":["temperature","max_tokens"],"expiration_date":"2027-01-01","architecture":{"output_modalities":["text"]}},{"id":"image/model","architecture":{"output_modalities":["image"]}},{"id":"missing/privacy","architecture":{"output_modalities":["text"]}}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!,
                body: #"{"data":[{"model_id":"openai/gpt-test"},{"model_id":"image/model"}]}"#
            ))
        ])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )
        let authorization = Self.receipt(provider: .openRouter)
        let state = await service.refreshOpenRouter(
            selectedModelID: "missing/privacy", consentReceipt: authorization
        )
        #expect(state == .needsAttention(selectedModelID: "missing/privacy"))
        #expect(await service.availableModelIDs(for: .openRouter) == ["openai/gpt-test"])
        let searchable = try #require(await service.availableModels(for: .openRouter).first)
        #expect(searchable.displayName == "GPT Test")
        #expect(searchable.canonicalSlug == "openai/gpt-test-2026")
        #expect(searchable.providerDisplayName == "openai")
        #expect(searchable.contextLength == 128_000)
        #expect(searchable.supportedParameters == ["max_tokens", "temperature"])
        #expect(searchable.expiry == "2027-01-01")
        #expect(searchable.searchTerms.contains("GPT Test"))
        #expect(searchable.eligibilityFacts == [
            .authenticatedUserVisible, .textOutput, .zeroDataRetentionEndpoint
        ])
        #expect(searchable.outputModalities == ["text"])
        let requests = await transport.requests
        #expect(requests.map(\.url?.absoluteString) == [
            "https://openrouter.ai/api/v1/models/user",
            "https://openrouter.ai/api/v1/endpoints/zdr"
        ])
    }

    @Test
    func previouslyValidatedSelectionIsPreservedOffline() async throws {
        let first = U4RecordingTransport(results: [
            .success(U4Fixtures.response(url: URL(string: "https://openrouter.ai/api/v1/models/user")!, body: #"{"data":[{"id":"openai/gpt-test","architecture":{"output_modalities":["text"]}}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!, body: #"{"data":[{"model_id":"openai/gpt-test"}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, body: #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"OK"}}]}"#)),
            .failure(ScribeHTTPTransportError.url(.notConnectedToInternet))
        ])
        let service = ScribeModelCatalogService(
            transport: first,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )
        let auth = Self.receipt(provider: .openRouter)
        #expect(await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test", consentReceipt: auth
        ) == .ready(selectedModelID: "openai/gpt-test"))
        let validationRequest = try #require(await first.requests.dropFirst(2).first)
        #expect(validationRequest.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(String(data: try #require(validationRequest.httpBody), encoding: .utf8) ==
            #"{"max_completion_tokens":8,"messages":[{"content":"Return only OK.","role":"system"},{"content":"Cadence provider compatibility check.","role":"user"}],"model":"openai/gpt-test","provider":{"data_collection":"deny","zdr":true},"stream":false}"#)
        #expect(await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test", consentReceipt: auth
        ) == .offlinePreserved(selectedModelID: "openai/gpt-test"))
    }

    @Test
    func openAIVisibilityStillRequiresSyntheticProductionAdapterValidation() async throws {
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://api.openai.com/v1/models")!,
            body: #"{"data":[{"id":"gpt-test"}]}"#
        )), .success(U4Fixtures.response(
            url: URL(string: "https://api.openai.com/v1/responses")!,
            body: #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#
        ))])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )
        let state = await service.refreshOpenAI(
            selectedModelID: "gpt-test",
            consentReceipt: Self.receipt(provider: .openAIDirect)
        )
        #expect(state == .ready(selectedModelID: "gpt-test"))
        let requests = await transport.requests
        let sent = try #require(requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(sent.httpMethod == "GET")
        #expect(sent.allHTTPHeaderFields == ["Authorization": "Bearer key"])
        #expect(requests.last?.url?.absoluteString == "https://api.openai.com/v1/responses")
    }

    @Test
    func openAIVisibilityWithoutAdapterCompatibilityNeedsAttention() async throws {
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/models")!,
                body: #"{"data":[{"id":"gpt-visible"}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://api.openai.com/v1/responses")!,
                body: #"{"status":"in_progress","output":[]}"#
            ))
        ])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )
        #expect(await service.refreshOpenAI(
            selectedModelID: "gpt-visible",
            consentReceipt: Self.receipt(provider: .openAIDirect)
        ) == .needsAttention(selectedModelID: "gpt-visible"))
    }

    @Test
    func modelDisappearanceRetainsExactIdentifierButNeedsAttention() async throws {
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(url: URL(string: "https://openrouter.ai/api/v1/models/user")!, body: #"{"data":[{"id":"openai/gpt-test","architecture":{"output_modalities":["text"]}}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!, body: #"{"data":[{"model_id":"openai/gpt-test"}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, body: #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"OK"}}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://openrouter.ai/api/v1/models/user")!, body: #"{"data":[{"id":"some/replacement","architecture":{"output_modalities":["text"]}}]}"#)),
            .success(U4Fixtures.response(url: URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!, body: #"{"data":[{"model_id":"some/replacement"}]}"#))
        ])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )
        let auth = Self.receipt(provider: .openRouter)
        #expect(await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test", consentReceipt: auth
        ) == .ready(selectedModelID: "openai/gpt-test"))
        #expect(await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test", consentReceipt: auth
        ) == .needsAttention(selectedModelID: "openai/gpt-test"))
    }

    @Test
    func malformedPrivacyOrSchemaDataIsIneligible() async throws {
        let transport = U4RecordingTransport(results: [
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/models/user")!,
                body: #"{"data":[{"id":"openai/gpt-test","architecture":{}}]}"#
            )),
            .success(U4Fixtures.response(
                url: URL(string: "https://openrouter.ai/api/v1/endpoints/zdr")!,
                body: #"{"data":[{"model_id":"openai/gpt-test"}]}"#
            ))
        ])
        let service = ScribeModelCatalogService(
            transport: transport,
            credentialLoader: { _ in "key" },
            consentVerifier: { _ in true }
        )
        #expect(await service.refreshOpenRouter(
            selectedModelID: "openai/gpt-test",
            consentReceipt: Self.receipt(provider: .openRouter)
        ) == .needsAttention(selectedModelID: "openai/gpt-test"))
    }

    private static func priorSelection(
        provider: ScribeProviderKind,
        modelID: String
    ) -> ScribePriorValidatedModelSelection {
        ScribePriorValidatedModelSelection(configuration: configuration(
            provider: provider,
            modelID: modelID
        ))!
    }

    private static func configuration(
        provider: ScribeProviderKind,
        modelID: String,
        displayName: String = "Validated provider",
        credential: String = "validated",
        catalogID: String? = nil,
        origin: String? = nil,
        requestURL: URL? = nil,
        enabled: Bool = true,
        lastValidatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> ScribeProviderLibraryConfiguration {
        let expectedOrigin = provider == .openRouter ? "https://openrouter.ai" : "https://api.openai.com"
        let expectedRequestURL = provider == .openRouter
            ? URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            : URL(string: "https://api.openai.com/v1/responses")!
        return try! ScribeProviderLibraryConfiguration(
            kind: provider,
            displayName: displayName,
            normalizedOrigin: origin ?? expectedOrigin,
            baseURL: URL(string: origin ?? expectedOrigin)!,
            requestURL: requestURL ?? expectedRequestURL,
            selectedModelID: modelID,
            catalogID: catalogID,
            disclosureVersion: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 50),
            lastValidatedAt: lastValidatedAt,
            credentialReference: ScribeCredentialReference(rawValue: credential),
            isEnabled: enabled
        )
    }

    private static func receipt(
        provider: ScribeProviderKind,
        origin: String? = nil,
        routing: ScribeProviderRoutingPolicy? = nil,
        disclosureRevision: Int = ScribeProviderDisclosure.currentVersion,
        id: UUID = UUID(),
        acceptedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> ScribeProviderConsentReceipt {
        ScribeProviderConsentIssuer.issue(
            id: id,
            providerKind: provider,
            recipientOrigin: origin ?? (provider == .openRouter
                ? "https://openrouter.ai"
                : "https://api.openai.com"),
            routingPolicy: routing ?? (provider == .openRouter
                ? .zeroDataRetentionSingleModel
                : .directSingleModel),
            retentionPolicy: provider == .openRouter ? .zeroDataRetentionRequired : .requestStorageDisabled,
            dataPolicy: provider == .openRouter ? .collectionDenied : .providerPolicyApplies,
            disclosureRevision: disclosureRevision,
            acceptedAt: acceptedAt
        )
    }
}

final class U4CredentialReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [ScribeProviderKind] = []
    var values: [ScribeProviderKind] { lock.withLock { storedValues } }
    func record(_ value: ScribeProviderKind) { lock.withLock { storedValues.append(value) } }
}
