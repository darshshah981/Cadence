import Foundation
import Testing
@testable import Cadence

@Suite(.serialized)
struct AdaptiveScribePerformanceTests {
    @Test
    func maximumLiteralParserFixtureStaysBelowFiveMillisecondsAtP95() {
        let transcript = String(repeating: "plain words ", count: 2_700)
        #expect(transcript.utf8.count < ScribeContextService.maximumContextUTF8Bytes)
        _ = ScribeLiteralNormalizer.normalize(transcript, environmentID: .claudeCode)

        let clock = ContinuousClock()
        let durations = (0..<20).map { _ in
            let start = clock.now
            _ = ScribeLiteralNormalizer.normalize(transcript, environmentID: .claudeCode)
            return start.duration(to: clock.now)
        }.sorted()

        #expect(durations[18] < .milliseconds(5))
    }

    @Test
    func recognitionResolutionAndPromptSerializationStayBelowTwentyMillisecondsAtP95() throws {
        let recognizer = WritingEnvironmentRecognizer()
        let target = ScribeTargetIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.tinyspeck.slackmacgap"
        )
        let clock = ContinuousClock()
        _ = recognizer.recognize(target: target, signature: nil)

        let durations = try (0..<100).map { _ in
            let start = clock.now
            let environmentID = recognizer.recognize(target: target, signature: nil)
            let environment = WritingEnvironmentResolver.resolve(
                recognizedEnvironmentID: environmentID,
                adaptationEnabled: true,
                preferenceLoadResult: .absent
            )
            let request = ScribeRequest(
                intent: .compose,
                spokenTranscript: "Write a concise project update.",
                resolvedEnvironment: environment
            )
            _ = try ScribeRequestPolicy.providerSafeInput(
                for: request,
                destination: .deepSeek
            )
            return start.duration(to: clock.now)
        }.sorted()

        #expect(durations[94] < .milliseconds(20))
    }
}
