import AppKit
import Combine
import Foundation
import OSLog
import SwiftUI

private let preferencesLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Preferences"
)

enum MenuScreen {
    case home
    case settings
}

struct ModelReadinessSummary {
    enum Tone {
        case ready
        case working
        case attention
    }

    let title: String
    let detail: String
    let tone: Tone
}

@MainActor
final class AppModel: ObservableObject {
    private enum PreferenceKey {
        static let whisperModel = "FlowState.whisperModel"
        static let decodingMode = "FlowState.decodingMode"
        static let fillerWordPolicy = "FlowState.fillerWordPolicy"
        static let keepContext = "FlowState.keepContext"
        static let trimSilence = "FlowState.trimSilence"
        static let normalizeAudio = "FlowState.normalizeAudio"
        static let livePreviewEnabled = "FlowState.livePreviewEnabled"
        static let tapStopsOnNextKeyPress = "FlowState.tapStopsOnNextKeyPress"
        static let vocabularyText = "FlowState.vocabularyText"
        static let analyticsEnabled = "Cadence.analyticsEnabled"
        static let holdEnabled = "FlowState.holdEnabled"
        static let holdKeyCode = "FlowState.holdKeyCode"
        static let holdModifiers = "FlowState.holdModifiers"
        static let holdKeyDisplay = "FlowState.holdKeyDisplay"
        static let tapEnabled = "FlowState.tapEnabled"
        static let tapKeyCode = "FlowState.tapKeyCode"
        static let tapModifiers = "FlowState.tapModifiers"
        static let tapKeyDisplay = "FlowState.tapKeyDisplay"
        static let transcriptHistory = "FlowState.transcriptHistory"
        static let firstSuccessfulDictationTracked = "Cadence.firstSuccessfulDictationTracked"
        static let didMigrateToFastDefaults = "FlowState.didMigrateToFastDefaults"
        static let didMigrateToLivePreviewDefault = "FlowState.didMigrateToLivePreviewDefault"
        static let didMigrateToLivePreviewDefaultV2 = "FlowState.didMigrateToLivePreviewDefault.v2"
        static let didUndoLivePreviewDefault = "FlowState.didUndoLivePreviewDefault.v1"
    }

    private enum AnalyticsTuning {
        static let followUpWindow: TimeInterval = 10
    }

    @Published private(set) var permissions: PermissionsSnapshot
    @Published private(set) var state: DictationSessionState = .idle
    @Published private(set) var hudState = HUDState.idle
    @Published private(set) var lastTranscript = ""
    @Published private(set) var transcriptHistory: [TranscriptHistoryItem]
    @Published private(set) var livePreviewConfirmedText = ""
    @Published private(set) var livePreviewUnconfirmedText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var shortcutValidationMessage: String?
    @Published private(set) var copiedTranscriptID: UUID?
    @Published private(set) var backendDescription = "Loading transcription backend"
    @Published private(set) var transcriptionConfiguration: TranscriptionConfiguration
    @Published private(set) var analyticsEnabled: Bool
    @Published var menuScreen: MenuScreen = .home

    @Published private(set) var holdToTalkBinding: HotkeyBinding
    @Published private(set) var tapToStartStopBinding: HotkeyBinding

    private let permissionsService: PermissionsService
    private let permissionGuideWindowController = PermissionGuideWindowController()
    private let hotkeyService: HotkeyService
    private let coordinator: DictationCoordinator
    private let analytics: AnalyticsService
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var lastExternalApplication: NSRunningApplication?
    private var transcriptionConfigurationTask: Task<Void, Never>?
    private var lastTrackedCorrectionTranscriptID: UUID?
    private var lastTrackedCorrectionSessionID: String?

    init() {
        let defaults = UserDefaults.standard
        let initialHoldBinding = AppModel.loadBinding(defaults: defaults, action: .holdToTalk)
        let initialTapBinding = AppModel.loadBinding(defaults: defaults, action: .tapToStartStop)
        self.defaults = defaults
        self.transcriptionConfiguration = AppModel.loadConfiguration(defaults: defaults)
        let analyticsEnabled = defaults.bool(forKey: PreferenceKey.analyticsEnabled)
        self.analyticsEnabled = analyticsEnabled
        self.analytics = AnalyticsService(isEnabled: analyticsEnabled)
        self.holdToTalkBinding = initialHoldBinding
        self.tapToStartStopBinding = initialTapBinding
        self.transcriptHistory = AppModel.loadTranscriptHistory(defaults: defaults)

        let permissionsService = PermissionsService()
        self.permissionsService = permissionsService
        self.permissions = permissionsService.snapshot()

        let hudController = HUDWindowController()
        let transcriptionEngine = WhisperKitTranscriptionEngine()
        let audioCaptureService = AudioCaptureService()
        let textInsertionService = TextInsertionService()
        let hotkeyService = HotkeyService(bindings: Self.currentHotkeyBindings(hold: initialHoldBinding, tap: initialTapBinding))
        self.hotkeyService = hotkeyService

        self.coordinator = DictationCoordinator(
            hotkeyService: hotkeyService,
            permissionsService: permissionsService,
            audioCaptureService: audioCaptureService,
            transcriptionEngine: transcriptionEngine,
            textInsertionService: textInsertionService,
            hudController: hudController,
            analytics: analytics
        )

        bindCoordinator()
        bindHotkeyDiagnostics()
        bindPermissionRefresh()
        Task {
            await refreshPermissions()
            await applyTranscriptionConfiguration(prewarm: false)
            await warmBackend()
        }
        analytics.track(
            "app_launched",
            properties: [
                "model": transcriptionConfiguration.model.rawValue,
                "decoding": transcriptionConfiguration.decodingMode.rawValue
            ]
        )
    }

    var menuBarSymbolName: String {
        switch state {
        case .idle:
            return "waveform.and.mic"
        case .listening:
            return "mic.fill"
        case .finalizing:
            return "ellipsis.message.fill"
        case .inserting:
            return "keyboard.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var activeShortcutSummary: String {
        currentHotkeyBindings
            .filter(\.isEnabled)
            .map { "\($0.action.displayName): \($0.shortcut.displayName)" }
            .joined(separator: " • ")
    }

    var primaryTriggerMode: DictationTriggerMode {
        if tapToStartStopBinding.isEnabled, !holdToTalkBinding.isEnabled {
            return .tapToStartStop
        }
        return .holdToTalk
    }

    var dictationQualityPreset: DictationQualityPreset {
        DictationQualityPreset.matching(transcriptionConfiguration)
    }

    var hotkeyConflictMessage: String? {
        guard holdToTalkBinding.isEnabled, tapToStartStopBinding.isEnabled else { return nil }
        guard holdToTalkBinding.shortcut.conflicts(with: tapToStartStopBinding.shortcut) else { return nil }
        return "Hold To Talk and Press To Start/Stop cannot use the same shortcut at the same time."
    }

    var setupProgressLabel: String {
        let completed = [permissions.microphoneGranted, permissions.accessibilityGranted, permissions.inputMonitoringGranted]
            .filter { $0 }
            .count
        return "\(completed)/3 permissions ready"
    }

    var setupSummaryTitle: String {
        permissions.allRequiredGranted ? "Mac setup complete" : "Finish setup"
    }

    var setupSummaryDetail: String {
        if permissions.allRequiredGranted {
            return "Cadence has microphone, accessibility, and shortcut access."
        }

        let missing = missingPermissionNames
        if missing.count == 1, let item = missing.first {
            return "Grant \(item.lowercased()) to start dictating anywhere."
        }
        return "Grant \(missing.joined(separator: ", ").lowercased()) to finish setup."
    }

    var modelReadinessSummary: ModelReadinessSummary {
        if let error = userFacingErrorMessage {
            return ModelReadinessSummary(
                title: "Model setup needs attention",
                detail: error,
                tone: .attention
            )
        }

        let lowercasedSummary = backendDescription.lowercased()
        let presetName = dictationQualityPreset.displayName

        if lowercasedSummary.contains("ready to load") || lowercasedSummary.contains("loading transcription backend") {
            return ModelReadinessSummary(
                title: "\(presetName) is ready when you are",
                detail: "Cadence will finish loading this model the first time you dictate.",
                tone: .ready
            )
        }

        if lowercasedSummary.contains("unavailable") {
            return ModelReadinessSummary(
                title: "Model setup needs attention",
                detail: "Cadence could not prepare the selected model yet.",
                tone: .attention
            )
        }

        if lowercasedSummary.contains("download") || lowercasedSummary.contains("prepare") {
            return ModelReadinessSummary(
                title: "Preparing \(presetName.lowercased())",
                detail: "Cadence may need a moment to finish local model setup.",
                tone: .working
            )
        }

        return ModelReadinessSummary(
            title: "\(presetName) is ready",
            detail: "Using \(transcriptionConfiguration.model.shortLabel) for \(primaryTriggerMode.shortDescription.lowercased())",
            tone: .ready
        )
    }

    var userFacingErrorMessage: String? {
        guard let lastError = lastError?.trimmingCharacters(in: .whitespacesAndNewlines), !lastError.isEmpty else {
            return nil
        }

        return Self.humanizedErrorMessage(lastError)
    }

    func refreshPermissions() async {
        let previousPermissions = permissions
        permissions = permissionsService.snapshot()
        permissionGuideWindowController.updatePermissions(permissions)
        if permissions != previousPermissions {
            analytics.track(
                "permissions_granted_changed",
                properties: [
                    "microphone": String(permissions.microphoneGranted),
                    "accessibility": String(permissions.accessibilityGranted),
                    "inputMonitoring": String(permissions.inputMonitoringGranted)
                ]
            )
            if !previousPermissions.allRequiredGranted, permissions.allRequiredGranted {
                analytics.track("setup_completed")
            }
        }
        analytics.track(
            "permissions_refreshed",
            properties: [
                "microphone": String(permissions.microphoneGranted),
                "accessibility": String(permissions.accessibilityGranted),
                "inputMonitoring": String(permissions.inputMonitoringGranted)
            ]
        )
    }

    func requestMicrophoneAccess() {
        analytics.track("permission_request_clicked", properties: ["permission": "microphone"])
        Task {
            _ = await permissionsService.requestMicrophoneAccess()
            await refreshPermissions()
            schedulePermissionRefreshBurst()
        }
    }

    func requestAccessibilityAccess() {
        analytics.track("permission_request_clicked", properties: ["permission": "accessibility"])
        permissionsService.requestAccessibilityAccess()
        schedulePermissionRefreshBurst()
    }

    func requestInputMonitoringAccess() {
        analytics.track("permission_request_clicked", properties: ["permission": "inputMonitoring"])
        permissionsService.requestInputMonitoringAccess()
        schedulePermissionRefreshBurst()
    }

    func openPermissionsWizard() {
        analytics.track("permissions_wizard_opened")
        NSApp.activate(ignoringOtherApps: true)
        permissionGuideWindowController.show(
            permissions: permissions,
            appURL: Bundle.main.bundleURL,
            onRequestMicrophone: { [weak self] in
                self?.requestMicrophoneAccess()
            },
            onRequestAccessibility: { [weak self] in
                self?.requestAccessibilityAccess()
            },
            onRequestInputMonitoring: { [weak self] in
                self?.requestInputMonitoringAccess()
            },
            onRefresh: { [weak self] in
                Task { await self?.refreshPermissions() }
            }
        )
        schedulePermissionRefreshBurst()
    }

    func showSettingsScreen() {
        analytics.track("screen_opened", properties: ["screen": "settings"])
        menuScreen = .settings
    }

    func showHomeScreen() {
        analytics.track("screen_opened", properties: ["screen": "home"])
        menuScreen = .home
    }

    func startStopDemoInsert() {
        Task {
            do {
                if let lastExternalApplication {
                    _ = lastExternalApplication.activate(options: [.activateIgnoringOtherApps])
                    try? await Task.sleep(for: .milliseconds(180))
                }
                try await coordinator.insertPreviewText()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func runSetupCheck() {
        analytics.track("setup_check_started")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshPermissions()
            await self.warmBackend()
        }
    }

    func warmBackend() async {
        let startedAt = Date()
        let properties = backendAnalyticsProperties()
        analytics.track("engine_prepare_started", properties: properties)
        do {
            let summary = try await coordinator.prewarmBackend()
            lastError = nil
            backendDescription = summary
            var completedProperties = properties
            completedProperties["durationMs"] = .int(Self.analyticsMilliseconds(Date().timeIntervalSince(startedAt)))
            completedProperties["backend"] = .string("whisperkit")
            analytics.track("engine_prepare_completed", properties: completedProperties)
        } catch {
            guard !Self.isBenignModelLoadCancellation(error) else {
                preferencesLogger.info("Ignored canceled background model load")
                return
            }
            lastError = error.localizedDescription
            backendDescription = "Transcription backend unavailable"
            var failureProperties = properties
            failureProperties["durationMs"] = .int(Self.analyticsMilliseconds(Date().timeIntervalSince(startedAt)))
            failureProperties["reason"] = .string(Self.analyticsErrorReason(for: error))
            analytics.track("engine_prepare_failed", properties: failureProperties)
            analytics.track("model_load_failed", properties: failureProperties)
        }
    }

    func setWhisperModel(_ model: WhisperModelOption) {
        analytics.track("setting_changed", properties: ["setting": "model", "value": model.rawValue])
        updateTranscriptionConfiguration { $0.model = model }
    }

    func setDecodingMode(_ decodingMode: WhisperDecodingMode) {
        analytics.track("setting_changed", properties: ["setting": "decoding", "value": decodingMode.rawValue])
        updateTranscriptionConfiguration { $0.decodingMode = decodingMode }
    }

    func setFillerWordPolicy(_ fillerWordPolicy: FillerWordPolicy) {
        analytics.track("setting_changed", properties: ["setting": "fillers", "value": fillerWordPolicy.rawValue])
        updateTranscriptionConfiguration { $0.fillerWordPolicy = fillerWordPolicy }
    }

    func setKeepContext(_ keepContext: Bool) {
        analytics.track("setting_changed", properties: ["setting": "keepContext", "value": String(keepContext)])
        updateTranscriptionConfiguration { $0.keepContext = keepContext }
    }

    func setTrimSilence(_ trimSilence: Bool) {
        analytics.track("setting_changed", properties: ["setting": "trimSilence", "value": String(trimSilence)])
        updateTranscriptionConfiguration { $0.trimSilence = trimSilence }
    }

    func setNormalizeAudio(_ normalizeAudio: Bool) {
        analytics.track("setting_changed", properties: ["setting": "normalizeAudio", "value": String(normalizeAudio)])
        updateTranscriptionConfiguration { $0.normalizeAudio = normalizeAudio }
    }

    func setLivePreviewEnabled(_ livePreviewEnabled: Bool) {
        analytics.track("setting_changed", properties: ["setting": "livePreviewEnabled", "value": String(livePreviewEnabled)])
        updateTranscriptionConfiguration { $0.livePreviewEnabled = livePreviewEnabled }
    }

    func setTapStopsOnNextKeyPress(_ enabled: Bool) {
        analytics.track("setting_changed", properties: ["setting": "tapStopsOnNextKeyPress", "value": String(enabled)])
        updateTranscriptionConfiguration { $0.tapStopsOnNextKeyPress = enabled }
    }

    func setVocabularyText(_ vocabularyText: String) {
        analytics.track(
            "setting_changed",
            properties: [
                "setting": "vocabularyText",
                "value": vocabularyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "empty" : "custom"
            ]
        )
        updateTranscriptionConfiguration { $0.vocabularyText = vocabularyText }
    }

    func setDictationQualityPreset(_ preset: DictationQualityPreset) {
        guard dictationQualityPreset != preset else { return }
        analytics.track("setting_changed", properties: ["setting": "qualityPreset", "value": preset.rawValue])
        updateTranscriptionConfiguration {
            $0.model = preset.model
            $0.decodingMode = preset.decodingMode
        }
    }

    func resetToRecommendedPreset() {
        analytics.track("recommended_preset_reset")
        transcriptionConfiguration = TranscriptionConfiguration()
        persist(configuration: transcriptionConfiguration)

        Task {
            await applyTranscriptionConfiguration(prewarm: true)
        }
    }

    func setHoldToTalkEnabled(_ isEnabled: Bool) {
        guard holdToTalkBinding.isEnabled != isEnabled else { return }
        if isEnabled,
           tapToStartStopBinding.isEnabled,
           holdToTalkBinding.shortcut.conflicts(with: tapToStartStopBinding.shortcut) {
            shortcutValidationMessage = "Hold To Talk and Press To Start/Stop need different shortcuts."
            analytics.track("shortcut_conflict_detected", properties: ["shortcut": "holdToTalk", "stage": "enable"])
            return
        }

        shortcutValidationMessage = nil
        analytics.track("shortcut_enabled_changed", properties: ["shortcut": "holdToTalk", "enabled": String(isEnabled)])
        holdToTalkBinding.isEnabled = isEnabled
        persist(binding: holdToTalkBinding)
        refreshRegisteredHotkeys()
    }

    func setTapToStartStopEnabled(_ isEnabled: Bool) {
        guard tapToStartStopBinding.isEnabled != isEnabled else { return }
        if isEnabled,
           holdToTalkBinding.isEnabled,
           tapToStartStopBinding.shortcut.conflicts(with: holdToTalkBinding.shortcut) {
            shortcutValidationMessage = "Hold To Talk and Press To Start/Stop need different shortcuts."
            analytics.track("shortcut_conflict_detected", properties: ["shortcut": "tapToStartStop", "stage": "enable"])
            return
        }

        shortcutValidationMessage = nil
        analytics.track("shortcut_enabled_changed", properties: ["shortcut": "tapToStartStop", "enabled": String(isEnabled)])
        tapToStartStopBinding.isEnabled = isEnabled
        persist(binding: tapToStartStopBinding)
        refreshRegisteredHotkeys()
    }

    func setPrimaryTriggerMode(_ mode: DictationTriggerMode) {
        guard primaryTriggerMode != mode || holdToTalkBinding.isEnabled == tapToStartStopBinding.isEnabled else { return }
        analytics.track("shortcut_mode_changed", properties: ["mode": mode.rawValue])

        switch mode {
        case .holdToTalk:
            holdToTalkBinding.isEnabled = true
            tapToStartStopBinding.isEnabled = false
        case .tapToStartStop:
            holdToTalkBinding.isEnabled = false
            tapToStartStopBinding.isEnabled = true
        }

        persist(binding: holdToTalkBinding)
        persist(binding: tapToStartStopBinding)
        refreshRegisteredHotkeys()
    }

    func setShortcut(_ shortcut: HotkeyConfiguration, for action: HotkeyAction) {
        guard action.supports(shortcut) else {
            shortcutValidationMessage = "\(action.displayName) shortcut rejected. \(action.shortcutRuleDescription)"
            return
        }

        switch action {
        case .holdToTalk:
            if holdToTalkBinding.isEnabled,
               tapToStartStopBinding.isEnabled,
               shortcut.conflicts(with: tapToStartStopBinding.shortcut) {
                shortcutValidationMessage = "Hold To Talk and Press To Start/Stop need different shortcuts."
                analytics.track("shortcut_conflict_detected", properties: ["shortcut": "holdToTalk", "stage": "change"])
                return
            }
        case .tapToStartStop:
            if tapToStartStopBinding.isEnabled,
               holdToTalkBinding.isEnabled,
               shortcut.conflicts(with: holdToTalkBinding.shortcut) {
                shortcutValidationMessage = "Hold To Talk and Press To Start/Stop need different shortcuts."
                analytics.track("shortcut_conflict_detected", properties: ["shortcut": "tapToStartStop", "stage": "change"])
                return
            }
        }

        shortcutValidationMessage = nil

        switch action {
        case .holdToTalk:
            guard holdToTalkBinding.shortcut != shortcut else { return }
            analytics.track("shortcut_changed", properties: ["shortcut": "holdToTalk"])
            holdToTalkBinding.shortcut = shortcut
            persist(binding: holdToTalkBinding)
        case .tapToStartStop:
            guard tapToStartStopBinding.shortcut != shortcut else { return }
            analytics.track("shortcut_changed", properties: ["shortcut": "tapToStartStop"])
            tapToStartStopBinding.shortcut = shortcut
            persist(binding: tapToStartStopBinding)
        }

        refreshRegisteredHotkeys()
    }

    func setShortcutRecordingActive(_ isActive: Bool) {
        coordinator.setHotkeysPaused(isActive)
    }

    func copyTranscript(_ item: TranscriptHistoryItem) {
        let wordCount = Self.wordCount(in: item.text)
        analytics.track(
            "transcript_copied",
            properties: [
                "sessionID": .string(item.analyticsSessionID ?? "history-only"),
                "charactersBucket": .string(Self.countBucket(item.text.count)),
                "characterCount": .int(item.text.count),
                "wordsBucket": .string(Self.countBucket(wordCount)),
                "wordCount": .int(wordCount)
            ]
        )
        if Date().timeIntervalSince(item.createdAt) <= AnalyticsTuning.followUpWindow {
            analytics.track(
                "manual_copy_after_dictation",
                properties: [
                    "sessionID": .string(item.analyticsSessionID ?? "history-only"),
                    "secondsSinceTranscript": .double(Self.analyticsSeconds(Date().timeIntervalSince(item.createdAt))),
                    "characterCount": .int(item.text.count),
                    "wordCount": .int(wordCount)
                ]
            )
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        copiedTranscriptID = item.id

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.copiedTranscriptID == item.id {
                self?.copiedTranscriptID = nil
            }
        }
    }

    func setAnalyticsEnabled(_ isEnabled: Bool) {
        guard analyticsEnabled != isEnabled else { return }
        analyticsEnabled = isEnabled
        defaults.set(isEnabled, forKey: PreferenceKey.analyticsEnabled)
        analytics.setEnabled(isEnabled)
    }

    private var currentHotkeyBindings: [HotkeyBinding] {
        Self.currentHotkeyBindings(hold: holdToTalkBinding, tap: tapToStartStopBinding)
    }

    private func bindCoordinator() {
        coordinator.onStateChange = { [weak self] state in
            self?.state = state
        }

        coordinator.onHUDChange = { [weak self] hudState in
            self?.hudState = hudState
        }

        coordinator.onTranscript = { [weak self] transcript, sessionID in
            self?.lastTranscript = transcript
            self?.appendTranscriptToHistory(transcript, sessionID: sessionID)
            self?.livePreviewConfirmedText = ""
            self?.livePreviewUnconfirmedText = ""
        }

        coordinator.onPreviewTranscript = { [weak self] preview in
            self?.livePreviewConfirmedText = preview.confirmedText
            self?.livePreviewUnconfirmedText = preview.unconfirmedText
        }

        coordinator.onError = { [weak self] message in
            self?.lastError = message
        }

        coordinator.onBackendStatus = { [weak self] summary in
            self?.backendDescription = summary
        }
    }

    private func bindHotkeyDiagnostics() {
        hotkeyService.onDiagnosticsEvent = { [weak self] name, properties in
            self?.analytics.track(name, properties: properties)
        }

        hotkeyService.onObservedKeyEvent = { [weak self] event in
            self?.handleObservedKeyEvent(event)
        }
    }

    private func bindPermissionRefresh() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { await self?.refreshPermissions() }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard
                    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    application.bundleIdentifier != Bundle.main.bundleIdentifier
                else {
                    return
                }

                self?.lastExternalApplication = application
            }
            .store(in: &cancellables)
    }

    private func schedulePermissionRefreshBurst() {
        Task {
            for nanoseconds in [300_000_000, 1_000_000_000, 2_500_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
                await refreshPermissions()
            }
        }
    }

    private func refreshRegisteredHotkeys() {
        coordinator.updateHotkeyBindings(sanitizedHotkeyBindings())
    }

    private func appendTranscriptToHistory(_ transcript: String, sessionID: String?) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let wordCount = Self.wordCount(in: cleaned)
        let item = TranscriptHistoryItem(text: cleaned, analyticsSessionID: sessionID)
        analytics.track(
            "transcript_created",
            properties: [
                "sessionID": .string(sessionID ?? "unknown"),
                "charactersBucket": .string(Self.countBucket(cleaned.count)),
                "characterCount": .int(cleaned.count),
                "wordsBucket": .string(Self.countBucket(wordCount)),
                "wordCount": .int(wordCount)
            ]
        )
        trackFirstSuccessfulDictationIfNeeded(item: item, wordCount: wordCount)
        transcriptHistory.insert(item, at: 0)
        lastTrackedCorrectionTranscriptID = nil
        lastTrackedCorrectionSessionID = nil
        if transcriptHistory.count > 20 {
            transcriptHistory = Array(transcriptHistory.prefix(20))
        }
        persistTranscriptHistory()
    }

    private func sanitizedHotkeyBindings() -> [HotkeyBinding] {
        guard holdToTalkBinding.isEnabled,
              tapToStartStopBinding.isEnabled,
              holdToTalkBinding.shortcut.conflicts(with: tapToStartStopBinding.shortcut) else {
            return currentHotkeyBindings
        }

        var sanitized = currentHotkeyBindings
        if let tapIndex = sanitized.firstIndex(where: { $0.action == .tapToStartStop }) {
            sanitized[tapIndex].isEnabled = false
        }
        return sanitized
    }

    private func updateTranscriptionConfiguration(_ mutate: (inout TranscriptionConfiguration) -> Void) {
        var next = transcriptionConfiguration
        mutate(&next)
        guard next != transcriptionConfiguration else { return }

        let shouldPrewarm = next.model != transcriptionConfiguration.model
        transcriptionConfiguration = next
        persist(configuration: next)
        lastError = nil

        transcriptionConfigurationTask?.cancel()
        transcriptionConfigurationTask = Task { @MainActor [weak self] in
            await self?.applyTranscriptionConfiguration(prewarm: shouldPrewarm)
        }
    }

    private func applyTranscriptionConfiguration(prewarm: Bool) async {
        do {
            let summary = try await coordinator.updateTranscriptionConfiguration(transcriptionConfiguration)
            lastError = nil
            backendDescription = summary
            if prewarm {
                await warmBackend()
            }
        } catch {
            guard !Self.isBenignModelLoadCancellation(error) else {
                preferencesLogger.info("Ignored canceled transcription configuration apply")
                return
            }
            lastError = error.localizedDescription
            backendDescription = "Transcription backend unavailable"
        }
    }

    private func handleObservedKeyEvent(_ event: ObservedKeyEvent) {
        guard event.isDeleteOrUndo else { return }
        guard let latestTranscript = transcriptHistory.first else { return }
        guard latestTranscript.id != lastTrackedCorrectionTranscriptID else { return }
        guard latestTranscript.analyticsSessionID != lastTrackedCorrectionSessionID else { return }

        let secondsSinceTranscript = Date().timeIntervalSince(latestTranscript.createdAt)
        guard secondsSinceTranscript <= AnalyticsTuning.followUpWindow else { return }

        lastTrackedCorrectionTranscriptID = latestTranscript.id
        lastTrackedCorrectionSessionID = latestTranscript.analyticsSessionID
        let wordCount = Self.wordCount(in: latestTranscript.text)
        analytics.track(
            "backspace_or_replace_soon_after_insert",
            properties: [
                "sessionID": .string(latestTranscript.analyticsSessionID ?? "history-only"),
                "signal": .string(event.keyCode == 6 ? "undo" : "delete"),
                "secondsSinceTranscript": .double(Self.analyticsSeconds(secondsSinceTranscript)),
                "characterCount": .int(latestTranscript.text.count),
                "wordCount": .int(wordCount)
            ]
        )
    }

    private func trackFirstSuccessfulDictationIfNeeded(item: TranscriptHistoryItem, wordCount: Int) {
        guard !defaults.bool(forKey: PreferenceKey.firstSuccessfulDictationTracked) else { return }
        defaults.set(true, forKey: PreferenceKey.firstSuccessfulDictationTracked)
        analytics.track(
            "first_successful_dictation",
            properties: [
                "sessionID": .string(item.analyticsSessionID ?? "unknown"),
                "characterCount": .int(item.text.count),
                "wordCount": .int(wordCount)
            ]
        )
    }

    private func backendAnalyticsProperties() -> [String: AnalyticsValue] {
        [
            "backend": .string("whisperkit"),
            "model": .string(transcriptionConfiguration.model.rawValue),
            "decoding": .string(transcriptionConfiguration.decodingMode.rawValue),
            "preset": .string(dictationQualityPreset.rawValue)
        ]
    }

    private static func isBenignModelLoadCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        let message = [
            nsError.localizedDescription,
            String(describing: error),
            nsError.userInfo.description
        ]
        .joined(separator: " ")
        .lowercased()

        return message.contains("nsurlerrordomain") &&
            message.contains("code=-999") &&
            message.contains("cancel")
    }

    private func persist(configuration: TranscriptionConfiguration) {
        defaults.set(configuration.model.rawValue, forKey: PreferenceKey.whisperModel)
        defaults.set(configuration.decodingMode.rawValue, forKey: PreferenceKey.decodingMode)
        defaults.set(configuration.fillerWordPolicy.rawValue, forKey: PreferenceKey.fillerWordPolicy)
        defaults.set(configuration.keepContext, forKey: PreferenceKey.keepContext)
        defaults.set(configuration.trimSilence, forKey: PreferenceKey.trimSilence)
        defaults.set(configuration.normalizeAudio, forKey: PreferenceKey.normalizeAudio)
        defaults.set(configuration.livePreviewEnabled, forKey: PreferenceKey.livePreviewEnabled)
        defaults.set(configuration.tapStopsOnNextKeyPress, forKey: PreferenceKey.tapStopsOnNextKeyPress)
        defaults.set(configuration.vocabularyText, forKey: PreferenceKey.vocabularyText)
    }

    private func persist(binding: HotkeyBinding) {
        let keys = Self.preferenceKeys(for: binding.action)
        defaults.set(binding.isEnabled, forKey: keys.enabled)
        defaults.set(binding.shortcut.keyCode, forKey: keys.keyCode)
        defaults.set(binding.shortcut.carbonModifiers, forKey: keys.modifiers)
        defaults.set(binding.shortcut.keyDisplay, forKey: keys.keyDisplay)
    }

    private func persistTranscriptHistory() {
        guard let data = try? JSONEncoder().encode(transcriptHistory) else { return }
        defaults.set(data, forKey: PreferenceKey.transcriptHistory)
    }

    private static func loadConfiguration(defaults: UserDefaults) -> TranscriptionConfiguration {
        var configuration = TranscriptionConfiguration()

        if let rawValue = defaults.string(forKey: PreferenceKey.whisperModel),
           let model = WhisperModelOption(rawValue: rawValue) {
            configuration.model = model
        }

        if let rawValue = defaults.string(forKey: PreferenceKey.decodingMode),
           let decodingMode = WhisperDecodingMode(rawValue: rawValue) {
            configuration.decodingMode = decodingMode
        }

        if let rawValue = defaults.string(forKey: PreferenceKey.fillerWordPolicy),
           let fillerWordPolicy = FillerWordPolicy(rawValue: rawValue) {
            configuration.fillerWordPolicy = fillerWordPolicy
        }

        if defaults.object(forKey: PreferenceKey.keepContext) != nil {
            configuration.keepContext = defaults.bool(forKey: PreferenceKey.keepContext)
        }

        if defaults.object(forKey: PreferenceKey.trimSilence) != nil {
            configuration.trimSilence = defaults.bool(forKey: PreferenceKey.trimSilence)
        }

        if defaults.object(forKey: PreferenceKey.normalizeAudio) != nil {
            configuration.normalizeAudio = defaults.bool(forKey: PreferenceKey.normalizeAudio)
        }

        if defaults.object(forKey: PreferenceKey.livePreviewEnabled) != nil {
            configuration.livePreviewEnabled = defaults.bool(forKey: PreferenceKey.livePreviewEnabled)
        }

        if defaults.object(forKey: PreferenceKey.tapStopsOnNextKeyPress) != nil {
            configuration.tapStopsOnNextKeyPress = defaults.bool(forKey: PreferenceKey.tapStopsOnNextKeyPress)
        }

        if let vocabularyText = defaults.string(forKey: PreferenceKey.vocabularyText) {
            configuration.vocabularyText = vocabularyText
        }

        if !defaults.bool(forKey: PreferenceKey.didMigrateToFastDefaults) {
            configuration.model = .baseEnglish
            configuration.decodingMode = .greedy
            configuration.livePreviewEnabled = false
            defaults.set(true, forKey: PreferenceKey.didMigrateToFastDefaults)
            defaults.set(configuration.model.rawValue, forKey: PreferenceKey.whisperModel)
            defaults.set(configuration.decodingMode.rawValue, forKey: PreferenceKey.decodingMode)
            defaults.set(configuration.livePreviewEnabled, forKey: PreferenceKey.livePreviewEnabled)
        }

        if !defaults.bool(forKey: PreferenceKey.didUndoLivePreviewDefault) {
            let hasStaleLivePreviewMigration =
                defaults.bool(forKey: PreferenceKey.didMigrateToLivePreviewDefault) ||
                defaults.bool(forKey: PreferenceKey.didMigrateToLivePreviewDefaultV2)

            if hasStaleLivePreviewMigration {
                configuration.livePreviewEnabled = false
                defaults.set(false, forKey: PreferenceKey.livePreviewEnabled)
                preferencesLogger.info("Reset stale live preview default from earlier migration")
            }

            defaults.set(true, forKey: PreferenceKey.didUndoLivePreviewDefault)
        }

        return configuration
    }

    private static func loadBinding(defaults: UserDefaults, action: HotkeyAction) -> HotkeyBinding {
        var binding: HotkeyBinding
        switch action {
        case .holdToTalk:
            binding = .defaultHoldToTalk
        case .tapToStartStop:
            binding = .defaultTapToStartStop
        }

        let keys = Self.preferenceKeys(for: action)
        if defaults.object(forKey: keys.enabled) != nil {
            binding.isEnabled = defaults.bool(forKey: keys.enabled)
        }

        if defaults.object(forKey: keys.keyCode) != nil {
            binding.shortcut.keyCode = UInt32(defaults.integer(forKey: keys.keyCode))
        }

        if defaults.object(forKey: keys.modifiers) != nil {
            binding.shortcut.carbonModifiers = UInt32(defaults.integer(forKey: keys.modifiers))
        }

        if let keyDisplay = defaults.string(forKey: keys.keyDisplay), !keyDisplay.isEmpty {
            binding.shortcut.keyDisplay = keyDisplay
        }

        return binding
    }

    private static func currentHotkeyBindings(hold: HotkeyBinding, tap: HotkeyBinding) -> [HotkeyBinding] {
        [hold, tap]
    }

    private static func loadTranscriptHistory(defaults: UserDefaults) -> [TranscriptHistoryItem] {
        guard let data = defaults.data(forKey: PreferenceKey.transcriptHistory),
              let history = try? JSONDecoder().decode([TranscriptHistoryItem].self, from: data) else {
            return []
        }
        return history
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

    private static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func analyticsMilliseconds(_ seconds: TimeInterval) -> Int {
        Int((max(seconds, 0) * 1000).rounded())
    }

    private static func analyticsSeconds(_ seconds: TimeInterval) -> Double {
        (max(seconds, 0) * 100).rounded() / 100
    }

    private static func analyticsErrorReason(for error: Error) -> String {
        switch error {
        case WhisperEngineError.contextInitializationFailed:
            return "contextInitializationFailed"
        case WhisperEngineError.emptyAudio:
            return "emptyAudio"
        case WhisperEngineError.noTranscript:
            return "noTranscript"
        default:
            return "other"
        }
    }

    private var missingPermissionNames: [String] {
        var missing = [String]()
        if !permissions.microphoneGranted {
            missing.append("Microphone")
        }
        if !permissions.accessibilityGranted {
            missing.append("Accessibility")
        }
        if !permissions.inputMonitoringGranted {
            missing.append("Input Monitoring")
        }
        return missing
    }

    static func humanizedErrorMessage(_ raw: String) -> String {
        if raw.contains("Whisper did not return any transcript text") {
            return "Nothing was picked up. Try speaking a little louder or closer to the mic."
        }
        if raw.contains("Press To Start/Stop shortcut rejected") {
            return "Press to Start/Stop needs 3 or more keys. Try something like Control + Option + Space."
        }
        if raw.contains("Hold To Talk shortcut rejected") {
            return "Hold To Talk works best with 1 or 2 modifier keys."
        }

        let lowercased = raw.lowercased()
        if lowercased.contains("nsurlerrordomain") && lowercased.contains("code=-999") {
            return "Model download was interrupted. Try the quality mode again in a moment."
        }
        if lowercased.contains("model not found") || lowercased.contains("repo name") {
            return "Cadence could not find that model yet. Try again while connected to the internet."
        }
        if lowercased.contains("internet") || lowercased.contains("offline") || lowercased.contains("timed out") {
            return "Cadence needs internet once to finish downloading this model."
        }

        return raw
    }

    private static func preferenceKeys(for action: HotkeyAction) -> (enabled: String, keyCode: String, modifiers: String, keyDisplay: String) {
        switch action {
        case .holdToTalk:
            return (
                enabled: PreferenceKey.holdEnabled,
                keyCode: PreferenceKey.holdKeyCode,
                modifiers: PreferenceKey.holdModifiers,
                keyDisplay: PreferenceKey.holdKeyDisplay
            )
        case .tapToStartStop:
            return (
                enabled: PreferenceKey.tapEnabled,
                keyCode: PreferenceKey.tapKeyCode,
                modifiers: PreferenceKey.tapModifiers,
                keyDisplay: PreferenceKey.tapKeyDisplay
            )
        }
    }
}
