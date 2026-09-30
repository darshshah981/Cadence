#if canImport(FoundationModels)
import Foundation
import Testing
@testable import Cadence

/// Opt-in synthetic quality check. It uses the actual local provider and the
/// same prompt compiler as runtime, without microphone, app content or network.
struct ScribeSessionMemoryOnDeviceEvaluationTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/tmp/CadenceEvalSessionMemoryEnabled")))
    func delayedRefundFactProducesGroundedUpdateRequest() async throws {
        guard #available(macOS 26.0, *) else {
            Issue.record("The on-device model requires macOS 26 for this evaluation")
            return
        }
        let provider = FoundationModelsScribeProvider()
        guard provider.capabilities.contains(.semanticGeneration) else {
            Issue.record("The on-device model is unavailable for the session-memory evaluation")
            return
        }
        let request = ScribeRequest.directDictation(
            processedDictation: "Ask for an update on the refund."
        )
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: request, destination: .legacyLocal,
            memoryFacts: ["The refund is delayed."]
        )
        let result = try await provider.generate(.init(id: request.id, input: input))
        let draft = result.text.lowercased()
        #expect(draft.contains("refund"))
        #expect(draft.contains("update") || draft.contains("status"))
        #expect(draft.contains("delay"))
        #expect(!draft.contains("approved"))
        #expect(!draft.contains("issued"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/tmp/CadenceEvalSessionMemoryEnabled")))
    func ellipticalFollowUpUsesTheSingleVerifiedFactWithoutClaimingResolution() async throws {
        guard #available(macOS 26.0, *) else {
            Issue.record("The on-device model requires macOS 26 for this evaluation")
            return
        }
        let provider = FoundationModelsScribeProvider()
        guard provider.capabilities.contains(.semanticGeneration) else {
            Issue.record("The on-device model is unavailable for the session-memory evaluation")
            return
        }
        let request = ScribeRequest.directDictation(processedDictation: "Ask for an update.")
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: request, destination: .legacyLocal,
            memoryFacts: ["The refund is delayed."]
        )
        let result = try await provider.generate(.init(id: request.id, input: input))
        let draft = result.text.lowercased()
        #expect(draft.contains("refund"))
        #expect(draft.contains("delay"))
        #expect(draft.contains("update") || draft.contains("status"))
        #expect(!draft.contains("approved"))
        #expect(!draft.contains("issued"))
    }
}
#endif
