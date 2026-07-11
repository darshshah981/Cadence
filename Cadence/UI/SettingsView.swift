import AppKit
import SwiftUI

struct SettingsView: View {
    private static let writingEnvironmentsScrollID = "settings-writing-environments"

    @ObservedObject var appModel: AppModel
    var maxContentWidth: CGFloat?
    var contentPadding = EdgeInsets()
    @State private var isAdvancedExpanded = false
    @State private var editingShortcut: PersonalShortcut?
    @State private var editingStyleProfile: WritingStyleProfile?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    setupSection
                    startStopSection
                    scribeSection
                    personalizationSection
                    captureSection
                    writingStyleSection
                    privacySection
                    advancedSection
                    versionFooter
                }
                .frame(maxWidth: maxContentWidth, alignment: .topLeading)
                .padding(contentPadding)
                .padding(.bottom, 2)
            }
            .animation(FlowMotion.enabled(FlowMotion.section, reduceMotion: reduceMotion), value: isAdvancedExpanded)
            .animation(FlowMotion.enabled(FlowMotion.control, reduceMotion: reduceMotion), value: appModel.dictationQualityPreset)
            .onAppear {
                #if DEBUG
                if ScribeLaunchFixtures.current == .settings {
                    scrollProxy.scrollTo(Self.writingEnvironmentsScrollID, anchor: .top)
                }
                #endif
            }
            .sheet(item: $editingShortcut) { shortcut in
                PersonalShortcutEditor(shortcut: shortcut) { appModel.savePersonalShortcut($0) }
            }
            .sheet(item: $editingStyleProfile) { profile in
                WritingStyleProfileEditor(profile: profile) { appModel.saveWritingStyleProfile($0) }
            }
            .sheet(
                isPresented: $appModel.isScribeProviderSetupPresented,
                onDismiss: appModel.dismissScribeProviderSetup
            ) {
                ScribeProviderSetupView(
                    onConnectDeepSeek: { try await appModel.connectDeepSeekForScribe(credential: $0) },
                    onConnectAdvanced: {
                        try await appModel.connectAdvancedScribeProvider(
                            baseURL: $0,
                            model: $1,
                            credential: $2
                        )
                    },
                    onGeneratePractice: { try await appModel.generateScribePracticeDraft() },
                    onSwitchProvider: appModel.switchScribeProviderSetup,
                    onDismiss: appModel.dismissScribeProviderSetup
                )
            }
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: title, systemImage: systemImage)
            content()
        }
    }

    private var setupSection: some View {
        settingsSection(title: "Setup", systemImage: "checkmark.seal") {
            FlowSectionCard {
                if appModel.permissions.allRequiredGranted {
                    setupCompleteRow
                } else {
                    PermissionWizardRow(
                        permissions: appModel.permissions,
                        action: appModel.openPermissionsWizard
                    )
                }
            }
        }
    }

    private var startStopSection: some View {
        settingsSection(title: "Start & Stop", systemImage: "keyboard") {
            FlowSectionCard {
                shortcutsSection
            }
        }
    }

    private var captureSection: some View {
        settingsSection(title: "Capture", systemImage: "waveform") {
            FlowSectionCard {
                captureReadinessRow
                insetDivider
                calendarControls
                insetDivider
                meetingNotesRow
                insetDivider
                setupCheckRow
            }
        }
    }

    private var scribeSection: some View {
        settingsSection(title: "Scribe", systemImage: "sparkles") {
            FlowSectionCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: appModel.scribeReadiness.canGenerate ? "sparkles" : "lock.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(appModel.scribeReadiness.canGenerate ? FlowTheme.success : FlowTheme.textTertiary)
                        .frame(width: 20)

                    SettingsLabelRow(
                        title: appModel.scribeReadiness.canGenerate ? "Ready to draft" : "Literal Dictation remains available",
                        description: appModel.scribeProviderStatus
                    )

                    Spacer()
                    Text(appModel.scribeBinding.shortcut.symbolDisplayName)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(12)
                insetDivider
                ScribeProviderManagementView(appModel: appModel)
                    .padding(12)
                insetDivider
                WritingEnvironmentsView(appModel: appModel)
                    .id(Self.writingEnvironmentsScrollID)
                    .padding(12)
            }
        }
    }

    private var writingStyleSection: some View {
        settingsSection(title: "Writing Style", systemImage: "textformat") {
            FlowSectionCard {
                qualityControls
                insetDivider
                SettingsToggleRow(
                    title: "Clean up text for each app",
                    description: "Cadence adapts punctuation and spacing for chat, writing, code, and terminal apps.",
                    isOn: appAwarePolishingBinding
                )
                insetDivider
                vocabularyControls
                insetDivider
                fillerWordControls
            }
        }
    }

    private var personalizationSection: some View {
        settingsSection(title: "Personalization", systemImage: "person.crop.circle.badge.checkmark") {
            FlowSectionCard {
                personalizationHeader(
                    title: "Spoken shortcuts",
                    description: "Expand a short trigger into text you use often.",
                    buttonTitle: "Add shortcut"
                ) {
                    editingShortcut = PersonalShortcut(trigger: "", template: "")
                }

                if appModel.personalizationLibrary.shortcuts.isEmpty {
                    personalizationEmptyRow("No spoken shortcuts yet.")
                } else {
                    ForEach(appModel.personalizationLibrary.shortcuts) { shortcut in
                        insetDivider
                        PersonalizationItemRow(
                            title: shortcut.trigger,
                            detail: shortcut.template,
                            isEnabled: Binding(
                                get: { shortcut.isEnabled },
                                set: { appModel.setPersonalShortcutEnabled(id: shortcut.id, enabled: $0) }
                            ),
                            onEdit: { editingShortcut = shortcut },
                            onDelete: { appModel.deletePersonalShortcut(id: shortcut.id) }
                        )
                    }
                }

                insetDivider
                personalizationHeader(
                    title: "Writing profiles",
                    description: "Choose tone and formatting globally or for one app.",
                    buttonTitle: "Add profile"
                ) {
                    editingStyleProfile = WritingStyleProfile(name: "")
                }

                if appModel.personalizationLibrary.styleProfiles.isEmpty {
                    personalizationEmptyRow("No writing profiles yet.")
                } else {
                    ForEach(appModel.personalizationLibrary.styleProfiles) { profile in
                        insetDivider
                        PersonalizationItemRow(
                            title: profile.name,
                            detail: profile.appBundleIdentifier.map { "App: \($0)" } ?? "All apps",
                            isEnabled: Binding(
                                get: { profile.isEnabled },
                                set: { appModel.setWritingStyleProfileEnabled(id: profile.id, enabled: $0) }
                            ),
                            onEdit: { editingStyleProfile = profile },
                            onDelete: { appModel.deleteWritingStyleProfile(id: profile.id) }
                        )
                    }
                }
            }
        }
    }

    private func personalizationHeader(
        title: String,
        description: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsLabelRow(title: title, description: description)
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
    }

    private func personalizationEmptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(FlowTheme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }

    private var privacySection: some View {
        settingsSection(title: "Privacy", systemImage: "lock") {
            FlowSectionCard {
                privacyPromiseRow
                insetDivider
                privacyControls
            }
        }
    }

    private var captureReadinessRow: some View {
        HStack(spacing: 10) {
            Image(systemName: appModel.permissions.screenRecordingGranted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(appModel.permissions.screenRecordingGranted ? FlowTheme.success : FlowTheme.textTertiary)
                .frame(width: 20)

            SettingsLabelRow(
                title: "System audio",
                description: appModel.permissions.screenRecordingGranted
                    ? "Cadence can capture computer audio for calls and videos."
                    : "Allow Screen Recording to capture computer audio."
            )

            Spacer()

            Button("Screen Recording") {
                appModel.openPermissionsWizard()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
    }

    private var meetingNotesRow: some View {
        SettingsActionRow(
            title: "Meeting notes",
            description: "Record calls, keep transcripts, and generate summaries.",
            buttonTitle: "Open"
        ) {
            appModel.showMeetingNotesWindow()
        }
    }

    private var setupCheckRow: some View {
        SettingsActionRow(
            title: "Health check",
            description: "Refresh permissions and confirm the speech model is ready.",
            buttonTitle: "Run"
        ) {
            appModel.runSetupCheck()
        }
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsLabelRow(
                title: "Transcription speed and accuracy",
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
    }

    private var privacyPromiseRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(FlowTheme.success)
                .frame(width: 20)

            SettingsLabelRow(
                title: "Private by default",
                description: "Audio, transcripts, custom words, and calendar metadata stay on this Mac unless you choose to export or copy them."
            )
        }
        .padding(12)
    }

    private var advancedSection: some View {
        settingsSection(title: "Advanced", systemImage: "slider.horizontal.3") {
            FlowSectionCard {
                DisclosureGroup(isExpanded: advancedExpandedBinding) {
                    VStack(alignment: .leading, spacing: 0) {
                        insetDivider
                        advancedModelControls
                        insetDivider
                        advancedAudioControls
                    }
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Advanced settings")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FlowTheme.textPrimary)

                        Text("Model, audio cleanup, and tuning controls.")
                            .font(.system(size: 12))
                            .foregroundStyle(FlowTheme.textSecondary)
                    }
                }
                .padding(12)
                insetDivider
                SettingsActionRow(
                    title: appModel.onboardingProgress.wasSkipped && !appModel.onboardingProgress.isComplete
                        ? "Resume onboarding"
                        : "Replay onboarding",
                    description: appModel.onboardingProgress.wasSkipped && !appModel.onboardingProgress.isComplete
                        ? "Continue from the step where you left off."
                        : "Review Dictation, Scribe, privacy, and shortcuts without changing saved meetings or settings.",
                    buttonTitle: appModel.onboardingProgress.wasSkipped && !appModel.onboardingProgress.isComplete
                        ? "Resume"
                        : "Replay"
                ) {
                    if appModel.onboardingProgress.wasSkipped && !appModel.onboardingProgress.isComplete {
                        appModel.resumeOnboarding()
                    } else {
                        appModel.replayOnboarding()
                    }
                }
            }
        }
    }

    private var advancedModelControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsLabelRow(
                title: "Recognition model",
                description: "Change this only when testing speed, size, or accuracy."
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
                title: "Search depth",
                description: "Fast responds sooner; Accurate works harder on difficult audio."
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

    private var advancedAudioControls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Trim silence",
                description: "Remove quiet gaps before and after speech.",
                isOn: trimSilenceBinding
            )
            insetDivider
            SettingsToggleRow(
                title: "Normalize audio",
                description: "Keep quiet and loud recordings in a steadier range.",
                isOn: normalizeAudioBinding
            )
            insetDivider
            WaveformSensitivityRow(value: waveformSensitivityBinding)
            insetDivider
            SettingsToggleRow(
                title: "Keep context",
                description: "Use recent words to improve punctuation in longer dictation.",
                isOn: keepContextBinding
            )
            insetDivider
            SettingsToggleRow(
                title: "Stop on next key press",
                description: "Stop recording when you start typing.",
                isOn: tapStopsOnNextKeyPressBinding
            )
            insetDivider
            SettingsToggleRow(
                title: "Activation sound",
                description: "Play a short sound when dictation starts.",
                isOn: dictationSoundFeedbackBinding
            )
        }
    }

    private var vocabularyControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words Cadence should remember")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textPrimary)

            Text("Add names, companies, and phrases that should be spelled correctly.")
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

    private var calendarControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsLabelRow(
                title: "Calendar",
                description: calendarDescription
            )

            HStack(spacing: 8) {
                Image(systemName: appModel.googleCalendarConnectionState.isConnected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(appModel.googleCalendarConnectionState.isConnected ? FlowTheme.success : FlowTheme.textTertiary)

                Text(calendarStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(2)
            }

            if appModel.googleCalendarConnectionState.isConnected {
                Button {
                    appModel.disconnectGoogleCalendar()
                } label: {
                    Label("Sign out of Google", systemImage: "person.crop.circle.badge.minus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    appModel.connectGoogleCalendar()
                } label: {
                    Label(appModel.isConnectingGoogleCalendar ? "Opening Google" : "Continue with Google", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!appModel.isGoogleCalendarSignInAvailable || appModel.isConnectingGoogleCalendar)
            }
        }
        .padding(12)
    }

    private var privacyControls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Share analytics",
                description: "Share product health signals. Audio, transcripts, custom words, and shortcuts are never included.",
                isOn: analyticsEnabledBinding
            )

            insetDivider

            HStack {
                SettingsLabelRow(
                    title: "Privacy details",
                    description: "Read the full local-data and analytics policy."
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
                Text("Ways to start")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text("Choose the gesture that feels natural while you work.")
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
                title: "Press to dictate",
                description: "Hold the shortcut to dictate, or double-press it to lock recording on.",
                hint: "Release to insert in press-to-dictate mode.",
                isEnabled: holdEnabledBinding,
                shortcut: holdShortcutBinding,
                onRecordingChange: appModel.setShortcutRecordingActive
            )

            insetDivider

            ShortcutSettingRow(
                title: "Toggle recording",
                description: "Press once to start, then press again to stop.",
                hint: pressToStartHint,
                isEnabled: tapEnabledBinding,
                shortcut: tapShortcutBinding,
                onRecordingChange: appModel.setShortcutRecordingActive
            )

            insetDivider

            ShortcutSettingRow(
                title: "Open Scribe",
                description: "Choose whether to draft, respond, or edit selected text.",
                hint: "Separate from Dictation. \(appModel.scribeProviderStatus)",
                isEnabled: scribeEnabledBinding,
                shortcut: scribeShortcutBinding,
                onRecordingChange: appModel.setShortcutRecordingActive
            )

            insetDivider

            SettingsToggleRow(
                title: "Shortcut reminder",
                description: "Show a small reminder while Cadence is waiting for your voice.",
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
                Text("Dictation is ready")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(appModel.permissions.screenRecordingGranted ? "Dictation and call recording are ready." : "Dictation is ready. Turn on Screen Recording to capture computer audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Permissions") {
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
        return "Good for longer thoughts. Try \(fallback)"
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

    private var waveformSensitivityBinding: Binding<Double> {
        Binding(
            get: { appModel.waveformSensitivity },
            set: { appModel.setWaveformSensitivity($0) }
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

    private var scribeShortcutBinding: Binding<HotkeyConfiguration> {
        Binding(
            get: { appModel.scribeBinding.shortcut },
            set: { appModel.setShortcut($0, for: .scribe) }
        )
    }

    private var tapStopsOnNextKeyPressBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.tapStopsOnNextKeyPress },
            set: { appModel.setTapStopsOnNextKeyPress($0) }
        )
    }

    private var dictationSoundFeedbackBinding: Binding<Bool> {
        Binding(
            get: { appModel.dictationSoundFeedbackEnabled },
            set: { appModel.setDictationSoundFeedbackEnabled($0) }
        )
    }

    private var appAwarePolishingBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.appAwarePolishingEnabled },
            set: { appModel.setAppAwarePolishingEnabled($0) }
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

    private var calendarDescription: String {
        if appModel.googleCalendarConnectionState.isConnected {
            return appModel.googleCalendarConnectionState.accountEmail ?? "Calendar is connected."
        }
        if !appModel.isGoogleCalendarSignInAvailable {
            return "Calendar sign-in is not configured in this build."
        }
        return "Show today and tomorrow's meetings on Home."
    }

    private var calendarStatus: String {
        if let error = appModel.googleCalendarConnectionState.errorMessage, !error.isEmpty {
            return error
        }
        if appModel.googleCalendarConnectionState.isConnected {
            return "Connected"
        }
        if appModel.googleCalendarConnectionState.isConfigured {
            return "Ready"
        }
        return "Unavailable in this build"
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

    private var scribeEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.scribeBinding.isEnabled },
            set: { appModel.setScribeEnabled($0) }
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

private struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(FlowTheme.textSecondary)
                .frame(width: 14)

            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(FlowTheme.textSecondary)
        }
        .padding(.leading, 2)
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

private struct SettingsActionRow: View {
    let title: String
    let description: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsLabelRow(title: title, description: description)

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
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

private struct WaveformSensitivityRow: View {
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SettingsLabelRow(
                    title: "Waveform sensitivity",
                    description: "Controls how strongly mic input animates the HUD bars."
                )

                Spacer()

                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(FlowTheme.textSecondary)
            }

            HStack(spacing: 10) {
                Text("Calm")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textTertiary)

                Slider(value: $value, in: 0.1...1.6, step: 0.1)

                Text("Lively")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textTertiary)
            }
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
            if permissions.screenRecordingGranted {
                return "Microphone, Accessibility, Input Monitoring, and Screen Recording are enabled."
            }
            return "Microphone, Accessibility, and Input Monitoring are enabled. Screen Recording is optional for system audio meeting capture."
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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                ShortcutRecorderField(shortcut: $shortcut, onRecordingChange: onRecordingChange)
                    .frame(width: 154, height: 32)

                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(FlowToggleStyle())
            }
            .frame(width: 214, alignment: .trailing)
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
    private var activeModifierKeyCodes = Set<UInt16>()
    private var isRecording = false {
        didSet {
            recorderButton.contentTintColor = isRecording ? .systemOrange : normalTextColor
            updateButtonTitle()
            onRecordingChange?(isRecording)
            if !isRecording {
                pendingModifierOnlyShortcut = false
                bestModifierOnlyShortcut = nil
                activeModifierKeyCodes.removeAll()
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
        layer?.borderWidth = 1

        recorderButton.isBordered = false
        recorderButton.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        recorderButton.alignment = .left
        recorderButton.target = self
        recorderButton.action = #selector(beginRecording)
        addSubview(recorderButton)
        updateLayerColors()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 154, height: 32)
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var normalTextColor: NSColor {
        NSColor(hex: isDarkAppearance ? 0xEDEAE0 : 0x1B1B19)
    }

    private func updateLayerColors() {
        layer?.backgroundColor = NSColor(hex: isDarkAppearance ? 0x24241F : 0xF5F3EC).cgColor
        layer?.borderColor = NSColor(hex: isDarkAppearance ? 0x545048 : 0xD6D4CB).cgColor
        recorderButton.contentTintColor = isRecording ? .systemOrange : normalTextColor
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

        let modifierFlags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        let sidedModifierKeyCodes = HotkeyConfiguration.activeSidedModifierKeyCodes(
            from: activeModifierKeyCodes,
            modifiers: modifierFlags
        )
        let newShortcut = HotkeyConfiguration.from(
            keyCode: event.keyCode,
            modifiers: modifierFlags,
            characters: event.charactersIgnoringModifiers,
            sidedModifierKeyCodes: sidedModifierKeyCodes
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

        let modifierFlags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        activeModifierKeyCodes = HotkeyConfiguration.updatedActiveModifierKeyCodes(activeModifierKeyCodes, with: event)
        let sidedModifierKeyCodes = HotkeyConfiguration.activeSidedModifierKeyCodes(
            from: activeModifierKeyCodes,
            modifiers: modifierFlags
        )
        let preview = HotkeyConfiguration.symbolModifierDisplayName(
            for: sidedModifierKeyCodes,
            fallback: HotkeyConfiguration.carbonModifiers(for: modifierFlags)
        )
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
            let candidate = HotkeyConfiguration.modifierOnly(
                modifiers: modifierFlags,
                sidedModifierKeyCodes: sidedModifierKeyCodes
            )
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
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }
}

private struct PersonalizationItemRow: View {
    let title: String
    let detail: String
    @Binding var isEnabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var confirmsDeletion = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Enable \(title)")
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Menu {
                Button("Edit", action: onEdit)
                Divider()
                Button("Delete", role: .destructive) { confirmsDeletion = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Actions for \(title)")
        }
        .padding(12)
        .confirmationDialog("Delete \(title)?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from Cadence on this Mac.")
        }
    }
}

private struct PersonalShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PersonalShortcut
    @State private var isAppSpecific: Bool
    @State private var appBundleIdentifier: String
    private let isNew: Bool
    let onSave: (PersonalShortcut) -> Void

    init(shortcut: PersonalShortcut, onSave: @escaping (PersonalShortcut) -> Void) {
        _draft = State(initialValue: shortcut)
        if case let .application(bundleIdentifier) = shortcut.scope {
            _isAppSpecific = State(initialValue: true)
            _appBundleIdentifier = State(initialValue: bundleIdentifier)
        } else {
            _isAppSpecific = State(initialValue: false)
            _appBundleIdentifier = State(initialValue: "")
        }
        self.isNew = shortcut.trigger.isEmpty
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add spoken shortcut" : "Edit spoken shortcut")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Spoken trigger", text: $draft.trigger)
                TextField("Replacement text", text: $draft.template, axis: .vertical)
                    .lineLimit(3...8)
                Toggle("Only in one app", isOn: $isAppSpecific)
                if isAppSpecific {
                    TextField("App bundle identifier", text: $appBundleIdentifier)
                        .help("For example: com.apple.mail")
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save shortcut") {
                    draft.scope = isAppSpecific
                        ? .application(appBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
                        : .global
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid || (isAppSpecific && appBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

private struct WritingStyleProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WritingStyleProfile
    @State private var isAppSpecific: Bool
    @State private var appBundleIdentifier: String
    private let isNew: Bool
    let onSave: (WritingStyleProfile) -> Void

    init(profile: WritingStyleProfile, onSave: @escaping (WritingStyleProfile) -> Void) {
        _draft = State(initialValue: profile)
        _isAppSpecific = State(initialValue: profile.appBundleIdentifier != nil)
        _appBundleIdentifier = State(initialValue: profile.appBundleIdentifier ?? "")
        self.isNew = profile.name.isEmpty
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add writing profile" : "Edit writing profile")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Profile name", text: $draft.name)
                Picker("Tone", selection: $draft.tone) {
                    ForEach(WritingTone.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Length", selection: $draft.length) {
                    ForEach(WritingLength.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Punctuation", selection: $draft.punctuation) {
                    ForEach(WritingPunctuation.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Formatting", selection: $draft.formatting) {
                    ForEach(WritingFormatting.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Preserve code exactly", isOn: $draft.preservesCodeLiterals)
                Toggle("Only in one app", isOn: $isAppSpecific)
                if isAppSpecific {
                    TextField("App bundle identifier", text: $appBundleIdentifier)
                        .help("For example: com.apple.mail")
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save profile") {
                    draft.appBundleIdentifier = isAppSpecific
                        ? appBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (isAppSpecific && appBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
