import Foundation
import Testing
@testable import Cadence

/// U12 privacy and consent proofs: setup-only receipts, synthetic allowlists,
/// analytics exclusion, and recursive canary taxonomy.
@MainActor
struct ScribePrivacyTests {
    static let privacyCanaries = [
        "SCRIBE_TRANSCRIPT_CANARY_74A9",
        "SCRIBE_SELECTION_CANARY_38F2",
        "SCRIBE_KEY_CANARY_SK_91D0",
        "SCRIBE_ORIGIN_CANARY_55BC",
        "SCRIBE_MODEL_CANARY_0E27",
        "SCRIBE_APP_CANARY_6A44",
        "SCRIBE_GUIDANCE_CANARY_9B18",
        "SCRIBE_PROMPT_CANARY_2CC1",
        "SCRIBE_RESPONSE_CANARY_8D13",
        "SCRIBE_PID_CANARY_7E19",
        "/tmp/SCRIBE_PATH_CANARY_6F31",
        "com.example.ScribeCanary_3D72"
    ]

    @Test
    func setupConsentIsRequiredBeforeCredentialCanReachDiscoveryOrConnection() async {
        let authority = ScribeProviderConsentAuthority()
        let session = ScribeProviderSetupSession(consentAuthority: authority)
        await session.providerSwitched(to: .openAIDirect)

        #expect(await session.authorizedReceipt(for: .openAIDirect, origin: "https://api.openai.com") == nil)

        let receipt = await authority.issueEphemeral(
            providerKind: .openAIDirect,
            recipientOrigin: "https://api.openai.com",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled,
            dataPolicy: .providerPolicyApplies
        )
        #expect(await session.authorizeDisclosure(receipt))
        #expect(await session.authorizedReceipt(for: .openAIDirect, origin: "https://api.openai.com") == receipt)
        #expect(await session.authorizedReceipt(for: .openAIDirect, origin: "https://wrong.example") == nil)

        await session.providerSwitched(to: .openRouter)
        #expect(session.disclosureAuthorization == nil)
        #expect(await session.authorizedReceipt(for: .openAIDirect, origin: "https://api.openai.com") == nil)
    }

    @Test
    func dismissalClearsDisclosureAuthorizationAlongsideCredentialMemory() async {
        let authority = ScribeProviderConsentAuthority()
        let session = ScribeProviderSetupSession(consentAuthority: authority)
        await session.providerSwitched(to: .openRouter)
        let receipt = await authority.issueEphemeral(
            providerKind: .openRouter,
            recipientOrigin: "https://openrouter.ai",
            routingPolicy: .zeroDataRetentionSingleModel,
            retentionPolicy: .zeroDataRetentionRequired,
            dataPolicy: .collectionDenied
        )
        #expect(await session.authorizeDisclosure(receipt))
        _ = session.prepareAttempt(providerKind: .openRouter, credential: "SCRIBE_KEY_CANARY_SK_91D0")
        session.setModelSearchQuery("SCRIBE_MODEL_CANARY_0E27")

        await session.dismiss()
        #expect(session.credentialBuffer.isEmpty)
        #expect(session.modelSearchQuery.isEmpty)
        #expect(session.selectedModelID == nil)
        #expect(session.disclosureAuthorization == nil)
        #expect(session.providerKind == nil)
        #expect(await session.authorizedReceipt(for: .openRouter, origin: "https://openrouter.ai") == nil)
    }

    @Test
    func appModelPublicConnectEntrypointsGateBeforeTransportOrCredentialStaging() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Cadence/App/AppModel.swift"),
            encoding: .utf8
        )
        for function in [
            "connectDeepSeekForScribe",
            "connectAdvancedScribeProvider",
            "connectOpenAIForScribe",
            "connectOpenRouterForScribe"
        ] {
            let body = try #require(functionBody(named: function, in: source))
            let guardOffset = try #require(body.range(of: "authorizedReceipt"))
            let transportOffset = try #require(
                body.range(
                    of: function == "connectOpenAIForScribe" || function == "connectOpenRouterForScribe"
                        ? "connectCatalogV2"
                        : "connectV2"
                )
            )
            #expect(guardOffset.lowerBound < transportOffset.lowerBound)
            #expect(body.contains("ScribeProviderConnectionError.consentRequired"))
        }

        let discovery = try #require(functionBody(named: "discoverScribeModels", in: source))
        #expect(discovery.contains("authorizedReceipt"))
        #expect(discovery.contains("disclosureAccepted"))
    }

    @Test
    func privacyCanaryScriptListsFullU12Taxonomy() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/verify_scribe_privacy_canaries.sh"),
            encoding: .utf8
        )
        for canary in Self.privacyCanaries {
            #expect(script.contains(canary), "Missing canary \(canary)")
        }
        #expect(script.contains("Evidence bundle is invalid") || script.contains("FAILED"))
    }

    @Test
    func privacyDocumentationCoversDirectDictationAndFirstClassProviders() throws {
        let privacy = try String(
            contentsOf: repositoryRoot.appendingPathComponent("docs/privacy.md"),
            encoding: .utf8
        )
        #expect(privacy.contains("setup-only consent receipt"))
        #expect(privacy.contains("selected text"))
        #expect(!privacy.localizedCaseInsensitiveContains("For Respond or Edit only"))
        #expect(privacy.contains("### OpenAI Direct") || privacy.contains("### OpenAI"))
        #expect(privacy.contains("### OpenRouter"))
        #expect(privacy.contains("https://api.openai.com"))
        #expect(privacy.contains("https://openrouter.ai") || privacy.contains("openrouter.ai"))
        #expect(privacy.contains("does not send audio"))
    }

    @Test
    func diagnosticExportRejectsPrivacyCanariesAndModelOriginSecrets() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let storage = InMemoryPrivacyDiagnosticsStorage()
        let service = ScribeDiagnosticsService(storage: storage, now: { now })
        await service.record(.init(
            kind: .generationCompleted,
            phase: .generation,
            provider: .openAIDirect,
            outcome: .success,
            latency: .underOneSecond,
            attempt: .first,
            retry: .none,
            appAdaptationEnabled: true,
            fallbackUsed: false
        ))
        await service.flush()
        let ringData = try #require(await storage.savedData)
        let exportData = try await ScribeDiagnosticsExportService.makeExport(
            events: service.events(),
            generatedAt: now,
            appVersion: "1.0",
            build: "100",
            macOSMajorVersion: 15,
            readiness: .ready,
            permissions: .init(microphone: true, accessibility: true, inputMonitoring: true),
            provider: .openAIDirect,
            appAdaptationEnabled: true
        )
        for data in [ringData, exportData] {
            let text = String(decoding: data, as: UTF8.self)
            for canary in Self.privacyCanaries {
                #expect(!text.contains(canary))
            }
            #expect(!text.contains("api.openai.com"))
            #expect(!text.contains("sk-"))
            #expect(!text.contains("SCRIBE_TRANSCRIPT"))
            #expect(!text.contains("gpt-4"))
        }
    }

    @Test
    func syntheticQualityCorpusContainsNoCanariesOrSelectedTextPaths() throws {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "CadenceTests/Fixtures/AdaptiveScribe/quality-corpus.json"
        ))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try #require(object["cases"] as? [[String: Any]])
        let encoded = String(decoding: data, as: UTF8.self)
        for canary in Self.privacyCanaries {
            #expect(!encoded.contains(canary))
        }
        #expect(cases.allSatisfy { $0["selection"] == nil && $0["intent"] == nil })
        #expect(object["syntheticOnly"] as? Bool == true)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func functionBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        // Next top-level method at the same indentation, or end of type.
        let searchRange = start.upperBound..<source.endIndex
        if let end = source.range(of: "\n    func ", range: searchRange)
            ?? source.range(of: "\n    private func ", range: searchRange)
            ?? source.range(of: "\n    /// ", range: searchRange) {
            return String(source[start.lowerBound..<end.lowerBound])
        }
        return String(source[start.lowerBound...])
    }
}

private actor InMemoryPrivacyDiagnosticsStorage: ScribeDiagnosticsPersisting {
    private(set) var savedData: Data?

    func load() async throws -> Data? { savedData }
    func save(_ data: Data) async throws { savedData = data }
    func clear() async throws { savedData = nil }
}
