import Foundation
import Testing
@testable import Cadence

@MainActor
struct ShortcutFeedbackTests {
    @Test
    func statusReplacementNeverDipsBetweenLabels() {
        for step in 0...140 {
            let elapsed = Double(step) / 1_000
            let outgoing = HUDStatusContentTransition.outgoingOpacity(elapsed: elapsed)
            let incoming = HUDStatusContentTransition.incomingOpacity(elapsed: elapsed)
            #expect(abs(outgoing + incoming - 1) < 0.000_001)
        }
        #expect(HUDStatusContentTransition.incomingOpacity(elapsed: 0) == 0)
        #expect(HUDStatusContentTransition.incomingOpacity(elapsed: 0.14) == 1)
    }

    @Test
    func everyStatusPairKeepsItsContainerAndFootprintThroughCompletion() {
        let statuses: [HUDVisualState] = [
            .preparingModel, .transcribing, .scribeTranscribing, .scribed,
            .inserting, .copying, .copied, .success, .cancelled,
            .error(message: "No speech"), .error(message: "Try again")
        ]
        for from in statuses {
            for to in statuses {
                let model = HUDViewModel()
                model.reduceMotionProvider = { false }
                model.apply(recording(from, level: 0))
                let previous = model.presentation
                let width = model.renderedWidth
                model.apply(recording(to, level: 0))
                model.beginMorph(from: previous, startWidth: width)
                for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    model.setMorphProgress(progress, elapsed: progress * HUDActiveContentTransition.duration)
                    #expect(HUDApplicationCueTransition.usesStableStatusContainer(
                        current: model.presentation.visualState,
                        previous: model.previousPresentation?.visualState
                    ))
                    #expect(model.renderedWidth == width)
                }
                model.finishMorph()
                #expect(HUDApplicationCueTransition.usesStableStatusContainer(
                    current: model.presentation.visualState,
                    previous: model.previousPresentation?.visualState
                ))
                #expect(model.renderedWidth == width)
            }
        }
    }

    @Test
    func statusContainerPreservesRecordingAndRestingMicrophoneHandoffs() {
        #expect(!HUDApplicationCueTransition.usesStableStatusContainer(current: .idle, previous: .success))
        #expect(!HUDApplicationCueTransition.usesStableStatusContainer(current: .transcribing, previous: .idle))
        #expect(!HUDApplicationCueTransition.usesStableStatusContainer(current: .transcribing, previous: .scribeRecording))
        #expect(HUDApplicationCueTransition.usesStableStatusContainer(current: .success, previous: nil))
    }

    @Test(arguments: [160, 3_096, 4_712, 6_328, 7_849, 15_999, 16_000])
    func shortAudioReachesTheWhisperDecoder(_ sampleCount: Int) {
        let options = WhisperKitTranscriptionEngine.decodeOptions(
            for: TranscriptionConfiguration(), sampleCount: sampleCount
        )
        // WhisperKit only enters decoding when content extends past this cutoff.
        // Checking the production options needs no model load or microphone.
        #expect(sampleCount > Int(options.windowClipTime * 16_000))
        #expect(options.noSpeechThreshold == 0.6)
    }

    @Test
    func trimmedSingleWordStillReachesTheWhisperDecoder() {
        let samples = Array(repeating: Float(0), count: 16_000)
            + Array(repeating: Float(0.1), count: 3_200)
            + Array(repeating: Float(0), count: 16_000)
        let configuration = TranscriptionConfiguration()
        let processed = TranscriptionAudioPreprocessor.preprocess(samples, configuration: configuration)
        #expect(processed.count < 16_000)
        let options = WhisperKitTranscriptionEngine.decodeOptions(
            for: configuration, sampleCount: processed.count
        )
        #expect(processed.count > Int(options.windowClipTime * 16_000))
    }

    @Test
    func longerRecordingsKeepTheTrailingSilenceGuard() {
        let options = WhisperKitTranscriptionEngine.decodeOptions(
            for: TranscriptionConfiguration(), sampleCount: 32_000
        )
        #expect(options.windowClipTime == 1)
    }

    @Test
    func fastNoSpeechResultNeverDisplaysTranscribing() async {
        let clock = HUDGateTestClock()
        var states: [HUDVisualState] = []
        let gate = HUDTransientStateGate(wait: { await clock.wait() }) { states.append($0.visualState) }
        gate.submit(recording(.recording(triggerMode: .holdToTalk, showsHint: false), level: 0))
        gate.submit(recording(.transcribing, level: 0))
        await clock.untilWaiting()
        gate.submit(recording(.error(message: "No speech"), level: 0))
        clock.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(states == [.recording(triggerMode: .holdToTalk, showsHint: false), .error(message: "No speech")])
    }

    @Test
    func slowProcessingShowsLatestStageWithoutRestartingDeadline() async {
        let clock = HUDGateTestClock()
        var states: [HUDVisualState] = []
        let gate = HUDTransientStateGate(wait: { await clock.wait() }) { states.append($0.visualState) }
        gate.submit(recording(.scribeTranscribing, level: 0))
        await clock.untilWaiting()
        gate.submit(recording(.preparingModel, level: 0))
        gate.submit(recording(.preparingModel, level: 0))
        #expect(states.isEmpty)
        #expect(clock.waitCount == 1)
        clock.resume()
        for _ in 0..<1_000 where states.isEmpty { await Task.yield() }
        #expect(states == [.preparingModel])
        gate.submit(recording(.success, level: 0))
        #expect(states.last == .success)
    }

    @Test
    func newRecordingAndHiddenHUDCancelPendingProgress() async {
        for replacement in [recording(.scribeRecording, level: 0.5), HUDState.idle] {
            let clock = HUDGateTestClock()
            var states: [HUDState] = []
            let gate = HUDTransientStateGate(wait: { await clock.wait() }) { states.append($0) }
            gate.submit(recording(.copying, level: 0))
            await clock.untilWaiting()
            gate.submit(replacement)
            clock.resume()
            for _ in 0..<20 { await Task.yield() }
            #expect(states == [replacement])
        }
    }

    @Test(arguments: [HUDVisualState.recording(triggerMode: .holdToTalk, showsHint: false), .scribeRecording])
    func liveAudioInterruptsAnEntranceAlreadyInProgress(_ visualState: HUDVisualState) {
        let quiet = makeModel(visualState)
        let voiced = makeModel(visualState)
        // Audio can arrive after the flourish has already become visible.
        for _ in 0..<20 {
            _ = quiet.advanceWaveform(deltaTime: 1 / 60)
            _ = voiced.advanceWaveform(deltaTime: 1 / 60)
        }
        #expect(quiet.displayBars == voiced.displayBars)
        voiced.apply(recording(visualState, level: 0.8))
        _ = quiet.advanceWaveform(deltaTime: 1 / 60)
        _ = voiced.advanceWaveform(deltaTime: 1 / 60)
        #expect(zip(quiet.displayBars, voiced.displayBars).contains { abs($0 - $1) > 0.05 })
    }

    @Test
    func returningToIdleDoesNotDelayAudioInTheNextSession() {
        let state = HUDVisualState.recording(triggerMode: .holdToTalk, showsHint: false)
        let model = makeModel(state)
        model.apply(recording(state, level: 0.8))
        _ = model.advanceWaveform(deltaTime: 1 / 120)
        model.apply(.logoIdle)
        model.apply(recording(state, level: 0.6))
        _ = model.advanceWaveform(deltaTime: 1 / 120)
        #expect(model.displayBars.allSatisfy { $0 > 0 })
        // Response remains smoothed instead of jumping straight to full level.
        #expect(model.displayBars.allSatisfy { $0 < 0.6 })
    }

    @Test
    func silentStartRetainsEntranceAndHiddenHUDStopsAnimating() {
        let model = makeModel(.scribeRecording)
        for _ in 0..<20 { _ = model.advanceWaveform(deltaTime: 1 / 60) }
        #expect(model.displayBars.contains { $0 > 0 })
        model.apply(.idle)
        #expect(!model.advanceWaveform(deltaTime: 1 / 60))
        #expect(model.displayBars.allSatisfy { $0 == 0 })
    }

    private func makeModel(_ state: HUDVisualState) -> HUDViewModel {
        let model = HUDViewModel()
        model.reduceMotionProvider = { false }
        model.apply(.logoIdle)
        model.apply(recording(state, level: 0))
        return model
    }

    private func recording(_ state: HUDVisualState, level: Double) -> HUDState {
        HUDState(visualState: state, subtitle: "", level: level,
                 waveformLevels: Array(repeating: level, count: 16),
                 isVisible: true, showsSubtitle: false)
    }
}

@MainActor
private final class HUDGateTestClock {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waitCount = 0

    func wait() async {
        waitCount += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func untilWaiting() async {
        while continuation == nil { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
