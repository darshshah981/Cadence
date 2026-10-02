import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribePerformanceRecorderTests {
    @Test
    func preflightTimingSurvivesCoordinatorBeginAndIsReadableAtListening() {
        let clock = TestScribePerformanceClock()
        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: clock, sink: sink)
        let action = UUID()
        recorder.begin(actionID: action)
        clock.nanoseconds = 12
        recorder.mark(.permissionsChecked, actionID: action)
        clock.nanoseconds = 25
        recorder.mark(.providerPreflightCompleted, actionID: action)
        clock.nanoseconds = 30
        recorder.mark(.transcriptionConfigured, actionID: action)
        recorder.begin(actionID: action) // Coordinator must not reset the shortcut clock.
        clock.nanoseconds = 47
        recorder.mark(.targetPinned, actionID: action)
        clock.nanoseconds = 65
        recorder.mark(.listening, actionID: action)
        #expect(recorder.elapsedNanoseconds(for: .listening, actionID: action) == 65)
        recorder.finish(actionID: action, outcome: .cancelled)
        #expect(recorder.elapsedNanoseconds(for: .listening, actionID: action) == nil)
        #expect(sink.samples.first?.stages.map(\.stage) == [
            .permissionsChecked, .providerPreflightCompleted, .transcriptionConfigured,
            .targetPinned, .listening
        ])
    }

    @Test
    func recordsOrderedContentFreeActionLocalStagesFromControlledClock() {
        let clock = TestScribePerformanceClock()
        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: clock, sink: sink)
        let action = UUID()

        recorder.begin(actionID: action)
        clock.nanoseconds = 10
        recorder.mark(.targetPinned, actionID: action)
        clock.nanoseconds = 15
        recorder.mark(.listening, actionID: action)
        clock.nanoseconds = 30
        recorder.mark(.firstAudioFrame, actionID: action)
        clock.nanoseconds = 40
        recorder.finish(actionID: action, outcome: .completed)

        #expect(sink.samples == [.init(
            actionID: action,
            stages: [
                .init(stage: .targetPinned, elapsedNanoseconds: 10),
                .init(stage: .listening, elapsedNanoseconds: 15),
                .init(stage: .firstAudioFrame, elapsedNanoseconds: 30),
            ],
            terminalOutcome: .completed,
            totalElapsedNanoseconds: 40
        )])
    }

    @Test
    func duplicateOutOfOrderAndLateMarksCannotContaminateAnAction() {
        let clock = TestScribePerformanceClock()
        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: clock, sink: sink)
        let oldAction = UUID(), newAction = UUID()

        recorder.begin(actionID: oldAction)
        clock.nanoseconds = 5
        recorder.mark(.targetPinned, actionID: oldAction)
        recorder.mark(.targetPinned, actionID: oldAction)
        recorder.mark(.generationStarted, actionID: oldAction)
        recorder.mark(.listening, actionID: oldAction) // backwards callback
        recorder.cancel(actionID: oldAction)

        recorder.begin(actionID: newAction)
        clock.nanoseconds = 10
        recorder.mark(.listening, actionID: oldAction) // late callback from prior invocation
        recorder.mark(.targetPinned, actionID: newAction)
        clock.nanoseconds = 12
        recorder.cancel(actionID: newAction)

        #expect(sink.samples.count == 2)
        #expect(sink.samples[0].stages == [
            .init(stage: .targetPinned, elapsedNanoseconds: 5),
            .init(stage: .generationStarted, elapsedNanoseconds: 5)
        ])
        #expect(sink.samples[1].stages == [.init(stage: .targetPinned, elapsedNanoseconds: 5)])
        #expect(sink.samples.allSatisfy { $0.terminalOutcome == .cancelled })
    }

    @Test
    func skippedStagesRemainValidWhileDuplicateAndBackwardMarksAreIgnored() {
        let clock = TestScribePerformanceClock()
        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: clock, sink: sink)
        let action = UUID()

        recorder.begin(actionID: action)
        clock.nanoseconds = 10
        recorder.mark(.listening, actionID: action) // no audio frame in a silent/mock run
        clock.nanoseconds = 20
        recorder.mark(.generationStarted, actionID: action) // skips transcription milestone
        recorder.mark(.listening, actionID: action)
        recorder.mark(.firstAudioFrame, actionID: action)
        recorder.finish(actionID: action, outcome: .completed)

        #expect(sink.samples[0].stages == [
            .init(stage: .listening, elapsedNanoseconds: 10),
            .init(stage: .generationStarted, elapsedNanoseconds: 20),
        ])
    }

    @Test
    func duplicateBeginDoesNotResetClockAndNewInvocationCancelsPriorAction() {
        let clock = TestScribePerformanceClock()
        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: clock, sink: sink)
        let first = UUID(), second = UUID()

        recorder.begin(actionID: first)
        clock.nanoseconds = 10
        recorder.begin(actionID: first)
        recorder.mark(.targetPinned, actionID: first)
        clock.nanoseconds = 15
        recorder.begin(actionID: second) // caller omitted prior cleanup
        recorder.mark(.listening, actionID: first) // late callback cannot reach new action
        clock.nanoseconds = 25
        recorder.mark(.listening, actionID: second)
        recorder.cancel(actionID: second)

        #expect(sink.samples.count == 2)
        #expect(sink.samples[0] == .init(actionID: first,
                                         stages: [.init(stage: .targetPinned, elapsedNanoseconds: 10)],
                                         terminalOutcome: .cancelled, totalElapsedNanoseconds: 15))
        #expect(sink.samples[1] == .init(actionID: second,
                                         stages: [.init(stage: .listening, elapsedNanoseconds: 10)],
                                         terminalOutcome: .cancelled, totalElapsedNanoseconds: 10))
    }

    @Test
    func noSinkIsDisabledAndClockRegressionIsClamped() {
        let clock = TestScribePerformanceClock()
        let disabled = ScribePerformanceRecorder(clock: clock)
        let action = UUID()
        disabled.begin(actionID: action)
        clock.nanoseconds = 50
        disabled.mark(.targetPinned, actionID: action)
        disabled.finish(actionID: action, outcome: .failed)
        #expect(!disabled.isEnabled)

        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: clock, sink: sink)
        recorder.begin(actionID: action)
        clock.nanoseconds = 10
        recorder.mark(.targetPinned, actionID: action)
        recorder.finish(actionID: action, outcome: .failed)
        #expect(sink.samples[0].stages[0].elapsedNanoseconds == 0)
        #expect(sink.samples[0].totalElapsedNanoseconds == 0)
    }

    @Test
    func boundedRawSampleBufferComputesP50AndP95WithoutClaimingABudgetPass() {
        let buffer = ScribePerformanceSampleBuffer(maximumSamples: 3)
        for total in [10, 20, 100, 40] as [UInt64] {
            buffer.record(.init(actionID: UUID(), stages: [], terminalOutcome: .completed, totalElapsedNanoseconds: total))
        }
        // The oldest sample was evicted: raw retained values are 20, 40, 100.
        #expect(buffer.samples.map(\.totalElapsedNanoseconds) == [20, 100, 40])
        #expect(buffer.summary() == .init(sampleCount: 3, p50Nanoseconds: 40, p95Nanoseconds: 100))
    }
}

private final class TestScribePerformanceClock: @unchecked Sendable, ScribePerformanceClock {
    var nanoseconds: UInt64 = 0
    func nowNanoseconds() -> UInt64 { nanoseconds }
}
