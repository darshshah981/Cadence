import Foundation

enum FlowStateError: LocalizedError {
    case missingRequiredPermissions
    case audioInputUnavailable
    case accessibilityPermissionMissing
    case eventSourceUnavailable
    case dictationAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .missingRequiredPermissions:
            return "Microphone and Accessibility permissions are required before dictation can start."
        case .audioInputUnavailable:
            return "No microphone input was available."
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required for direct text insertion."
        case .eventSourceUnavailable:
            return "FlowState could not post keyboard events."
        case .dictationAlreadyRunning:
            return "A dictation session is already in progress."
        }
    }
}

@MainActor
final class DictationCoordinator {
    private enum PreviewTuning {
        static let fallbackInterval: Duration = .milliseconds(1200)
        static let pauseInterval: Duration = .milliseconds(250)
        static let pauseThreshold: TimeInterval = 0.32
        static let activeSpeechThreshold = 0.045
        static let fastFinalizeSpeechDuration: TimeInterval = 6.2
    }

    var onStateChange: ((DictationSessionState) -> Void)?
    var onHUDChange: ((HUDState) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onPreviewTranscript: ((PreviewTranscript) -> Void)?
    var onError: ((String) -> Void)?
    var onBackendStatus: ((String) -> Void)?

    private let hotkeyService: HotkeyService
    private let permissionsService: PermissionsService
    private let audioCaptureService: AudioCaptureServing
    private let transcriptionEngine: TranscriptionEngine
    private let textInsertionService: TextInsertionServing
    private let hudController: HUDWindowController
    private var activeTriggerMode: DictationTriggerMode?
    private var stopTapDictationOnNextKeyPress = false
    private var previewTask: Task<Void, Never>?
    private var latestPreview = PreviewTranscript(confirmedText: "", unconfirmedText: "")
    private var latestAudioLevel = 0.0
    private var lastSpeechTimestamp = Date()
    private var lastPreviewTimestamp = Date.distantPast

    private var state: DictationSessionState = .idle {
        didSet { onStateChange?(state) }
    }

    init(
        hotkeyService: HotkeyService,
        permissionsService: PermissionsService,
        audioCaptureService: AudioCaptureServing,
        transcriptionEngine: TranscriptionEngine,
        textInsertionService: TextInsertionServing,
        hudController: HUDWindowController
    ) {
        self.hotkeyService = hotkeyService
        self.permissionsService = permissionsService
        self.audioCaptureService = audioCaptureService
        self.transcriptionEngine = transcriptionEngine
        self.textInsertionService = textInsertionService
        self.hudController = hudController

        self.hudController.onStop = { [weak self] in
            Task { await self?.stopFromHUD() }
        }
        self.hudController.onCancel = { [weak self] in
            Task { await self?.cancelFromHUD() }
        }

        self.hotkeyService.onPress = { [weak self] action in
            Task { await self?.handleHotkeyPress(action) }
        }

        self.hotkeyService.onRelease = { [weak self] action in
            Task { await self?.handleHotkeyRelease(action) }
        }

        self.hotkeyService.onAnyKeyPress = { [weak self] in
            Task { await self?.handleAnyKeyPress() }
        }
    }

    func insertPreviewText() async throws {
        try await textInsertionService.insert("FlowState preview insert.\n")
    }

    func updateTranscriptionConfiguration(_ configuration: TranscriptionConfiguration) async throws -> String {
        stopTapDictationOnNextKeyPress = configuration.tapStopsOnNextKeyPress
        try await transcriptionEngine.updateConfiguration(configuration)
        let summary = await transcriptionEngine.statusSummary()
        onBackendStatus?(summary)
        return summary
    }

    func prewarmBackend() async throws -> String {
        try await transcriptionEngine.prepare()
        let summary = await transcriptionEngine.statusSummary()
        onBackendStatus?(summary)
        return summary
    }

    func updateHotkeyBindings(_ bindings: [HotkeyBinding]) {
        hotkeyService.updateBindings(bindings)
    }

    func setHotkeysPaused(_ paused: Bool) {
        hotkeyService.setPaused(paused)
    }

    private func handleHotkeyPress(_ action: HotkeyAction) async {
        switch action {
        case .holdToTalk:
            if state == .idle || isErrorState {
                await beginDictationIfPossible(triggerMode: .holdToTalk)
            }
        case .tapToStartStop:
            switch state {
            case .idle, .error:
                await beginDictationIfPossible(triggerMode: .tapToStartStop)
            case .listening where activeTriggerMode == .holdToTalk:
                activeTriggerMode = .tapToStartStop
                publishHUD(
                    title: "Listening",
                    subtitle: latestPreview.composedText,
                    level: max(latestAudioLevel, 0.2),
                    showsSubtitle: !latestPreview.composedText.isEmpty,
                    showsControls: true
                )
            case .listening where activeTriggerMode == .tapToStartStop:
                await finishDictationIfNeeded()
            case .listening, .finalizing, .inserting:
                break
            }
        }
    }

    private func handleHotkeyRelease(_ action: HotkeyAction) async {
        guard action == .holdToTalk, activeTriggerMode == .holdToTalk else { return }
        await finishDictationIfNeeded()
    }

    private func handleAnyKeyPress() async {
        guard stopTapDictationOnNextKeyPress else { return }
        guard activeTriggerMode == .tapToStartStop, state == .listening else { return }
        await finishDictationIfNeeded()
    }

    private func beginDictationIfPossible(triggerMode: DictationTriggerMode) async {
        if state != .idle {
            guard case .error = state else {
                return
            }
        }

        do {
            let permissions = permissionsService.snapshot()
            guard permissions.allRequiredGranted else {
                throw FlowStateError.missingRequiredPermissions
            }

            activeTriggerMode = triggerMode

            let summary = try await prewarmBackend()
            onBackendStatus?(summary)
            try await transcriptionEngine.startSession()
            try audioCaptureService.startCapture { [weak self] chunk, level in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await transcriptionEngine.appendAudio(chunk)
                    latestAudioLevel = level
                    if level >= PreviewTuning.activeSpeechThreshold {
                        lastSpeechTimestamp = Date()
                    }
                    publishHUD(
                        title: "Listening",
                        subtitle: latestPreview.composedText,
                        level: level,
                        showsSubtitle: !latestPreview.composedText.isEmpty,
                        showsControls: activeTriggerMode == .tapToStartStop
                    )
                }
            }

            state = .listening
            startPreviewLoop()
            publishHUD(
                title: "Listening",
                subtitle: "",
                level: 0.1,
                showsSubtitle: false,
                showsControls: triggerMode == .tapToStartStop
            )
        } catch {
            activeTriggerMode = nil
            publishError(error.localizedDescription)
        }
    }

    private func finishDictationIfNeeded() async {
        guard state == .listening else { return }

        state = .finalizing
        publishHUD(title: "Finalizing", subtitle: "", level: 0.3, showsSubtitle: false, showsControls: false)

        let metrics = audioCaptureService.stopCapture()
        let releasePreview = await transcriptionEngine.previewTranscript() ?? latestPreview
        stopPreviewLoop()

        do {
            let correctedText: String

            if shouldUsePreviewAsFinal(releasePreview, metrics: metrics) {
                let previewText = releasePreview.composedText
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                correctedText = VocabularyPostProcessor.apply(
                    to: previewText,
                    vocabularyText: currentVocabularyText
                )
                await transcriptionEngine.cancelSession()
            } else {
                publishHUD(title: "Finalizing", subtitle: "", level: 0.35, showsSubtitle: false, showsControls: false)
                let transcript = try await transcriptionEngine.finishSession(metrics: metrics)
                correctedText = VocabularyPostProcessor.apply(
                    to: transcript.cleanedText,
                    vocabularyText: currentVocabularyText
                )
            }

            onTranscript?(correctedText)

            state = .inserting
            publishHUD(title: "Inserting", subtitle: "", level: 0.6, showsSubtitle: false, showsControls: false)

            try await textInsertionService.insert(correctedText + " ")

            state = .idle
            activeTriggerMode = nil
            publishHUD(title: "Inserted", subtitle: "", level: 1, showsSubtitle: false, showsControls: false)

            try await Task.sleep(for: .milliseconds(700))
            hideHUD()
        } catch {
            activeTriggerMode = nil
            publishError(error.localizedDescription)
        }
    }

    private func publishHUD(title: String, subtitle: String, level: Double, showsSubtitle: Bool, showsControls: Bool) {
        let hudState = HUDState(
            title: title,
            subtitle: subtitle,
            level: level,
            isVisible: true,
            showsSubtitle: showsSubtitle,
            showsControls: showsControls
        )
        onHUDChange?(hudState)
        hudController.update(with: hudState)
    }

    private func hideHUD() {
        onHUDChange?(HUDState.idle)
        hudController.update(with: .idle)
    }

    private func publishError(_ message: String) {
        stopPreviewLoop()
        activeTriggerMode = nil
        state = .error(message)
        onError?(message)
        publishHUD(title: "Permission or runtime issue", subtitle: message, level: 0, showsSubtitle: true, showsControls: false)
    }

    private var currentVocabularyText: String {
        UserDefaults.standard.string(forKey: "FlowState.vocabularyText") ?? ""
    }

    private var isErrorState: Bool {
        if case .error = state {
            return true
        }
        return false
    }

    private func startPreviewLoop() {
        stopPreviewLoop()
        latestPreview = PreviewTranscript(confirmedText: "", unconfirmedText: "")
        latestAudioLevel = 0
        lastSpeechTimestamp = Date()
        lastPreviewTimestamp = .distantPast
        onPreviewTranscript?(latestPreview)

        previewTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let recentlyPaused = Date().timeIntervalSince(self.lastSpeechTimestamp) >= PreviewTuning.pauseThreshold
                try? await Task.sleep(for: recentlyPaused ? PreviewTuning.pauseInterval : PreviewTuning.fallbackInterval)
                guard !Task.isCancelled else { break }
                guard self.state == .listening else { continue }

                let now = Date()
                let shouldPollForPause = now.timeIntervalSince(self.lastSpeechTimestamp) >= PreviewTuning.pauseThreshold
                let shouldPollForCadence = now.timeIntervalSince(self.lastPreviewTimestamp) >= 1.0
                guard shouldPollForPause || shouldPollForCadence else { continue }

                if let preview = await self.transcriptionEngine.previewTranscript() {
                    self.lastPreviewTimestamp = now
                    let correctedPreview = PreviewTranscript(
                        confirmedText: VocabularyPostProcessor.apply(
                            to: preview.confirmedText,
                            vocabularyText: self.currentVocabularyText
                        ),
                        unconfirmedText: VocabularyPostProcessor.apply(
                            to: preview.unconfirmedText,
                            vocabularyText: self.currentVocabularyText
                        )
                    )
                    self.latestPreview = correctedPreview
                    self.onPreviewTranscript?(correctedPreview)
                    self.publishHUD(
                        title: "Listening",
                        subtitle: correctedPreview.composedText,
                        level: max(self.latestAudioLevel, 0.45),
                        showsSubtitle: !correctedPreview.composedText.isEmpty,
                        showsControls: self.activeTriggerMode == .tapToStartStop
                    )
                }
            }
        }
    }

    private func stopPreviewLoop() {
        previewTask?.cancel()
        previewTask = nil
        latestPreview = PreviewTranscript(confirmedText: "", unconfirmedText: "")
        onPreviewTranscript?(latestPreview)
    }

    private func shouldUsePreviewAsFinal(_ preview: PreviewTranscript, metrics: AudioCaptureSessionMetrics) -> Bool {
        let text = preview.composedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let speechDuration = metrics.sampleRate > 0
            ? Double(metrics.speechFrameCount) / metrics.sampleRate
            : metrics.duration
        guard speechDuration <= PreviewTuning.fastFinalizeSpeechDuration else {
            return false
        }

        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        return wordCount >= 2 || text.count >= 12
    }

    private func stopFromHUD() async {
        guard activeTriggerMode == .tapToStartStop else { return }
        await finishDictationIfNeeded()
    }

    private func cancelFromHUD() async {
        guard activeTriggerMode == .tapToStartStop else { return }
        guard state == .listening else { return }

        _ = audioCaptureService.stopCapture()
        stopPreviewLoop()
        await transcriptionEngine.cancelSession()
        activeTriggerMode = nil
        state = .idle
        hideHUD()
    }
}
