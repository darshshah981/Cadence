import Foundation
import OSLog

private let dictationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Dictation"
)

enum CadenceError: LocalizedError {
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
            return "Cadence could not post keyboard events."
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
        static let holdHintCutoff = 3
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
    private let analytics: AnalyticsService
    private var transcriptionConfiguration = TranscriptionConfiguration()
    private var activeTriggerMode: DictationTriggerMode?
    private var stopTapDictationOnNextKeyPress = false
    private var previewTask: Task<Void, Never>?
    private var latestPreview = PreviewTranscript(confirmedText: "", unconfirmedText: "")
    private var latestAudioLevel = 0.0
    private var latestWaveformLevels = Array(repeating: 0.0, count: 16)
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
        hudController: HUDWindowController,
        analytics: AnalyticsService
    ) {
        self.hotkeyService = hotkeyService
        self.permissionsService = permissionsService
        self.audioCaptureService = audioCaptureService
        self.transcriptionEngine = transcriptionEngine
        self.textInsertionService = textInsertionService
        self.hudController = hudController
        self.analytics = analytics

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
        try await textInsertionService.insert("Cadence preview insert.\n")
    }

    func updateTranscriptionConfiguration(_ configuration: TranscriptionConfiguration) async throws -> String {
        transcriptionConfiguration = configuration
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
                    visualState: .recording(triggerMode: .tapToStartStop, showsHint: false),
                    subtitle: latestPreview.composedText,
                    level: max(latestAudioLevel, 0.2),
                    waveformLevels: latestWaveformLevels,
                    showsSubtitle: !latestPreview.composedText.isEmpty
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
            var permissions = permissionsService.snapshot()
            if !permissions.microphoneGranted {
                _ = await permissionsService.requestMicrophoneAccess()
                permissions = permissionsService.snapshot()
            }

            guard permissions.allRequiredGranted else {
                analytics.track("dictation_blocked", properties: ["reason": "permissions"])
                throw CadenceError.missingRequiredPermissions
            }

            activeTriggerMode = triggerMode
            analytics.track("dictation_started", properties: ["trigger": triggerMode.rawValue])

            try await transcriptionEngine.startSession()
            try audioCaptureService.startCapture { [weak self] chunk, level in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await transcriptionEngine.appendAudio(chunk)
                    latestAudioLevel = level
                    latestWaveformLevels = Self.waveformLevels(from: chunk.samples)
                    if level >= PreviewTuning.activeSpeechThreshold {
                        lastSpeechTimestamp = Date()
                    }
                    guard state == .listening else { return }
                    publishHUD(
                        visualState: .recording(
                            triggerMode: activeTriggerMode ?? triggerMode,
                            showsHint: shouldShowHoldHint(for: activeTriggerMode ?? triggerMode)
                        ),
                        subtitle: latestPreview.composedText,
                        level: level,
                        waveformLevels: latestWaveformLevels,
                        showsSubtitle: !latestPreview.composedText.isEmpty
                    )
                }
            }

            state = .listening
            startPreviewLoop()
            publishHUD(
                visualState: .recording(
                    triggerMode: triggerMode,
                    showsHint: shouldShowHoldHint(for: triggerMode)
                ),
                subtitle: "",
                level: 0.1,
                waveformLevels: latestWaveformLevels,
                showsSubtitle: false
            )
            warmBackendForCurrentSession()
        } catch {
            activeTriggerMode = nil
            publishError(error.localizedDescription)
        }
    }

    private func warmBackendForCurrentSession() {
        Task { [weak self] in
            guard let self else { return }

            do {
                _ = try await self.prewarmBackend()
            } catch {
                dictationLogger.error(
                    "Cadence timing backgroundPrepare failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func finishDictationIfNeeded() async {
        guard state == .listening else { return }

        let finalizeStartedAt = Date()
        state = .finalizing
        publishHUD(
            visualState: .transcribing,
            subtitle: "",
            level: 0.3,
            waveformLevels: latestWaveformLevels,
            showsSubtitle: false
        )

        let metrics = audioCaptureService.stopCapture()
        let releasePreview = latestPreview
        let speechDuration = metrics.sampleRate > 0
            ? Double(metrics.speechFrameCount) / metrics.sampleRate
            : metrics.duration
        dictationLogger.info(
            "Cadence timing finalize capture duration=\(Self.formatSeconds(metrics.duration), privacy: .public)s speech=\(Self.formatSeconds(speechDuration), privacy: .public)s frames=\(metrics.frameCount, privacy: .public) speechFrames=\(metrics.speechFrameCount, privacy: .public) livePreview=\(self.transcriptionConfiguration.livePreviewEnabled, privacy: .public) cachedPreview=\(!releasePreview.composedText.isEmpty, privacy: .public)"
        )
        stopPreviewLoop()

        do {
            let correctedText: String

            if shouldUsePreviewAsFinal(releasePreview, metrics: metrics) {
                dictationLogger.info("Cadence timing finalize using cached preview as final")
                let previewText = releasePreview.composedText
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                correctedText = applyPostProcessing(to: previewText)
                await transcriptionEngine.cancelSession()
            } else {
                publishHUD(
                    visualState: .transcribing,
                    subtitle: "",
                    level: 0.35,
                    waveformLevels: latestWaveformLevels,
                    showsSubtitle: false
                )
                let engineStartedAt = Date()
                let transcript = try await transcriptionEngine.finishSession(metrics: metrics)
                dictationLogger.info(
                    "Cadence timing finalEngine elapsed=\(Self.formatSeconds(Date().timeIntervalSince(engineStartedAt)), privacy: .public)s"
                )
                correctedText = applyPostProcessing(to: transcript.cleanedText)
            }

            onTranscript?(correctedText)
            incrementSuccessfulRecordingCount()

            state = .inserting
            publishHUD(
                visualState: .transcribing,
                subtitle: "",
                level: 0.6,
                waveformLevels: latestWaveformLevels,
                showsSubtitle: false
            )

            let insertionStartedAt = Date()
            try await textInsertionService.insert(correctedText + " ")
            let insertionElapsed = Date().timeIntervalSince(insertionStartedAt)
            let totalElapsed = Date().timeIntervalSince(finalizeStartedAt)
            dictationLogger.info(
                "Cadence timing finalize complete total=\(Self.formatSeconds(totalElapsed), privacy: .public)s insert=\(Self.formatSeconds(insertionElapsed), privacy: .public)s chars=\(correctedText.count, privacy: .public)"
            )
            analytics.track(
                "dictation_completed",
                properties: [
                    "durationBucket": Self.durationBucket(metrics.duration),
                    "speechBucket": Self.durationBucket(speechDuration),
                    "charactersBucket": Self.countBucket(correctedText.count),
                    "trigger": activeTriggerMode?.rawValue ?? "unknown"
                ]
            )

            state = .idle
            activeTriggerMode = nil
            hideHUD()

            try await Task.sleep(for: .milliseconds(700))
            hideHUD()
        } catch {
            dictationLogger.error(
                "Cadence timing finalize failed total=\(Self.formatSeconds(Date().timeIntervalSince(finalizeStartedAt)), privacy: .public)s error=\(error.localizedDescription, privacy: .public)"
            )
            analytics.track(
                "dictation_failed",
                properties: ["reason": Self.analyticsErrorReason(for: error)]
            )
            activeTriggerMode = nil
            publishError(error.localizedDescription)
        }
    }

    private func publishHUD(
        visualState: HUDVisualState,
        subtitle: String,
        level: Double,
        waveformLevels: [Double],
        showsSubtitle: Bool
    ) {
        let hudState = HUDState(
            visualState: visualState,
            subtitle: subtitle,
            level: level,
            waveformLevels: waveformLevels,
            isVisible: true,
            showsSubtitle: showsSubtitle
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
        publishHUD(
            visualState: .error(message: humanizedHUDMessage(for: message)),
            subtitle: "",
            level: 0,
            waveformLevels: Array(repeating: 0, count: 16),
            showsSubtitle: false
        )
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.hideHUD()
        }
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
        latestWaveformLevels = Array(repeating: 0, count: 16)
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
                        confirmedText: self.applyPostProcessing(to: preview.confirmedText),
                        unconfirmedText: self.applyPostProcessing(to: preview.unconfirmedText)
                    )
                    self.latestPreview = correctedPreview
                    self.onPreviewTranscript?(correctedPreview)
                    self.publishHUD(
                        visualState: .recording(
                            triggerMode: self.activeTriggerMode ?? .holdToTalk,
                            showsHint: self.shouldShowHoldHint(for: self.activeTriggerMode ?? .holdToTalk)
                        ),
                        subtitle: correctedPreview.composedText,
                        level: max(self.latestAudioLevel, 0.45),
                        waveformLevels: self.latestWaveformLevels,
                        showsSubtitle: !correctedPreview.composedText.isEmpty
                    )
                }
            }
        }
    }

    private func stopPreviewLoop() {
        previewTask?.cancel()
        previewTask = nil
        latestPreview = PreviewTranscript(confirmedText: "", unconfirmedText: "")
        latestWaveformLevels = Array(repeating: 0, count: 16)
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

    private func applyPostProcessing(to text: String) -> String {
        VocabularyPostProcessor.apply(to: text, configuration: transcriptionConfiguration)
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    private static func durationBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<2:
            return "0-2s"
        case ..<10:
            return "2-10s"
        case ..<30:
            return "10-30s"
        default:
            return "30s+"
        }
    }

    private static func countBucket(_ count: Int) -> String {
        switch count {
        case 0..<50:
            return "0-49"
        case 50..<200:
            return "50-199"
        case 200..<800:
            return "200-799"
        default:
            return "800+"
        }
    }

    private static func analyticsErrorReason(for error: Error) -> String {
        switch error {
        case WhisperEngineError.emptyAudio:
            return "emptyAudio"
        case WhisperEngineError.noTranscript:
            return "noTranscript"
        case CadenceError.missingRequiredPermissions:
            return "permissions"
        case CadenceError.accessibilityPermissionMissing:
            return "accessibility"
        default:
            return "other"
        }
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

    private func shouldShowHoldHint(for triggerMode: DictationTriggerMode) -> Bool {
        guard triggerMode == .holdToTalk else { return false }
        return UserDefaults.standard.integer(forKey: "Cadence.holdHintRecordingCount") < PreviewTuning.holdHintCutoff
    }

    private func incrementSuccessfulRecordingCount() {
        let key = "Cadence.holdHintRecordingCount"
        let count = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(count + 1, forKey: key)
    }

    private func humanizedHUDMessage(for raw: String) -> String {
        if raw.contains("Whisper did not return any transcript text") {
            return "Nothing picked up"
        }
        if raw.contains("Transcription backend unavailable") ||
            raw.contains("Loading transcription backend") {
            return "Model not loaded yet"
        }
        if raw.contains("Microphone") {
            return "Mic access needed"
        }
        return raw
    }

    private static func waveformLevels(from samples: [Float]) -> [Double] {
        let barCount = 16
        guard !samples.isEmpty else {
            return Array(repeating: 0, count: barCount)
        }

        let bucketSize = max(1, samples.count / barCount)
        return (0..<barCount).map { index in
            let start = index * bucketSize
            let end = min(samples.count, start + bucketSize)
            guard start < end else { return 0 }

            var sum: Float = 0
            for sample in samples[start..<end] {
                sum += abs(sample)
            }
            let average = sum / Float(end - start)
            return min(1, Double(average * 10))
        }
    }
}
