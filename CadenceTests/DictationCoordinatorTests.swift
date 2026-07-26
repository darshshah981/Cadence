import Foundation
import Testing
@testable import Cadence

@MainActor
struct DictationCoordinatorTests {
    @Test
    func waveformUsesRollingSpeechEnvelopeInsteadOfUniformSampleBuckets() {
        let quiet = DictationCoordinator.updatedWaveformLevels(
            previous: Array(repeating: 0, count: 16),
            samples: Array(repeating: 0.01, count: 160),
            sensitivity: 0.1
        )
        let voiced = DictationCoordinator.updatedWaveformLevels(
            previous: quiet,
            samples: Array(repeating: 0.08, count: 160),
            sensitivity: 0.1
        )

        #expect(quiet.dropLast().allSatisfy { $0 == 0 })
        #expect(quiet.last ?? 0 > 0.2)
        #expect(voiced[14] == quiet[15])
        #expect(voiced[15] > voiced[14])
        #expect(Set(voiced.map { Int(($0 * 100).rounded()) }).count >= 3)
    }

    @Test
    func noTargetRecordsAndCopiesInsteadOfShowingAnInsertionError() async {
        let fixture = DictationCoordinatorFixture(target: nil)
        await fixture.coordinator.startDictation()

        #expect(fixture.engine.startCount == 1)
        #expect(fixture.audio.startCount == 1)
        #expect(fixture.arbiter.activeKind == .dictation)

        await fixture.coordinator.finishDictation()

        #expect(fixture.pasteboard.value?.trimmingCharacters(in: .whitespacesAndNewlines) == "Keep this transcript")
        #expect(fixture.feedback.completionCount == 1)
        #expect(fixture.insertion.values.isEmpty)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func visibleHUDSkipsTheEphemeralInsertingState() async {
        let fixture = DictationCoordinatorFixture(target: Self.capture())
        var visualStates: [HUDVisualState] = []
        fixture.coordinator.onHUDChange = { visualStates.append($0.visualState) }

        await fixture.coordinator.startDictation()
        await fixture.coordinator.finishDictation()

        #expect(visualStates.contains(.transcribing))
        #expect(visualStates.contains(.success))
        #expect(!visualStates.contains(.inserting))
    }

    @Test
    func toggleShortcutPromotesHoldSessionAndHoldReleaseDoesNotStopIt() async {
        let fixture = DictationCoordinatorFixture(target: Self.capture())
        var visualStates: [HUDVisualState] = []
        fixture.coordinator.onHUDChange = { visualStates.append($0.visualState) }

        fixture.hotkey.onPress?(.holdToTalk)
        for _ in 0..<1_000 where fixture.audio.startCount == 0 {
            await Task.yield()
        }
        fixture.hotkey.onPress?(.tapToStartStop)
        for _ in 0..<1_000
            where visualStates.last != .recording(triggerMode: .tapToStartStop, showsHint: false) {
            await Task.yield()
        }
        fixture.hotkey.onRelease?(.holdToTalk)
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.audio.stopCount == 0)
        #expect(visualStates.last == .recording(triggerMode: .tapToStartStop, showsHint: false))

        fixture.hotkey.onPress?(.tapToStartStop)
        for _ in 0..<1_000 where fixture.audio.stopCount == 0 {
            await Task.yield()
        }
        #expect(fixture.audio.stopCount == 1)
    }

    @Test
    func doublePressingHoldShortcutStartsLockedAndItsReleaseDoesNotStop() async {
        let fixture = DictationCoordinatorFixture(target: Self.capture())
        var visualStates: [HUDVisualState] = []
        fixture.coordinator.onHUDChange = { visualStates.append($0.visualState) }

        fixture.hotkey.onDoublePress?(.holdToTalk)
        for _ in 0..<1_000 where fixture.audio.startCount == 0 {
            await Task.yield()
        }

        #expect(fixture.audio.startCount == 1)
        #expect(visualStates.last == .recording(triggerMode: .tapToStartStop, showsHint: false))

        fixture.hotkey.onRelease?(.holdToTalk)
        for _ in 0..<20 { await Task.yield() }
        #expect(fixture.audio.stopCount == 0)

        fixture.hotkey.onQuickTap?(.holdToTalk)
        for _ in 0..<1_000 where fixture.audio.stopCount == 0 {
            await Task.yield()
        }
        #expect(fixture.audio.stopCount == 1)
    }

    @Test
    func trailingPressEnterCommandIsRemovedAndReturnFollowsInsertedText() async throws {
        let fixture = DictationCoordinatorFixture(
            target: Self.capture(),
            transcript: "Send the update press enter"
        )
        var configuration = TranscriptionConfiguration()
        configuration.pressEnterCommandEnabled = true
        _ = try await fixture.coordinator.updateTranscriptionConfiguration(configuration)

        await fixture.coordinator.startDictation()
        await fixture.coordinator.finishDictation()

        #expect(fixture.insertion.events == [
            .insert("Send the update"),
            .pressReturn
        ])
    }

    @Test
    func trailingPressEnterWordsRemainLiteralWhenCommandIsDisabled() async {
        let fixture = DictationCoordinatorFixture(
            target: Self.capture(),
            transcript: "Send the update press enter"
        )

        await fixture.coordinator.startDictation()
        await fixture.coordinator.finishDictation()

        #expect(fixture.insertion.values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } == ["Send the update press enter"])
        #expect(!fixture.insertion.events.contains(.pressReturn))
    }

    @Test
    func pressEnterCommandHandlesRecognizerPunctuationAndOnlyMatchesAtTheEnd() {
        #expect(DictationCommandInterpreter.interpret(
            "Send the update. PRESS ENTER!",
            pressEnterEnabled: true
        ) == DictationCommandInterpretation(
            text: "Send the update.",
            shouldPressReturn: true
        ))
        #expect(DictationCommandInterpreter.interpret(
            "Discuss press enter behavior tomorrow",
            pressEnterEnabled: true
        ) == DictationCommandInterpretation(
            text: "Discuss press enter behavior tomorrow",
            shouldPressReturn: false
        ))
    }

    @Test
    func customReturnPhraseIsRemovedAndMatchesFlexibleSpacing() {
        #expect(DictationCommandInterpreter.interpret(
            "Send the update, SEND   NOW!",
            pressEnterEnabled: true,
            commandPhrase: "send now"
        ) == DictationCommandInterpretation(
            text: "Send the update",
            shouldPressReturn: true
        ))
        #expect(DictationCommandInterpreter.interpret(
            "Mention send now in the explanation",
            pressEnterEnabled: true,
            commandPhrase: "send now"
        ) == DictationCommandInterpretation(
            text: "Mention send now in the explanation",
            shouldPressReturn: false
        ))
    }

    @Test
    func emptyOrRegexLikeReturnPhraseFailsClosed() {
        #expect(!DictationCommandInterpreter.interpret(
            "Send the update",
            pressEnterEnabled: true,
            commandPhrase: "   "
        ).shouldPressReturn)
        #expect(DictationCommandInterpreter.interpret(
            "Send the update, go (now).",
            pressEnterEnabled: true,
            commandPhrase: "go (now)"
        ).shouldPressReturn)
    }

    @Test
    func clipboardOnlyDictationRemovesCommandWithoutPostingReturn() async throws {
        let fixture = DictationCoordinatorFixture(
            target: nil,
            transcript: "Save this note, press enter."
        )
        var configuration = TranscriptionConfiguration()
        configuration.pressEnterCommandEnabled = true
        _ = try await fixture.coordinator.updateTranscriptionConfiguration(configuration)

        await fixture.coordinator.startDictation()
        await fixture.coordinator.finishDictation()

        #expect(fixture.pasteboard.value == "Save this note")
        #expect(fixture.insertion.events.isEmpty)
    }

    @Test
    func externalAppWithoutEditableFocusCopiesAndReportsCopied() async {
        let fixture = DictationCoordinatorFixture(
            target: Self.capture(),
            hasEditableTarget: false
        )
        var visualStates: [HUDVisualState] = []
        fixture.coordinator.onHUDChange = { visualStates.append($0.visualState) }

        await fixture.coordinator.startDictation()
        await fixture.coordinator.finishDictation()

        #expect(fixture.pasteboard.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            == "Keep this transcript")
        #expect(fixture.insertion.events.isEmpty)
        #expect(visualStates.contains(.copied))
        #expect(!visualStates.contains(.success))
    }

    @Test
    func unknownCustomEditorBacksUpClipboardAndAttemptsKeyboardInsertion() async {
        let fixture = DictationCoordinatorFixture(
            target: Self.capture(),
            targetAssessment: .unknown(.focusedElementUnavailable)
        )

        await fixture.coordinator.startDictation()
        await fixture.coordinator.finishDictation()

        #expect(fixture.pasteboard.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            == "Keep this transcript")
        #expect(fixture.insertion.values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        } == ["Keep this transcript"])
    }

    @Test
    func pressEnterDoesNotFireWithoutEditableFocus() async throws {
        let fixture = DictationCoordinatorFixture(
            target: Self.capture(),
            transcript: "Send the update press enter",
            hasEditableTarget: false
        )
        var configuration = TranscriptionConfiguration()
        configuration.pressEnterCommandEnabled = true
        _ = try await fixture.coordinator.updateTranscriptionConfiguration(configuration)

        await fixture.coordinator.startDictation()
        await fixture.coordinator.finishDictation()

        #expect(fixture.pasteboard.value == "Send the update")
        #expect(fixture.insertion.events.isEmpty)
    }

    @Test
    func focusRaceDuringAtomicCaptureReleasesLeaseBeforeEngineOrAudio() async {
        let fixture = DictationCoordinatorFixture(target: Self.capture())
        var displayedError: String?
        fixture.coordinator.onError = { displayedError = $0 }
        fixture.authority.suspendThenThrow = true
        let start = Task { await fixture.coordinator.startDictation() }
        await fixture.authority.waitUntilCaptureSuspends()
        #expect(fixture.arbiter.activeKind == .dictation)
        fixture.authority.releaseCapture()
        await start.value

        #expect(fixture.engine.startCount == 0)
        #expect(fixture.audio.startCount == 0)
        #expect(fixture.arbiter.activeKind == nil)
        #expect(displayedError == "The destination changed — try again")
        #expect(!(displayedError?.contains("ApplicationTargetAuthorityError") ?? false))
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
    let pasteboard = DictationPasteboardFake()
    let feedback = DictationFeedbackFake()
    let hotkey = DictationHotkeyFake()
    let targetCapability: DictationTargetCapabilityFake
    let arbiter = VoiceSessionArbiter()
    let coordinator: DictationCoordinator

    init(
        target: ApplicationTargetCapture?,
        transcript: String = "Keep this transcript",
        hasEditableTarget: Bool = true,
        targetAssessment: DictationTargetCapabilityAssessment? = nil
    ) {
        authority = DictationTargetAuthorityFake(target: target)
        targetCapability = DictationTargetCapabilityFake(
            assessment: targetAssessment
                ?? (hasEditableTarget ? .editable(.standardTextRole) : .notEditable(.nonTextRole))
        )
        engine.transcript = transcript
        coordinator = DictationCoordinator(
            hotkeyService: hotkey,
            permissionsService: DictationPermissionsFake(),
            audioCaptureService: audio,
            transcriptionEngine: engine,
            textInsertionService: insertion,
            hudController: HUDWindowController(),
            analytics: AnalyticsService(isEnabled: false),
            feedbackService: feedback,
            sessionArbiter: arbiter,
            targetAuthority: authority,
            personalizationStore: PersonalizationStore(defaults: UserDefaults()),
            pasteboardWriter: pasteboard,
            targetCapability: targetCapability
        )
    }
}

private final class DictationHotkeyFake: HotkeyServing {
    var onPress: ((HotkeyAction) -> Void)?
    var onRelease: ((HotkeyAction) -> Void)?
    var onQuickTap: ((HotkeyAction) -> Void)?
    var onDoublePress: ((HotkeyAction) -> Void)?
    var onAnyKeyPress: (() -> Void)?
    var onObservedKeyEvent: ((ObservedKeyEvent) -> Void)?
    var onDiagnosticsEvent: ((String, [String: String]) -> Void)?

    func updateBindings(_ bindings: [HotkeyBinding]) {}
    func setPaused(_ paused: Bool) {}
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
    func activate(_ capture: ApplicationTargetCapture) -> Bool { true }
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
    private(set) var stopCount = 0
    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) throws { startCount += 1 }
    func stopCapture() -> AudioCaptureSessionMetrics {
        stopCount += 1
        return .init(duration: 1, frameCount: 16_000, sampleRate: 16_000, speechDetected: true, speechFrameCount: 16_000, peakLevel: 0.5)
    }
}

private final class DictationEngineFake: TranscriptionEngine {
    private(set) var startCount = 0
    var transcript = "Keep this transcript"
    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}
    func isPrepared() async -> Bool { true }
    func prepare() async throws {}
    func startSession() async throws { startCount += 1 }
    func appendAudio(_ chunk: AudioChunk) async {}
    func previewTranscript() async -> PreviewTranscript? { nil }
    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        .init(rawText: transcript, cleanedText: transcript, duration: 1)
    }
    func cancelSession() async {}
    func statusSummary() async -> String { "ready" }
}

private final class DictationInsertionFake: TextInsertionServing {
    enum Event: Equatable {
        case insert(String)
        case pressReturn
    }

    private(set) var values: [String] = []
    private(set) var events: [Event] = []
    func insert(_ text: String) async throws {
        values.append(text)
        events.append(.insert(text))
    }
    func pressReturn() async throws { events.append(.pressReturn) }
    func deleteLastInsertion() async throws {}
}

@MainActor
private final class DictationTargetCapabilityFake: DictationTargetCapabilityServing {
    let assessment: DictationTargetCapabilityAssessment

    init(assessment: DictationTargetCapabilityAssessment) {
        self.assessment = assessment
    }

    func assessFocusedElement(for capture: ApplicationTargetCapture) -> DictationTargetCapabilityAssessment {
        assessment
    }
}

@MainActor
private final class DictationPasteboardFake: TextPasteboardWriting {
    private(set) var value: String?

    func replaceContents(with text: String) -> Bool {
        value = text
        return true
    }
}

@MainActor
private final class DictationFeedbackFake: FeedbackServing {
    var isActivationEnabled = false
    var isCompletionEnabled = false
    private(set) var completionCount = 0
    func playActivationSound() {}
    func playCompletionSound() { completionCount += 1 }
}
