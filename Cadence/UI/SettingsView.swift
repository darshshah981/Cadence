import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @State private var isAdvancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupSection
            shortcutsSection
            dictationSection
            advancedSection
            versionFooter
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowSectionHeader(title: "Setup")
            FlowSectionCard {
                PermissionWizardRow(
                    permissions: appModel.permissions,
                    action: appModel.openPermissionsWizard
                )
            }
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowSectionHeader(title: "Shortcut")
            FlowSectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsLabelRow(
                        title: "Dictation shortcut",
                        description: shortcutDescription
                    )

                    ShortcutRecorderField(
                        shortcut: primaryShortcutBinding,
                        onRecordingChange: appModel.setShortcutRecordingActive
                    )
                    .frame(maxWidth: .infinity, minHeight: 42)
                }
                .padding(12)

                insetDivider

                VStack(alignment: .leading, spacing: 10) {
                    SettingsLabelRow(
                        title: "Mode",
                        description: appModel.primaryTriggerMode.shortDescription
                    )

                    TriggerModeSegmentedControl(
                        selection: Binding(
                            get: { appModel.primaryTriggerMode },
                            set: { appModel.setPrimaryTriggerMode($0) }
                        )
                    )
                }
                .padding(12)
            }
        }
    }

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowSectionHeader(title: "Dictation")
            FlowSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsLabelRow(
                        title: "Quality",
                        description: appModel.dictationQualityPreset.description
                    )

                    QualityPresetSegmentedControl(
                        selection: Binding(
                            get: { appModel.dictationQualityPreset },
                            set: { appModel.setDictationQualityPreset($0) }
                        )
                    )
                }
                .padding(12)

                insetDivider

                VStack(alignment: .leading, spacing: 12) {
                    SettingsLabelRow(
                        title: "Filler words",
                        description: appModel.transcriptionConfiguration.fillerWordPolicy.description
                    )

                    FillerWordSegmentedControl(selection: fillerWordPolicyBinding)
                }
                .padding(12)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowSectionHeader(title: "Advanced")
            FlowSectionCard {
                DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                    advancedContent
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced settings")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FlowTheme.textPrimary)

                        Text("Models, audio behavior, custom words, and privacy.")
                            .font(.system(size: 12))
                            .foregroundStyle(FlowTheme.textSecondary)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            insetDivider
            advancedModelControls
            insetDivider
            advancedAudioControls
            insetDivider
            vocabularyControls
            insetDivider
            privacyControls
        }
        .padding(.top, 10)
    }

    private var advancedModelControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsLabelRow(
                title: "Model",
                description: "Manual model selection for testing speed and accuracy."
            )

            VStack(spacing: 8) {
                ForEach(WhisperModelOption.allCases) { model in
                    ModelOptionRow(
                        model: model,
                        isSelected: appModel.transcriptionConfiguration.model == model
                    ) {
                        appModel.setWhisperModel(model)
                    }
                }
            }

            SettingsLabelRow(
                title: "Decoding",
                description: "Fast is lower latency; Accurate searches harder."
            )

            DecodingSegmentedControl(
                selection: Binding(
                    get: { appModel.transcriptionConfiguration.decodingMode },
                    set: { appModel.setDecodingMode($0) }
                )
            )
        }
        .padding(12)
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowSectionHeader(title: "Audio")
            FlowSectionCard {
                SettingsToggleRow(
                    title: "Trim silence",
                    description: "Removes dead air before and after speech.",
                    isOn: trimSilenceBinding
                )
                insetDivider
                SettingsToggleRow(
                    title: "Normalize audio",
                    description: "Brings quiet recordings into a steadier range.",
                    isOn: normalizeAudioBinding
                )
                insetDivider
                SettingsToggleRow(
                    title: "Keep context",
                    description: "Helps punctuation and continuity during longer dictation.",
                    isOn: keepContextBinding
                )
                insetDivider
                SettingsToggleRow(
                    title: "Stop on next key press",
                    description: "For press-to-start mode, stop dictation as soon as you begin typing.",
                    isOn: tapStopsOnNextKeyPressBinding
                )
            }
        }
    }

    private var advancedAudioControls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Trim silence",
                description: "Removes dead air before and after speech.",
                isOn: trimSilenceBinding
            )
            insetDivider
            SettingsToggleRow(
                title: "Normalize audio",
                description: "Brings quiet recordings into a steadier range.",
                isOn: normalizeAudioBinding
            )
            insetDivider
            SettingsToggleRow(
                title: "Keep context",
                description: "Helps punctuation and continuity during longer dictation.",
                isOn: keepContextBinding
            )
            insetDivider
            SettingsToggleRow(
                title: "Stop on next key press",
                description: "For press-to-start mode, stop dictation as soon as you begin typing.",
                isOn: tapStopsOnNextKeyPressBinding
            )
        }
    }

    private var vocabularyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Names & custom words")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textPrimary)

            Text("One preferred term per line. Example: `Epic Games: Epic`")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)

            TextEditor(text: vocabularyBinding)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(FlowTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88)
                .padding(8)
                .background(FlowTheme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(FlowTheme.border, lineWidth: 1)
                )
        }
        .padding(12)
    }

    private var privacyControls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Share analytics",
                description: "Sends privacy-safe product events. Never includes audio, transcripts, vocabulary, or shortcut keys.",
                isOn: analyticsEnabledBinding
            )

            insetDivider

            HStack {
                SettingsLabelRow(
                    title: "Privacy",
                    description: "Read what Cadence collects and what stays on your Mac."
                )

                Spacer()

                Button("Open") {
                    if let url = URL(string: "https://github.com/darshshah981/Cadence/blob/main/docs/privacy.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
        }
    }

    private var versionFooter: some View {
        Text("Cadence \(appVersion)")
            .font(.system(size: 11))
            .foregroundStyle(FlowTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return [short, build].compactMap { $0 }.joined(separator: " • ")
    }

    private var shortcutDescription: String {
        switch appModel.primaryTriggerMode {
        case .holdToTalk:
            return "Press and hold to dictate, then release to finish."
        case .tapToStartStop:
            return "Press once to start, then stop from the shortcut or pill."
        }
    }

    private var pressToStartHint: String {
        let current = appModel.tapToStartStopBinding.shortcut.symbolDisplayName
        let examples = ["⌃ ⌥ SPACE", "⌃ ⇧ D"]
        let fallback = examples.first(where: { $0 != current }) ?? examples[0]
        return "Needs 3+ keys. Try \(fallback)"
    }

    private var insetDivider: some View {
        Divider()
            .overlay(FlowTheme.border)
            .padding(.leading, 12)
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

    private var vocabularyBinding: Binding<String> {
        Binding(
            get: { appModel.transcriptionConfiguration.vocabularyText },
            set: { appModel.setVocabularyText($0) }
        )
    }

    private var fillerWordPolicyBinding: Binding<FillerWordPolicy> {
        Binding(
            get: { appModel.transcriptionConfiguration.fillerWordPolicy },
            set: { appModel.setFillerWordPolicy($0) }
        )
    }

    private var primaryShortcutBinding: Binding<HotkeyConfiguration> {
        Binding(
            get: {
                switch appModel.primaryTriggerMode {
                case .holdToTalk:
                    return appModel.holdToTalkBinding.shortcut
                case .tapToStartStop:
                    return appModel.tapToStartStopBinding.shortcut
                }
            },
            set: { shortcut in
                appModel.setShortcut(shortcut, for: primaryShortcutAction)
            }
        )
    }

    private var primaryShortcutAction: HotkeyAction {
        switch appModel.primaryTriggerMode {
        case .holdToTalk:
            return .holdToTalk
        case .tapToStartStop:
            return .tapToStartStop
        }
    }

    private var tapStopsOnNextKeyPressBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.tapStopsOnNextKeyPress },
            set: { appModel.setTapStopsOnNextKeyPress($0) }
        )
    }

    private var analyticsEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.analyticsEnabled },
            set: { appModel.setAnalyticsEnabled($0) }
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

private struct FlowInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}

private struct SettingsLabelRow: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textPrimary)

            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TriggerModeSegmentedControl: View {
    @Binding var selection: DictationTriggerMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DictationTriggerMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.displayName.replacingOccurrences(of: " To ", with: " to "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == mode ? FlowTheme.textPrimary : FlowTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == mode ? FlowTheme.elevated : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(selection == mode ? FlowTheme.borderStrong : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private struct QualityPresetSegmentedControl: View {
    @Binding var selection: DictationQualityPreset

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DictationQualityPreset.allCases) { preset in
                Button {
                    selection = preset
                } label: {
                    Text(preset.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == preset ? FlowTheme.textPrimary : FlowTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == preset ? FlowTheme.elevated : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(selection == preset ? FlowTheme.borderStrong : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private struct FillerWordSegmentedControl: View {
    @Binding var selection: FillerWordPolicy

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FillerWordPolicy.allCases) { policy in
                Button {
                    selection = policy
                } label: {
                    Text(policy.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == policy ? FlowTheme.textPrimary : FlowTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == policy ? FlowTheme.elevated : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(FlowToggleStyle())
        }
        .padding(12)
    }
}

private struct PermissionWizardRow: View {
    let permissions: PermissionsSnapshot
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(permissions.allRequiredGranted ? "Cadence is ready" : "Finish setup")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(action: action) {
                Text(permissions.allRequiredGranted ? "Review" : "Open Wizard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    private var summary: String {
        if permissions.allRequiredGranted {
            return "Microphone, Accessibility, and Input Monitoring are enabled."
        }

        let missing = [
            permissions.microphoneGranted ? nil : "Microphone",
            permissions.accessibilityGranted ? nil : "Accessibility",
            permissions.inputMonitoringGranted ? nil : "Input Monitoring"
        ]
        .compactMap { $0 }
        .joined(separator: ", ")

        return "Missing: \(missing)"
    }
}

private struct PermissionBadge: View {
    let isGranted: Bool

    var body: some View {
        Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isGranted ? FlowTheme.success : FlowTheme.error)
            .frame(width: 18, height: 18)
            .accessibilityLabel(isGranted ? "Granted" : "Not granted")
    }
}

private struct ModelOptionRow: View {
    let model: WhisperModelOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? FlowTheme.accent : FlowTheme.textTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName.replacingOccurrences(of: " English", with: ""))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FlowTheme.textPrimary)

                    Text("\(model.approximateSize) • \(model.qualityDescriptor)")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)
                }

                Spacer()
            }
            .padding(10)
            .background(isSelected ? FlowTheme.subtle : FlowTheme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? FlowTheme.borderStrong : FlowTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DecodingSegmentedControl: View {
    @Binding var selection: WhisperDecodingMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WhisperDecodingMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.productLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == mode ? FlowTheme.textPrimary : FlowTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == mode ? FlowTheme.elevated : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(selection == mode ? FlowTheme.borderStrong : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private struct ShortcutSettingRow: View {
    let title: String
    let description: String
    let hint: String
    @Binding var isEnabled: Bool
    @Binding var shortcut: HotkeyConfiguration
    let onRecordingChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FlowTheme.textPrimary)

                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(FlowToggleStyle())
            }

            ShortcutRecorderField(shortcut: $shortcut, onRecordingChange: onRecordingChange)
                .frame(maxWidth: .infinity, minHeight: 42)

            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.textTertiary)
        }
        .padding(12)
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
            updateButtonTitle()
        }
    }

    private let recorderButton = NSButton(title: "", target: nil, action: nil)
    private var pendingModifierOnlyShortcut = false
    private var bestModifierOnlyShortcut: HotkeyConfiguration?
    private var isRecording = false {
        didSet {
            recorderButton.contentTintColor = isRecording ? .systemOrange : .labelColor
            updateButtonTitle()
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

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        recorderButton.isBordered = false
        recorderButton.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        recorderButton.alignment = .left
        recorderButton.target = self
        recorderButton.action = #selector(beginRecording)
        addSubview(recorderButton)
        updateButtonTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        recorderButton.frame = bounds.insetBy(dx: 10, dy: 8)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 220, height: 42)
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
        let preview = HotkeyConfiguration.symbolModifierDisplayName(for: HotkeyConfiguration.carbonModifiers(for: modifierFlags))
        recorderButton.title = preview.isEmpty ? "Press your shortcut keys…" : "\(preview) …"

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

    private func updateButtonTitle() {
        recorderButton.title = isRecording ? "Press your shortcut keys…" : shortcut.symbolDisplayName
        layer?.borderColor = (isRecording ? NSColor.systemOrange : NSColor.separatorColor).cgColor
    }

    private func shouldPromoteModifierOnlyShortcut(_ candidate: HotkeyConfiguration) -> Bool {
        guard let currentBest = bestModifierOnlyShortcut else {
            return true
        }
        return candidate.componentCount >= currentBest.componentCount
    }

    private static func isModifierOnlyKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62:
            return true
        default:
            return false
        }
    }
}
