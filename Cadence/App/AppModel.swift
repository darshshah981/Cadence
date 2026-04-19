import AppKit
import Combine
import Foundation
import SwiftUI

enum MenuScreen {
    case home
    case settings
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
        static let holdEnabled = "FlowState.holdEnabled"
        static let holdKeyCode = "FlowState.holdKeyCode"
        static let holdModifiers = "FlowState.holdModifiers"
        static let holdKeyDisplay = "FlowState.holdKeyDisplay"
        static let tapEnabled = "FlowState.tapEnabled"
        static let tapKeyCode = "FlowState.tapKeyCode"
        static let tapModifiers = "FlowState.tapModifiers"
        static let tapKeyDisplay = "FlowState.tapKeyDisplay"
        static let transcriptHistory = "FlowState.transcriptHistory"
        static let didMigrateToFastDefaults = "FlowState.didMigrateToFastDefaults"
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
    @Published private(set) var backendDescription = "Loading local Whisper backend"
    @Published private(set) var transcriptionConfiguration: TranscriptionConfiguration
    @Published var menuScreen: MenuScreen = .home

    @Published private(set) var holdToTalkBinding: HotkeyBinding
    @Published private(set) var tapToStartStopBinding: HotkeyBinding

    private let permissionsService: PermissionsService
    private let permissionGuideWindowController = PermissionGuideWindowController()
    private let coordinator: DictationCoordinator
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var lastExternalApplication: NSRunningApplication?

    init() {
        let defaults = UserDefaults.standard
        let initialHoldBinding = AppModel.loadBinding(defaults: defaults, action: .holdToTalk)
        let initialTapBinding = AppModel.loadBinding(defaults: defaults, action: .tapToStartStop)
        self.defaults = defaults
        self.transcriptionConfiguration = AppModel.loadConfiguration(defaults: defaults)
        self.holdToTalkBinding = initialHoldBinding
        self.tapToStartStopBinding = initialTapBinding
        self.transcriptHistory = AppModel.loadTranscriptHistory(defaults: defaults)

        let permissionsService = PermissionsService()
        self.permissionsService = permissionsService
        self.permissions = permissionsService.snapshot()

        let hudController = HUDWindowController()
        let transcriptionEngine = LocalWhisperTranscriptionEngine(modelManager: WhisperModelManager())
        let audioCaptureService = AudioCaptureService()
        let textInsertionService = TextInsertionService()

        self.coordinator = DictationCoordinator(
            hotkeyService: HotkeyService(bindings: Self.currentHotkeyBindings(hold: initialHoldBinding, tap: initialTapBinding)),
            permissionsService: permissionsService,
            audioCaptureService: audioCaptureService,
            transcriptionEngine: transcriptionEngine,
            textInsertionService: textInsertionService,
            hudController: hudController
        )

        bindCoordinator()
        bindPermissionRefresh()
        Task {
            await refreshPermissions()
            await applyTranscriptionConfiguration(prewarm: false)
            await warmBackend()
        }
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

    var hotkeyConflictMessage: String? {
        guard holdToTalkBinding.isEnabled, tapToStartStopBinding.isEnabled else { return nil }
        guard holdToTalkBinding.shortcut.conflicts(with: tapToStartStopBinding.shortcut) else { return nil }
        return "Hold To Talk and Press To Start/Stop cannot use the same shortcut at the same time."
    }

    func refreshPermissions() async {
        permissions = permissionsService.snapshot()
    }

    func requestMicrophoneAccess() {
        Task {
            _ = await permissionsService.requestMicrophoneAccess()
            await refreshPermissions()
        }
    }

    func requestAccessibilityAccess() {
        permissionsService.requestAccessibilityAccess()
        showPermissionGuide(for: .accessibility)
        schedulePermissionRefreshBurst()
    }

    func requestInputMonitoringAccess() {
        permissionsService.requestInputMonitoringAccess()
        showPermissionGuide(for: .inputMonitoring)
        schedulePermissionRefreshBurst()
    }

    func showSettingsScreen() {
        menuScreen = .settings
    }

    func showHomeScreen() {
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
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func warmBackend() async {
        do {
            let summary = try await coordinator.prewarmBackend()
            backendDescription = summary
        } catch {
            lastError = error.localizedDescription
            backendDescription = "Local Whisper unavailable"
        }
    }

    func setWhisperModel(_ model: WhisperModelOption) {
        updateTranscriptionConfiguration { $0.model = model }
    }

    func setDecodingMode(_ decodingMode: WhisperDecodingMode) {
        updateTranscriptionConfiguration { $0.decodingMode = decodingMode }
    }

    func setFillerWordPolicy(_ fillerWordPolicy: FillerWordPolicy) {
        updateTranscriptionConfiguration { $0.fillerWordPolicy = fillerWordPolicy }
    }

    func setKeepContext(_ keepContext: Bool) {
        updateTranscriptionConfiguration { $0.keepContext = keepContext }
    }

    func setTrimSilence(_ trimSilence: Bool) {
        updateTranscriptionConfiguration { $0.trimSilence = trimSilence }
    }

    func setNormalizeAudio(_ normalizeAudio: Bool) {
        updateTranscriptionConfiguration { $0.normalizeAudio = normalizeAudio }
    }

    func setLivePreviewEnabled(_ livePreviewEnabled: Bool) {
        updateTranscriptionConfiguration { $0.livePreviewEnabled = livePreviewEnabled }
    }

    func setTapStopsOnNextKeyPress(_ enabled: Bool) {
        updateTranscriptionConfiguration { $0.tapStopsOnNextKeyPress = enabled }
    }

    func setVocabularyText(_ vocabularyText: String) {
        updateTranscriptionConfiguration { $0.vocabularyText = vocabularyText }
    }

    func resetToRecommendedPreset() {
        transcriptionConfiguration = TranscriptionConfiguration()
        persist(configuration: transcriptionConfiguration)

        Task {
            await applyTranscriptionConfiguration(prewarm: true)
        }
    }

    func setHoldToTalkEnabled(_ isEnabled: Bool) {
        guard holdToTalkBinding.isEnabled != isEnabled else { return }
        holdToTalkBinding.isEnabled = isEnabled
        persist(binding: holdToTalkBinding)
        refreshRegisteredHotkeys()
    }

    func setTapToStartStopEnabled(_ isEnabled: Bool) {
        guard tapToStartStopBinding.isEnabled != isEnabled else { return }
        tapToStartStopBinding.isEnabled = isEnabled
        persist(binding: tapToStartStopBinding)
        refreshRegisteredHotkeys()
    }

    func setShortcut(_ shortcut: HotkeyConfiguration, for action: HotkeyAction) {
        guard action.supports(shortcut) else {
            shortcutValidationMessage = "\(action.displayName) shortcut rejected. \(action.shortcutRuleDescription)"
            return
        }

        shortcutValidationMessage = nil

        switch action {
        case .holdToTalk:
            guard holdToTalkBinding.shortcut != shortcut else { return }
            holdToTalkBinding.shortcut = shortcut
            persist(binding: holdToTalkBinding)
        case .tapToStartStop:
            guard tapToStartStopBinding.shortcut != shortcut else { return }
            tapToStartStopBinding.shortcut = shortcut
            persist(binding: tapToStartStopBinding)
        }

        refreshRegisteredHotkeys()
    }

    func setShortcutRecordingActive(_ isActive: Bool) {
        coordinator.setHotkeysPaused(isActive)
    }

    func copyTranscript(_ item: TranscriptHistoryItem) {
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

        coordinator.onTranscript = { [weak self] transcript in
            self?.lastTranscript = transcript
            self?.appendTranscriptToHistory(transcript)
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

    private func showPermissionGuide(for kind: PermissionGuideKind) {
        NSApp.activate(ignoringOtherApps: true)
        permissionGuideWindowController.show(kind: kind, appURL: Bundle.main.bundleURL)
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

    private func appendTranscriptToHistory(_ transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        transcriptHistory.insert(TranscriptHistoryItem(text: cleaned), at: 0)
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

        transcriptionConfiguration = next
        persist(configuration: next)

        Task {
            await applyTranscriptionConfiguration(prewarm: true)
        }
    }

    private func applyTranscriptionConfiguration(prewarm: Bool) async {
        do {
            let summary = try await coordinator.updateTranscriptionConfiguration(transcriptionConfiguration)
            backendDescription = summary
            if prewarm {
                await warmBackend()
            }
        } catch {
            lastError = error.localizedDescription
            backendDescription = "Local Whisper unavailable"
        }
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
