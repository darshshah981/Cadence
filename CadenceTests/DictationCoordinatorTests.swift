import Foundation
import Testing
@testable import Cadence

@MainActor
struct DictationCoordinatorTests {
    @Test
    func noTargetFailsBeforeEngineOrAudioAndReleasesLease() async {
        let fixture = DictationCoordinatorFixture(target: nil)
        await fixture.coordinator.startDictation()

        #expect(fixture.engine.startCount == 0)
        #expect(fixture.audio.startCount == 0)
        #expect(fixture.arbiter.activeKind == nil)
        #expect(fixture.insertion.values.isEmpty)
    }

    @Test
    func focusRaceDuringAtomicCaptureReleasesLeaseBeforeEngineOrAudio() async {
        let fixture = DictationCoordinatorFixture(target: Self.capture())
        fixture.authority.suspendThenThrow = true
        let start = Task { await fixture.coordinator.startDictation() }
        await fixture.authority.waitUntilCaptureSuspends()
        #expect(fixture.arbiter.activeKind == .dictation)
        fixture.authority.releaseCapture()
        await start.value

        #expect(fixture.engine.startCount == 0)
        #expect(fixture.audio.startCount == 0)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func focusSwitchBlocksInsertionWithoutRedirectAndPreservesProcessedTranscript() async {
        let fixture = DictationCoordinatorFixture(target: Self.capture())
        var transcripts: [String] = []
        fixture.coordinator.onTranscript = { text, _ in transcripts.append(text) }
        await fixture.coordinator.startDictation()
        fixture.authority.verifyError = .targetChanged
        await fixture.coordinator.finishDictation()

        #expect(transcripts == ["Keep this transcript"])
        #expect(fixture.insertion.values.isEmpty)
        #expect(fixture.authority.verifyCount == 1)
    }

    @Test
    func targetPinsAtAcceptedCaptureAndClearsOnlyExactTokenAtIdle() async {
        let capture = Self.capture()
        let fixture = DictationCoordinatorFixture(target: capture)
        var pinned: [UUID] = []
        var cleared: [UUID] = []
        fixture.coordinator.onTargetPin = { target, _ in pinned.append(target.id) }
        fixture.coordinator.onTargetClear = { cleared.append($0) }
        await fixture.coordinator.startDictation()
        #expect(pinned == [capture.id])
        await fixture.coordinator.finishDictation()
        #expect(cleared.isEmpty)
        fixture.coordinator.presentLogoIdle()

        #expect(cleared == [capture.id])
        #expect(fixture.insertion.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } == ["Keep this transcript"])
    }

    private static func capture() -> ApplicationTargetCapture {
        .init(
            process: .init(
                processIdentifier: 88,
                bundleIdentifier: "com.openai.codex",
                bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"),
                incarnation: UUID()
            ),
            identityRevision: 1,
            captureRevision: 1,
            source: .dictation,
            displayName: "Codex"
        )
    }
}

@MainActor
private final class DictationCoordinatorFixture {
    let authority: DictationTargetAuthorityFake
    let engine = DictationEngineFake()
    let audio = DictationAudioFake()
    let insertion = DictationInsertionFake()
    let arbiter = VoiceSessionArbiter()
    let coordinator: DictationCoordinator

    init(target: ApplicationTargetCapture?) {
        authority = DictationTargetAuthorityFake(target: target)
        coordinator = DictationCoordinator(
            hotkeyService: HotkeyService(bindings: []),
            permissionsService: DictationPermissionsFake(),
            audioCaptureService: audio,
            transcriptionEngine: engine,
            textInsertionService: insertion,
            hudController: HUDWindowController(),
            analytics: AnalyticsService(isEnabled: false),
            feedbackService: DictationFeedbackFake(),
            sessionArbiter: arbiter,
            targetAuthority: authority,
            personalizationStore: PersonalizationStore(defaults: UserDefaults())
        )
    }
}

@MainActor
private final class DictationTargetAuthorityFake: ApplicationTargetAuthorizing {
    var target: ApplicationTargetCapture?
    var verifyError: ApplicationTargetAuthorityError?
    var suspendThenThrow = false
    private var captureSuspended = false
    private var captureContinuation: CheckedContinuation<Void, Never>?
    private(set) var verifyCount = 0
    init(target: ApplicationTargetCapture?) { self.target = target }
    func capture(source: ApplicationTargetCapture.Source) async throws -> ApplicationTargetCapture {
        if suspendThenThrow {
            captureSuspended = true
            await withCheckedContinuation { captureContinuation = $0 }
            throw ApplicationTargetAuthorityError.targetChanged
        }
        guard let target else { throw ApplicationTargetAuthorityError.noExternalTarget }
        return target
    }
    func verify(_ capture: ApplicationTargetCapture) async throws {
        verifyCount += 1
        if let verifyError { throw verifyError }
    }
    func enrich(processIdentifier: Int32, bundleIdentifier: String?) -> ApplicationProcessIdentity? { nil }
    func enrichCapture(id: UUID, processIdentifier: Int32, bundleIdentifier: String?) -> ApplicationTargetCapture? { nil }
    func matchesCurrent(_ identity: ApplicationProcessIdentity) -> Bool { true }
    func waitUntilCaptureSuspends() async {
        while !captureSuspended { await Task.yield() }
    }
    func releaseCapture() {
        captureContinuation?.resume()
        captureContinuation = nil
    }
}

@MainActor
private final class DictationPermissionsFake: DictationPermissionsServing {
    func snapshot() -> PermissionsSnapshot {
        .init(
            microphoneGranted: true, accessibilityGranted: true,
            inputMonitoringGranted: true, screenRecordingGranted: false
        )
    }
    func requestMicrophoneAccess() async -> Bool { true }
}

private final class DictationAudioFake: AudioCaptureServing {
    private(set) var startCount = 0
    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) throws { startCount += 1 }
    func stopCapture() -> AudioCaptureSessionMetrics {
        .init(duration: 1, frameCount: 16_000, sampleRate: 16_000, speechDetected: true, speechFrameCount: 16_000, peakLevel: 0.5)
    }
}

private final class DictationEngineFake: TranscriptionEngine {
    private(set) var startCount = 0
    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}
    func isPrepared() async -> Bool { true }
    func prepare() async throws {}
    func startSession() async throws { startCount += 1 }
    func appendAudio(_ chunk: AudioChunk) async {}
    func previewTranscript() async -> PreviewTranscript? { nil }
    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        .init(rawText: "Keep this transcript", cleanedText: "Keep this transcript", duration: 1)
    }
    func cancelSession() async {}
    func statusSummary() async -> String { "ready" }
}

private final class DictationInsertionFake: TextInsertionServing {
    private(set) var values: [String] = []
    func insert(_ text: String) async throws { values.append(text) }
    func deleteLastInsertion() async throws {}
}

@MainActor
private final class DictationFeedbackFake: FeedbackServing {
    var isEnabled = false
    func playActivationSound() {}
}
