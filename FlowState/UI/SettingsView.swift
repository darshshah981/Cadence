import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Form {
            Section("Behavior") {
                LabeledContent("App name", value: "FlowState")
                LabeledContent("Language", value: "English-first")

                shortcutSection(
                    title: HotkeyAction.holdToTalk.displayName,
                    description: HotkeyAction.holdToTalk.shortDescription,
                    ruleDescription: HotkeyAction.holdToTalk.shortcutRuleDescription,
                    isEnabled: holdEnabledBinding,
                    shortcut: Binding(
                        get: { appModel.holdToTalkBinding.shortcut },
                        set: { appModel.setShortcut($0, for: .holdToTalk) }
                    )
                )

                shortcutSection(
                    title: HotkeyAction.tapToStartStop.displayName,
                    description: HotkeyAction.tapToStartStop.shortDescription,
                    ruleDescription: HotkeyAction.tapToStartStop.shortcutRuleDescription,
                    isEnabled: tapEnabledBinding,
                    shortcut: Binding(
                        get: { appModel.tapToStartStopBinding.shortcut },
                        set: { appModel.setShortcut($0, for: .tapToStartStop) }
                    )
                )

                if let hotkeyConflictMessage = appModel.hotkeyConflictMessage {
                    Text(hotkeyConflictMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.orange)
                }

                if let shortcutValidationMessage = appModel.shortcutValidationMessage {
                    Text(shortcutValidationMessage)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.red)
                }
            }

            Section("Transcription") {
                LabeledContent("Current backend", value: appModel.backendDescription)
                LabeledContent("Recommended", value: "Base English + Greedy")

                Picker("Model", selection: modelBinding) {
                    ForEach(WhisperModelOption.allCases) { model in
                        Text("\(model.displayName) (\(model.approximateSize))")
                            .tag(model)
                    }
                }
                .pickerStyle(.menu)

                Picker("Decoding", selection: decodingBinding) {
                    ForEach(WhisperDecodingMode.allCases) { mode in
                        Text(mode.displayName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Keep context across segments", isOn: keepContextBinding)
                Toggle("Trim leading and trailing silence", isOn: trimSilenceBinding)
                Toggle("Normalize quiet recordings", isOn: normalizeAudioBinding)
                Toggle("Enable live subtitles", isOn: livePreviewBinding)
                Toggle("Stop press-to-start/stop dictation on next key press", isOn: tapStopsOnNextKeyPressBinding)

                Button("Reset To Fast Preset") {
                    appModel.resetToRecommendedPreset()
                }

                Text("Current preset: \(appModel.transcriptionConfiguration.summary)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Text("When enabled, FlowState transcribes live and shows subtitles above the bottom pill. When disabled, the pill remains visible but live transcription stays off until release.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Text("Modifier-only shortcuts like `Control + Option` are supported. For press-to-start/stop dictation, you can also stop recording on the next key press instead of repeating the same shortcut.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Section("Vocabulary") {
                Text("Add one preferred term per line. Use `Canonical: alias 1, alias 2` to rewrite common misrecognitions after transcription and hint the model during decoding.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)

                TextEditor(text: vocabularyBinding)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(minHeight: 110)
            }

            Section("Permissions") {
                LabeledContent("Microphone", value: appModel.permissions.microphoneGranted ? "Granted" : "Missing")
                LabeledContent("Accessibility", value: appModel.permissions.accessibilityGranted ? "Granted" : "Missing")
                LabeledContent("Input Monitoring", value: appModel.permissions.inputMonitoringGranted ? "Granted" : "Missing")
                Text("macOS permissions are tied to the exact app bundle path and signature. If you move or replace the app, re-enable that specific copy in System Settings.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func shortcutSection(
        title: String,
        description: String,
        ruleDescription: String,
        isEnabled: Binding<Bool>,
        shortcut: Binding<HotkeyConfiguration>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(title, isOn: isEnabled)
            Text(description)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Text(ruleDescription)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            ShortcutRecorderField(
                shortcut: shortcut,
                onRecordingChange: { isRecording in
                    appModel.setShortcutRecordingActive(isRecording)
                }
            )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private var modelBinding: Binding<WhisperModelOption> {
        Binding(
            get: { appModel.transcriptionConfiguration.model },
            set: { appModel.setWhisperModel($0) }
        )
    }

    private var decodingBinding: Binding<WhisperDecodingMode> {
        Binding(
            get: { appModel.transcriptionConfiguration.decodingMode },
            set: { appModel.setDecodingMode($0) }
        )
    }

    private var keepContextBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.keepContext },
            set: { appModel.setKeepContext($0) }
        )
    }

    private var trimSilenceBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.trimSilence },
            set: { appModel.setTrimSilence($0) }
        )
    }

    private var normalizeAudioBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.normalizeAudio },
            set: { appModel.setNormalizeAudio($0) }
        )
    }

    private var livePreviewBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.livePreviewEnabled },
            set: { appModel.setLivePreviewEnabled($0) }
        )
    }

    private var vocabularyBinding: Binding<String> {
        Binding(
            get: { appModel.transcriptionConfiguration.vocabularyText },
            set: { appModel.setVocabularyText($0) }
        )
    }

    private var tapStopsOnNextKeyPressBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.tapStopsOnNextKeyPress },
            set: { appModel.setTapStopsOnNextKeyPress($0) }
        )
    }

    private var holdEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.holdToTalkBinding.isEnabled },
            set: { appModel.setHoldToTalkEnabled($0) }
        )
    }

    private var tapEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.tapToStartStopBinding.isEnabled },
            set: { appModel.setTapToStartStopEnabled($0) }
        )
    }
}

struct ShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: HotkeyConfiguration
    var onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderContainerView {
        let view = ShortcutRecorderContainerView()
        view.shortcut = shortcut
        view.onShortcutChange = { newShortcut in
            shortcut = newShortcut
        }
        view.onRecordingChange = onRecordingChange
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderContainerView, context: Context) {
        nsView.shortcut = shortcut
        nsView.onShortcutChange = { newShortcut in
            shortcut = newShortcut
        }
        nsView.onRecordingChange = onRecordingChange
    }
}

final class ShortcutRecorderContainerView: NSView {
    var onShortcutChange: ((HotkeyConfiguration) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    var shortcut: HotkeyConfiguration = .defaultHoldToTalk {
        didSet {
            guard !isRecording else { return }
            recorderButton.title = shortcut.displayName
        }
    }

    private let recorderButton = NSButton(title: "", target: nil, action: nil)
    private var pendingModifierOnlyShortcut = false
    private var bestModifierOnlyShortcut: HotkeyConfiguration?
    private var isRecording = false {
        didSet {
            recorderButton.title = isRecording ? "Type shortcut" : shortcut.displayName
            recorderButton.contentTintColor = isRecording ? .systemBlue : .labelColor
            onRecordingChange?(isRecording)
            if !isRecording {
                pendingModifierOnlyShortcut = false
                bestModifierOnlyShortcut = nil
            }
            needsLayout = true
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        recorderButton.bezelStyle = .rounded
        recorderButton.font = .systemFont(ofSize: 12.5, weight: .medium)
        recorderButton.target = self
        recorderButton.action = #selector(beginRecording)
        recorderButton.title = shortcut.displayName
        addSubview(recorderButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        recorderButton.frame = bounds
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 30)
    }

    @objc
    private func beginRecording() {
        isRecording = true
        bestModifierOnlyShortcut = nil
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            isRecording = false
            return
        }

        if Self.isModifierOnlyKey(event.keyCode) {
            return
        }

        let modifierFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let newShortcut = HotkeyConfiguration.from(
            keyCode: event.keyCode,
            modifiers: modifierFlags,
            characters: event.charactersIgnoringModifiers
        )
        shortcut = newShortcut
        onShortcutChange?(newShortcut)
        pendingModifierOnlyShortcut = false
        isRecording = false
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }

        let modifierFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let preview = HotkeyConfiguration.modifierDisplayName(for: HotkeyConfiguration.carbonModifiers(for: modifierFlags))
        recorderButton.title = preview.isEmpty ? "Type shortcut" : "\(preview) + …"

        if modifierFlags.isEmpty {
            if pendingModifierOnlyShortcut {
                if let bestModifierOnlyShortcut {
                    shortcut = bestModifierOnlyShortcut
                    onShortcutChange?(bestModifierOnlyShortcut)
                }
                isRecording = false
            }
            return
        }

        if Self.isModifierOnlyKey(event.keyCode) {
            let candidate = HotkeyConfiguration.modifierOnly(modifiers: modifierFlags)
            if shouldPromoteModifierOnlyShortcut(candidate) {
                bestModifierOnlyShortcut = candidate
                shortcut = candidate
                onShortcutChange?(candidate)
            }
            pendingModifierOnlyShortcut = true
        }
    }

    private static func isModifierOnlyKey(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62].contains(Int(keyCode))
    }

    private func shouldPromoteModifierOnlyShortcut(_ candidate: HotkeyConfiguration) -> Bool {
        guard let bestModifierOnlyShortcut else { return true }
        return candidate.carbonModifiers.nonzeroBitCount >= bestModifierOnlyShortcut.carbonModifiers.nonzeroBitCount
    }
}
