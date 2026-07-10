import Foundation
import Testing
@testable import Cadence

struct ScribeTests {
    @Test
    func intentsRoundTripAndDeclareContextNeeds() throws {
        let encoded = try JSONEncoder().encode(ScribeIntent.allCases)
        let decoded = try JSONDecoder().decode([ScribeIntent].self, from: encoded)

        #expect(decoded == ScribeIntent.allCases)
        #expect(!ScribeIntent.compose.requiresSelectedText)
        #expect(ScribeIntent.respond.requiresSelectedText)
        #expect(ScribeIntent.edit.requiresSelectedText)
    }

    @Test
    func privateModeNeverAdvertisesSemanticGeneration() {
        let readiness = ScribeReadiness(
            privacyMode: .privateMode,
            providerCapabilities: .semanticGeneration,
            permissionsGranted: true
        )

        #expect(!readiness.canGenerate)
        #expect(readiness.canUseLiteralFallback)
        #expect(readiness.blockingReason == .privateMode)
    }

    @Test
    func mockProviderReturnsScriptedResultAndDeduplicatesRequest() async throws {
        let provider = MockScribeProvider(
            responses: [.success("A concise response.")]
        )
        let request = ScribeRequest(
            intent: .respond,
            spokenTranscript: "Decline politely",
            context: ScribeContextSnapshot(
                target: ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                selectedText: "Can you attend tomorrow?"
            )
        )

        let first = try await provider.generate(request)
        let duplicate = try await provider.generate(request)
        let callCount = await provider.generationCount

        #expect(first == duplicate)
        #expect(first.requestID == request.id)
        #expect(first.text == "A concise response.")
        #expect(callCount == 1)
    }

    @Test
    func mockProviderRejectsEmptyOutput() async {
        let provider = MockScribeProvider(responses: [.success("   \n")])
        let request = ScribeRequest(intent: .compose, spokenTranscript: "Write an update")

        await #expect(throws: ScribeProviderError.emptyResult) {
            try await provider.generate(request)
        }
    }

    @Test
    func mockProviderSurfacesOfflineTimeoutAndCancellation() async {
        for failure in [
            ScribeProviderError.offline,
            ScribeProviderError.timedOut,
            ScribeProviderError.cancelled
        ] {
            let provider = MockScribeProvider(responses: [.failure(failure)])
            let request = ScribeRequest(intent: .compose, spokenTranscript: "Write an update")

            await #expect(throws: failure) {
                try await provider.generate(request)
            }
        }
    }

    @Test
    func sessionStateKeepsRequestIdentityAcrossLifecycle() {
        let requestID = UUID()
        let result = ScribeResult(requestID: requestID, text: "Draft")

        #expect(ScribeSessionState.listening(requestID: requestID, intent: .compose).requestID == requestID)
        #expect(ScribeSessionState.generating(requestID: requestID).requestID == requestID)
        #expect(ScribeSessionState.reviewing(result).requestID == requestID)
        #expect(ScribeSessionState.idle.requestID == nil)
    }
}
