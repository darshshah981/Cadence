import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @State private var isAdvancedExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            generalSection
            advancedSection
            versionFooter
        }
        .animation(FlowMotion.enabled(FlowMotion.section, reduceMotion: reduceMotion), value: isAdvancedExpanded)
        .animation(FlowMotion.enabled(FlowMotion.control, reduceMotion: reduceMotion), value: appModel.dictationQualityPreset)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowSectionHeader(title: "General")
            FlowSectionCard {
                if appModel.permissions.allRequiredGranted {
                    setupCompleteRow
                } else {
                    PermissionWizardRow(
                        permissions: appModel.permissions,
                        action: appModel.openPermissionsWizard
                    )
                }
                insetDivider

                shortcutsSection

                insetDivider

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

                    ModelReadinessInlineView(summary: appModel.modelReadinessSummary)
                }
                .padding(12)

                insetDivider

                HStack {
                    SettingsLabelRow(
                        title: "Check setup",
                        description: "Refresh permissions and make sure the current model is ready."
                    )

                    Spacer()

                    Button("Run") {
                        appModel.runSetupCheck()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowSectionHeader(title: "Advanced")
            FlowSectionCard {
                DisclosureGroup(isExpanded: advancedExpandedBinding) {
                    VStack(alignment: .leading, spacing: 0) {
                        insetDivider
                        advancedModelControls
                        insetDivider
                        advancedAudioControls
                        insetDivider
                        fillerWordControls
                        insetDivider
                        vocabularyControls
                        insetDivider
                        privacyControls
                    }
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced settings")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FlowTheme.textPrimary)

                        Text("Model selection, cleanup rules, custom words, and privacy.")
                            .font(.system(size: 12))
                            .foregroundStyle(FlowTheme.textSecondary)
                    }
                }
                .padding(12)
            }
        }
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

    private var fillerWordControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsLabelRow(
                title: "Filler words",
                description: appModel.transcriptionConfiguration.fillerWordPolicy.description
            )

            FillerWordSegmentedControl(selection: fillerWordPolicyBinding)
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

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shortcuts")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text("Enable either mode, or keep both on with different shortcuts.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)

            if let message = appModel.shortcutValidationMessage ?? appModel.hotkeyConflictMessage {
                ShortcutWarningView(message: message)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            insetDivider

            ShortcutSettingRow(
                title: "Hold to speak",
                description: "Hold the shortcut, speak, then release to insert.",
                hint: "Best for quick bursts. Modifier-only shortcuts are easiest here.",
                isEnabled: holdEnabledBinding,
                shortcut: holdShortcutBinding,
                onRecordingChange: appModel.setShortcutRecordingActive
            )

            insetDivider

            ShortcutSettingRow(
                title: "Press to start/stop",
                description: "Press once to start, then press again or use the pill to stop.",
                hint: pressToStartHint,
                isEnabled: tapEnabledBinding,
                shortcut: tapShortcutBinding,
                onRecordingChange: appModel.setShortcutRecordingActive
            )

            insetDivider

            SettingsToggleRow(
                title: "Show shortcut dock",
                description: "Keep the floating shortcut reminder above the bottom bar on the home screen.",
                isOn: showsShortcutDockBinding
            )
        }
    }

    private var setupCompleteRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(FlowTheme.success)

            VStack(alignment: .leading, spacing: 4) {
                Text("Mac setup complete")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text("Microphone, Accessibility, and Input Monitoring are all ready.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Review") {
                appModel.openPermissionsWizard()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
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

    private var holdShortcutBinding: Binding<HotkeyConfiguration> {
        Binding(
            get: { appModel.holdToTalkBinding.shortcut },
            set: { appModel.setShortcut($0, for: .holdToTalk) }
        )
    }

    private var tapShortcutBinding: Binding<HotkeyConfiguration> {
        Binding(
            get: { appModel.tapToStartStopBinding.shortcut },
            set: { appModel.setShortcut($0, for: .tapToStartStop) }
        )
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

    private var showsShortcutDockBinding: Binding<Bool> {
        Binding(
            get: { appModel.showsShortcutDock },
            set: { appModel.setShowsShortcutDock($0) }
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

    private var advancedExpandedBinding: Binding<Bool> {
        Binding(
            get: { isAdvancedExpanded },
            set: { newValue in
                withAnimation(FlowMotion.enabled(FlowMotion.section, reduceMotion: reduceMotion)) {
                    isAdvancedExpanded = newValue
                }
            }
        )
    }
}

private struct ModelReadinessInlineView: View {
    let summary: ModelReadinessSummary

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(summary.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
    }

    private var tint: Color {
        switch summary.tone {
        case .ready:
            return FlowTheme.success
        case .working:
            return FlowTheme.accent
        case .attention:
            return FlowTheme.error
        }
    }

    private var background: Color {
        switch summary.tone {
        case .ready:
            return FlowTheme.successSubtle
        case .working:
            return FlowTheme.accentSubtle
        case .attention:
            return FlowTheme.errorSubtle
        }
    }

    private var border: Color {
        switch summary.tone {
        case .ready:
            return FlowTheme.success
        case .working:
            return FlowTheme.accentBorder
        case .attention:
            return FlowTheme.error
        }
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

private struct ShortcutWarningView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.error)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FlowTheme.error)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowTheme.errorSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.error.opacity(0.55), lineWidth: 1)
        )
    }
}

private struct TriggerModeSegmentedControl: View {
    @Binding var selection: DictationTriggerMode

    var body: some View {
        FlowSegmentedControl(
            options: Array(DictationTriggerMode.allCases),
            selection: $selection,
            title: { $0.displayName.replacingOccurrences(of: " To ", with: " to ") }
        )
    }
}

private struct QualityPresetSegmentedControl: View {
    @Binding var selection: DictationQualityPreset

    var body: some View {
        FlowSegmentedControl(
            options: Array(DictationQualityPreset.allCases),
            selection: $selection,
            title: \.displayName
        )
    }
}

private struct FillerWordSegmentedControl: View {
    @Binding var selection: FillerWordPolicy

    var body: some View {
        FlowSegmentedControl(
            options: Array(FillerWordPolicy.allCases),
            selection: $selection,
            title: \.displayName
        )
    }
}

private struct FlowSegmentedControl<Option: Identifiable & Equatable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                segmentButton(for: option)
            }
        }
        .padding(4)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
        .animation(FlowMotion.enabled(FlowMotion.control, reduceMotion: reduceMotion), value: selection)
    }

    private func segmentButton(for option: Option) -> some View {
        let isSelected = selection == option

        return Button {
            guard selection != option else { return }
            withAnimation(FlowMotion.enabled(FlowMotion.control, reduceMotion: reduceMotion)) {
                selection = option
            }
        } label: {
            Text(title(option))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? FlowTheme.textPrimary : FlowTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(FlowTheme.elevated)
                            .matchedGeometryEffect(id: "selected-segment", in: selectionNamespace)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? FlowTheme.borderStrong : Color.clear, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(FlowMotion.enabled(FlowMotion.control, reduceMotion: reduceMotion)) {
                action()
            }
        } label: {
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
        .animation(FlowMotion.enabled(FlowMotion.control, reduceMotion: reduceMotion), value: isSelected)
    }
}

private struct DecodingSegmentedControl: View {
    @Binding var selection: WhisperDecodingMode

    var body: some View {
        FlowSegmentedControl(
            options: Array(WhisperDecodingMode.allCases),
            selection: $selection,
            title: \.productLabel
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
