import Foundation
import Testing
@testable import Cadence

struct ScribeActionPolicyTests {
    @Test
    func everyRuntimeStateHasOneSafeHierarchy() {
        let requestID = UUID()
        let result = ScribeResult(requestID: requestID, text: "Draft")
        let states: [ScribeSessionState] = [
            .idle,
            .choosingIntent,
            .listening(requestID: requestID, intent: .compose),
            .transcribing(requestID: requestID),
            .generating(requestID: requestID),
            .reviewing(result),
            .insertionRecovery(result),
            .inserting(requestID: requestID),
            .succeeded(requestID: requestID),
            .cancelled(requestID: requestID),
            .failed(requestID: requestID, error: .offline)
        ]

        for state in states {
            let actions = ScribeActionPolicy.actions(
                for: state,
                hasLiteralTranscript: true,
                canRetryGeneration: true
            )
            #expect(ScribeActionPolicy.isValid(actions))
        }
    }

    @Test
    func insertionRecoveryNeverRegeneratesAndKeepsDraftActions() {
        let result = ScribeResult(requestID: UUID(), text: "Draft")
        let actions = ScribeActionPolicy.actions(
            for: .insertionRecovery(result),
            hasLiteralTranscript: true,
            canRetryGeneration: true
        )

        #expect(actions.map(\.title) == ["Discard draft", "Copy draft", "Return and insert"])
        #expect(!actions.contains { $0.title.localizedCaseInsensitiveContains("again") })
    }
}
