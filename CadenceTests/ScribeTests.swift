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
        #expect(ScribeIntent.compose.contextScope == .none)
        #expect(ScribeIntent.respond.contextScope == .selectedText)
        #expect(ScribeIntent.edit.contextScope == .selectedText)
        #expect(ScribeIntentPickerResult.cancelled.intent == nil)
        #expect(ScribeIntentPickerResult.selected(.edit).intent == .edit)
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
        let request = Self.providerRequest()

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
        let request = Self.providerRequest()

        await #expect(throws: ScribeProviderError.emptyResult) {
            try await provider.generate(request)
        }
    }

    @Test
    func mockProviderRejectsMalformedAndOversizedOutput() async {
        let malformed = MockScribeProvider(responses: [.success("Draft\u{0000}text")])
        let oversized = MockScribeProvider(
            responses: [.success(String(repeating: "a", count: ScribeOutputPolicy.maximumUTF8Bytes + 1))]
        )
        let request = Self.providerRequest()

        await #expect(throws: ScribeProviderError.invalidResult) {
            try await malformed.generate(request)
        }
        await #expect(throws: ScribeProviderError.resultTooLarge) {
            try await oversized.generate(request)
        }
    }

    @Test
    func mockProviderCooperatesWithTaskCancellation() async {
        let provider = MockScribeProvider(
            responses: [.delayedSuccess("Late result", .seconds(10))]
        )
        let request = Self.providerRequest()
        let task = Task { try await provider.generate(request) }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
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
            let request = Self.providerRequest()

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
        #expect(ScribeSessionState.generatingSlow(requestID: requestID).requestID == requestID)
        #expect(ScribeSessionState.reviewing(result).requestID == requestID)
        #expect(ScribeSessionState.idle.requestID == nil)
    }

    private static func providerRequest(id: UUID = UUID()) -> ScribeProviderRequest {
        ScribeProviderRequest(
            id: id,
            input: ProviderSafeScribeInput(
                systemMessage: "Fixture system message",
                userMessage: "Fixture user message"
            )
        )
    }
}
