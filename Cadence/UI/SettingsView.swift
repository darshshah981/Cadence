import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class InstalledApplicationPickerIconCache {
    static let shared = InstalledApplicationPickerIconCache()
    private let cache = NSCache<NSURL, NSImage>()

    private init() { cache.countLimit = 64 }

    func icon(for bundleURL: URL) -> NSImage {
        let key = bundleURL.standardizedFileURL as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        let workspaceIcon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        let icon = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
        icon.size = NSSize(width: 32, height: 32)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct SettingsView: View {
    private static let writingEnvironmentsScrollID = "settings-writing-environments"

    @ObservedObject var appModel: AppModel
    var maxContentWidth: CGFloat?
    var contentPadding = EdgeInsets()
    @State private var appSearchQuery = ""
    @State private var selectedApplication: InstalledApplicationDescriptor?
    @State private var applicationFamily: ScribeEnvironmentFamilyID = .general
    @State private var applicationPresetID = ""
    @State private var customGuidance = ""
    @State private var shortcutDraft: PersonalShortcut?
    @State private var editingStyleProfile: WritingStyleProfile?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            // Fixture windows pin an exact content width; prefer that over a
            // GeometryReader that can lag one layout pass behind the outer frame.
            let measuredWidth = fixtureLayoutWidth ?? proxy.size.width
            let compact = measuredWidth < CadenceDesignMetrics.compactActionBreakpoint
            Group {
                if compact {
                    VStack(alignment: .leading, spacing: 14) {
                        categorySelector
                        settingsContent
                    }
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        settingsRail
                        settingsContent
                    }
                }
            }
            .padding(contentPadding)
            .frame(maxWidth: maxContentWidth, alignment: .topLeading)
            .frame(width: fixtureLayoutWidth, alignment: .topLeading)
            .animation(FlowMotion.enabled(FlowMotion.control, reduceMotion: reduceMotion), value: appModel.dictationQualityPreset)
            .sheet(item: $editingStyleProfile) { profile in
                WritingStyleProfileEditor(profile: profile) { appModel.saveWritingStyleProfile($0) }
            }
            .sheet(
                isPresented: $appModel.isScribeProviderSetupPresented,
                onDismiss: appModel.dismissScribeProviderSetup
            ) {
                ScribeProviderSetupView(
                    onConnectDeepSeek: { try await appModel.connectDeepSeekForScribe(credential: $0) },
                    onConnectOpenAI: { try await appModel.connectOpenAIForScribe(model: $0, credential: $1) },
                    onConnectOpenRouter: { try await appModel.connectOpenRouterForScribe(model: $0, credential: $1) },
                    onAcceptDisclosure: { provider, advancedBaseURL in
                        try await appModel.acceptScribeProviderSetupDisclosure(
                            for: provider,
                            advancedBaseURL: advancedBaseURL
                        )
                    },
                    onDiscoverModels: { provider, credential, accepted, query in
                        await appModel.discoverScribeModels(for: provider, credential: credential, disclosureAccepted: accepted, matching: query)
                    },
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
            .onDisappear(perform: appModel.dismissScribeProviderSetup)
        }
    }

    /// When UI-test fixtures pin a content width, use it for the compact rail
    /// decision so 559/560 breakpoints are deterministic on CI runners.
    private var fixtureLayoutWidth: CGFloat? {
        #if DEBUG
        guard ScribeLaunchFixtures.current == .settings else { return nil }
        return ScribeLaunchFixtures.panelWidth
        #else
        return nil
        #endif
    }

    private var categorySelector: some View {
        CadenceDropdownRow(
            title: "Settings category",
            selection: Binding(get: { appModel.settingsPresentationState.selectedCategory }, set: selectCategory),
            accessibilityIdentifier: "settings-category-selector"
        ) {
            ForEach(visibleCategories, id: \.self) { category in
                Text(category.title).tag(category)
            }
        }
    }

    private var visibleCategories: [SettingsCategoryID] {
        SettingsCategoryID.visibleCategories(
            scribeEnabled: appModel.featureFlags.scribeEnabled
        )
    }

    private var settingsRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings").font(.title3.weight(.semibold)).padding(.bottom, 8)
            ForEach(visibleCategories, id: \.self) { category in
                Button {
                    selectCategory(category)
                } label: {
                    Label(category.title, systemImage: category.systemImage)
                        .font(.system(size: 12, weight: .medium))
                }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        appModel.settingsPresentationState.selectedCategory == category
                            ? FlowTheme.subtle
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .foregroundStyle(
                        appModel.settingsPresentationState.selectedCategory == category
                            ? FlowTheme.textPrimary
                            : FlowTheme.textSecondary
                    )
                    .accessibilityIdentifier("settings-category-\(category.rawValue)")
                    .accessibilityLabel(category.title)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 176, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-category-rail")
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(
                    title: appModel.settingsPresentationState.selectedCategory.title,
                    description: nil
                )
                switch appModel.settingsPresentationState.selectedCategory {
                case .general:
                    if !appModel.permissions.allRequiredGranted {
                        setupSection
                    }
                    generalPreferencesSection
                    personalizationSection
                case .dictation:
                    startStopSection
                    writingStyleSection
                    spokenPhraseSection
                    dictionarySection
                    fillerWordsSection
                case .scribe:
                    if appModel.featureFlags.scribeEnabled {
                        scribeSection
                    }
                case .meetings:
                    meetingsSection
                case .apps:
                    integrationsSection
                case .providers:
                    integrationsSection
                case .privacy:
                    privacySection
                    if appModel.featureFlags.scribeEnabled {
                        diagnosticsSection
                    }
                case .advanced:
                    advancedSection
                }
                versionFooter
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 2)
        }
        .accessibilityIdentifier("settings-category-content-\(appModel.settingsPresentationState.selectedCategory.rawValue)")
    }

    private var integrationsSection: some View {
        Group {
            settingsSection(title: "Calendar") {
                FlowSectionCard {
                    calendarControls
                }
            }

            if appModel.featureFlags.scribeEnabled {
                settingsSection(title: "Writing provider") {
                    FlowSectionCard {
                        ScribeProviderManagementView(appModel: appModel)
                            .padding(12)
                    }
                }
                appsSection
            }
        }
    }

    private var appsSection: some View {
        settingsSection(title: "App profiles") {
            FlowSectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsLabelRow(title: "Writing environments", description: "Choose an installed Mac app. Cadence stores its verified app identity, never a typed bundle identifier.")
                    HStack {
                        TextField("Search installed apps", text: $appSearchQuery)
                            .textFieldStyle(.plain)
                            .cadenceSettingsFieldChrome()
                            .accessibilityIdentifier("settings-app-search")
                        CadenceActionButton(title: "Refresh", role: .secondary, accessibilityIdentifier: "settings-app-refresh") { appModel.refreshInstalledApplications() }
                        CadenceActionButton(title: "Choose app…", role: .secondary, accessibilityIdentifier: "settings-app-choose") { chooseApplication() }
                    }
                    appPicker
                    if let selectedApplication {
                        HStack(spacing: 8) {
                            Text(selectedApplication.displayName)
                                .font(.headline)
                            if selectedApplicationConfiguration != nil {
                                Text("Configured")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(FlowTheme.success)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(FlowTheme.successSubtle, in: Capsule())
                                    .accessibilityIdentifier("settings-app-configured-badge")
                            }
                        }
                        CadenceDropdownRow(title: "Writing style", selection: $applicationFamily, accessibilityIdentifier: "settings-app-family") {
                            Text("General").tag(ScribeEnvironmentFamilyID.general)
                            Text("Messaging").tag(ScribeEnvironmentFamilyID.messaging)
                            Text("Coding").tag(ScribeEnvironmentFamilyID.coding)
                        }
                        CadenceDropdownRow(title: "Preset", detail: "Presets are limited to the selected writing style.", selection: $applicationPresetID, accessibilityIdentifier: "settings-app-preset") {
                            Text("Family default").tag("")
                            ForEach(presets(for: applicationFamily), id: \.id) { preset in
                                Text(preset.id.rawValue.replacingOccurrences(of: "\(applicationFamily.rawValue).", with: "").capitalized).tag(preset.id.rawValue)
                            }
                        }
                        CadenceTextEditorRow(title: "Custom Scribe guidance", detail: "Optional. Considered with the transcription after the selected style preset.", text: $customGuidance, accessibilityIdentifier: "settings-app-guidance")
                        CadenceSettingsPrimaryButton(
                            title: "\(selectedApplicationConfiguration == nil ? "Add" : "Update") \(selectedApplication.displayName)",
                            accessibilityIdentifier: "settings-app-add"
                        ) {
                            let app = selectedApplication
                            let guidance = try? ScribeCustomGuidance(customGuidance)
                            let selection: ScribePresetSelection = applicationPresetID.isEmpty ? .familyDefault : .explicit(try! ScribePresetID(applicationPresetID))
                            Task { try? await appModel.upsertApplicationConfiguration(for: app, familyID: applicationFamily, presetSelection: selection, customGuidance: guidance) }
                        }
                    }
                    configuredApps
                }
                .padding(12)
            }
        }
        .onAppear { appModel.refreshInstalledApplications() }
        .onChange(of: applicationFamily) { _, family in
            if !applicationPresetID.hasPrefix("\(family.rawValue).") { applicationPresetID = "" }
        }
    }

    private var appPicker: some View {
        let apps = InstalledApplicationPickerProjection.applications(
            from: appModel.installedApplications,
            query: appSearchQuery
        )
        return VStack(alignment: .leading, spacing: 8) {
            if apps.isEmpty {
                Text(appSearchQuery.isEmpty ? "No eligible apps found. Refresh or choose an app manually." : "No matching apps. Try another search or choose an app manually.")
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textSecondary)
            }
            ForEach(apps) { app in
                Button {
                    selectApplication(app)
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: InstalledApplicationPickerIconCache.shared.icon(for: app.bundleURL))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .padding(3)
                            .background(
                                Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(FlowTheme.border.opacity(0.8), lineWidth: 1)
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.displayName).font(.system(size: 13, weight: .medium))
                            if app.bundleIdentifier == "com.openai.codex" {
                                Text("Recommended for coding").font(.caption2).foregroundStyle(FlowTheme.textSecondary)
                            }
                        }
                        Spacer()
                        if selectedApplication?.id == app.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(FlowTheme.success)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .background(selectedApplication?.id == app.id ? FlowTheme.accentSubtle : FlowTheme.subtle.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-app-choice-\(settingsAppIdentifier(app))")
            }
        }
        .accessibilityIdentifier("settings-installed-app-picker")
    }

    private var selectedApplicationConfiguration: ApplicationConfiguration? {
        guard let selectedApplication else { return nil }
        guard case let .configured(configuration) = ApplicationSettingsConfigurationState.resolve(
            application: selectedApplication,
            configurations: appModel.applicationConfigurations
        ) else { return nil }
        return configuration
    }

    private func selectApplication(_ application: InstalledApplicationDescriptor) {
        selectedApplication = application
        if case let .configured(configuration) = ApplicationSettingsConfigurationState.resolve(
            application: application,
            configurations: appModel.applicationConfigurations
        ) {
            applicationFamily = configuration.familyID
            switch configuration.presetSelection {
            case .familyDefault: applicationPresetID = ""
            case let .explicit(id): applicationPresetID = id.rawValue
            }
            customGuidance = configuration.customGuidance?.rawValue ?? ""
        } else {
            applicationFamily = .general
            applicationPresetID = ""
            customGuidance = ""
        }
    }

    private var configuredApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !appModel.applicationConfigurations.isEmpty { Divider(); Text("Configured apps").font(.headline) }
            ForEach(appModel.applicationConfigurations) { configuration in
                HStack {
                    VStack(alignment: .leading) {
                        Text(configuration.application.lastKnownDisplayName)
                        Text(configuration.application.lastKnownBundleURL.path).font(.caption).foregroundStyle(FlowTheme.textTertiary).lineLimit(1)
                    }
                    Spacer()
                    CadenceToggle(title: "Enable \(configuration.application.lastKnownDisplayName)", isOn: Binding(get: { configuration.isEnabled }, set: { enabled in Task { try? await appModel.setApplicationConfigurationEnabled(configuration.id, enabled: enabled) } }))
                    .labelsHidden()
                }
            }
        }
    }

    private func presets(for family: ScribeEnvironmentFamilyID) -> [ScribeGuidancePresetDefinition] {
        ScribeGuidanceCatalog.releaseOne.family(family)?.presets ?? []
    }

    private func selectCategory(_ category: SettingsCategoryID) {
        appModel.dismissScribeProviderSetup()
        appModel.selectSettingsCategory(category)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.message = "Choose an installed Mac app to configure Scribe. Cadence reads its verified app identity."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let application = await appModel.chooseInstalledApplication(at: url) {
                selectApplication(application)
            }
        }
    }

    private func settingsAppIdentifier(_ app: InstalledApplicationDescriptor) -> String {
        app.bundleURL.standardizedFileURL.path.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(Character(scalar)).lowercased() : "-"
        }.joined()
    }

    private var diagnosticsSection: some View {
        settingsSection(title: "Local diagnostics") {
            FlowSectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsLabelRow(title: "Scribe diagnostics", description: "Content-free local setup and recovery outcomes. Never uploaded automatically.")
                    HStack { CadenceActionButton(title: "Clear", role: .destructive) { appModel.clearScribeDiagnostics() }; CadenceActionButton(title: "Export…", role: .secondary) { appModel.exportScribeDiagnostics() } }
                }.padding(12)
            }
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.textSecondary)
                .padding(.leading, 2)
            content()
        }
    }

    private var setupSection: some View {
        settingsSection(title: "Needs attention") {
            FlowSectionCard {
                PermissionWizardRow(
                    permissions: appModel.permissions,
                    action: appModel.openPermissionsWizard
                )
            }
        }
    }

    private var generalPreferencesSection: some View {
        Group {
            settingsSection(title: "Appearance") {
                FlowSectionCard {
                    HStack(alignment: .center, spacing: 16) {
                        Text("Theme")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(FlowTheme.textPrimary)

                        Spacer(minLength: 16)

                        AppearanceSlidingSelector(
                            selection: Binding(
                                get: { appModel.appearancePreference },
                                set: { appModel.setAppearancePreference($0) }
                            )
                        )
                        .frame(width: 248)
                        .accessibilityIdentifier("settings-appearance-menu")
                    }
                    .padding(12)
                }
            }

            settingsSection(title: "Feedback") {
                FlowSectionCard {
                    SettingsToggleRow(
                        title: "Start sound",
                        description: nil,
                        isOn: dictationActivationSoundBinding
                    )
                    .help("Play a short chime when Cadence begins listening.")
                    insetDivider
                    SettingsToggleRow(
                        title: "Completion sound",
                        description: nil,
                        isOn: dictationCompletionSoundBinding
                    )
                    .help("Play a short chime after text is inserted or copied.")
                    insetDivider
                    SettingsToggleRow(
                        title: "Shortcut hint",
                        description: nil,
                        isOn: showsShortcutDockBinding
                    )
                    .help("Show a small on-screen reminder for how to stop or release dictation.")
                }
            }
        }
    }

    private var startStopSection: some View {
        settingsSection(title: "Start & Stop") {
            FlowSectionCard {
                shortcutsSection
            }
        }
    }

    private var meetingsSection: some View {
        Group {
            settingsSection(title: "Recording") {
                FlowSectionCard {
                    HStack(spacing: 16) {
                        Text("Capture source")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FlowTheme.textPrimary)

                        Spacer(minLength: 16)

                        FlowSegmentedControl(
                            options: MeetingCaptureSource.allCases,
                            selection: meetingCaptureSourceBinding,
                            title: \.displayName
                        )
                        .frame(width: 330)
                        .accessibilityIdentifier("settings-meeting-capture-source")
                    }
                    .padding(12)
                    insetDivider
                    captureReadinessRow
                }
            }

            settingsSection(title: "Notes") {
                FlowSectionCard {
                    meetingNotesRow
                }
            }

            settingsSection(title: "Calendar context") {
                FlowSectionCard {
                    calendarConnectionSummaryRow
                }
            }
        }
    }

    private var scribeSection: some View {
        settingsSection(title: "Scribe") {
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
        settingsSection(title: "Writing Style") {
            FlowSectionCard {
                qualityControls
                insetDivider
                SettingsToggleRow(
                    title: "Clean up text for each app",
                    description: nil,
                    isOn: appAwarePolishingBinding
                )
                .help("Adapt punctuation and spacing for chat, writing, code, and terminal apps.")
            }
        }
    }

    private var spokenPhraseSection: some View {
        settingsSection(title: "Spoken phrase") {
            FlowSectionCard {
                SettingsToggleRow(
                    title: "Press Return with a spoken phrase",
                    description: nil,
                    isOn: pressEnterCommandBinding
                )
                .help("End a dictation with this phrase to press Return without typing the phrase.")
                if appModel.transcriptionConfiguration.pressEnterCommandEnabled {
                    insetDivider
                    HStack(alignment: .center, spacing: 12) {
                        Text("Trigger phrase")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FlowTheme.textPrimary)

                        Spacer(minLength: 16)

                        TextField(
                            DictationCommandPhrase.defaultValue,
                            text: pressEnterCommandPhraseBinding
                        )
                        .textFieldStyle(.plain)
                        .cadenceSettingsFieldChrome()
                        .frame(width: 180)
                        .accessibilityLabel("Return command trigger phrase")
                        .accessibilityIdentifier("press-enter-command-phrase")
                        .help("Use a short phrase that you are unlikely to dictate by accident.")
                    }
                    .padding(12)
                }
            }
        }
    }

    private var dictionarySection: some View {
        settingsSection(title: "Dictionary") {
            FlowSectionCard {
                vocabularyControls
            }
        }
    }

    private var fillerWordsSection: some View {
        settingsSection(title: "Filler words") {
            FlowSectionCard {
                fillerWordControls
            }
        }
    }

    private var personalizationSection: some View {
        settingsSection(title: "Personalization") {
            FlowSectionCard {
                HStack(spacing: 12) {
                    Text("Spoken shortcuts")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FlowTheme.textPrimary)
                    Spacer()
                    CadenceToggle(
                        title: "Enable spoken shortcuts",
                        isOn: spokenShortcutsEnabledBinding
                    )
                    .labelsHidden()
                    .controlSize(.small)
                }
                .padding(12)

                if appModel.personalizationLibrary.shortcuts.isEmpty {
                    personalizationEmptyRow("No spoken shortcuts yet.")
                } else {
                    ForEach(appModel.personalizationLibrary.shortcuts) { shortcut in
                        insetDivider
                        PersonalShortcutRow(
                            title: shortcut.trigger,
                            detail: shortcut.template,
                            isEditing: shortcutDraft?.id == shortcut.id,
                            onEdit: { shortcutDraft = shortcut },
                            onDelete: {
                                if shortcutDraft?.id == shortcut.id {
                                    shortcutDraft = nil
                                }
                                appModel.deletePersonalShortcut(id: shortcut.id)
                            }
                        )
                        if shortcutDraft?.id == shortcut.id, let shortcutDraft {
                            InlinePersonalShortcutEditor(
                                shortcut: shortcutDraft,
                                onCancel: { self.shortcutDraft = nil },
                                onSave: {
                                    appModel.savePersonalShortcut($0)
                                    self.shortcutDraft = nil
                                }
                            )
                            .id(shortcutDraft.id)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                insetDivider
                Button {
                    shortcutDraft = PersonalShortcut(trigger: "", template: "")
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                        Text("Add shortcut")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(FlowTheme.textPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityIdentifier("settings-add-spoken-shortcut")

                if let shortcutDraft, shortcutDraft.trigger.isEmpty {
                    InlinePersonalShortcutEditor(
                        shortcut: shortcutDraft,
                        onCancel: { self.shortcutDraft = nil },
                        onSave: {
                            appModel.savePersonalShortcut($0)
                            self.shortcutDraft = nil
                        }
                    )
                    .id(shortcutDraft.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if appModel.featureFlags.scribeEnabled {
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
                .buttonStyle(CadenceActionButtonStyle(role: .secondary))
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
        settingsSection(title: "Privacy") {
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
                    ? nil
                    : "Permission required"
            )

            Spacer()

            Button("Screen Recording") {
                appModel.openPermissionsWizard()
            }
            .buttonStyle(CadenceActionButtonStyle(role: .secondary))
            .controlSize(.small)
        }
        .padding(12)
    }

    private var meetingNotesRow: some View {
        SettingsActionRow(
            title: "Meeting notes",
            description: nil,
            buttonTitle: "Open"
        ) {
            appModel.showMeetingNotesWindow()
        }
        .help("Open meeting notes, transcripts, and summaries.")
    }

    private var qualityControls: some View {
        HStack(spacing: 16) {
            Text("Quality")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textPrimary)

            Spacer(minLength: 16)

            FlowSegmentedControl(
                options: DictationQualityPreset.allCases,
                selection: Binding(
                    get: { appModel.dictationQualityPreset },
                    set: { appModel.setDictationQualityPreset($0) }
                ),
                title: \.displayName,
                selectedStatus: qualityStatus
            )
            .frame(width: 330)
            .accessibilityIdentifier("settings-quality-selector")
        }
        .padding(12)
    }

    private var qualityStatus: FlowSegmentedStatus? {
        let summary = appModel.modelReadinessSummary
        switch summary.tone {
        case .ready:
            return nil
        case .working:
            return .working(help: "\(summary.title). \(summary.detail)")
        case .attention:
            return .attention(help: "\(summary.title). \(summary.detail)")
        }
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
        settingsSection(title: "Advanced") {
            FlowSectionCard {
                DisclosureGroup(isExpanded: advancedExpandedBinding) {
                    VStack(alignment: .leading, spacing: 0) {
                        insetDivider
                        advancedModelControls
                        insetDivider
                        advancedAudioControls
                        #if DEBUG
                        insetDivider
                        hudMotionLab
                        #endif
                    }
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } label: {
                    Text("Advanced settings")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FlowTheme.textPrimary)
                }
                .disclosureGroupStyle(CadenceDisclosureGroupStyle(
                    accessibilityIdentifier: "settings-advanced-disclosure"
                ))
                .padding(12)
                insetDivider
                SettingsActionRow(
                    title: appModel.onboardingProgress.wasSkipped && !appModel.onboardingProgress.isComplete
                        ? "Resume onboarding"
                        : "Replay onboarding",
                    description: nil,
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
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Recognition model")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Spacer(minLength: 16)

                CadenceDiscretePicker(
                    title: "Recognition model",
                    selection: Binding(
                        get: { appModel.transcriptionConfiguration.model },
                        set: { appModel.setWhisperModel($0) }
                    )
                ) {
                    ForEach(WhisperModelOption.allCases) { model in
                        Text("\(model.displayName.replacingOccurrences(of: " English", with: "")) · \(model.approximateSize)")
                            .tag(model)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("settings-recognition-model-menu")
            }
            .padding(12)
            .help("Choose the local transcription model.")

            insetDivider

            HStack(spacing: 16) {
                Text("Search depth")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Spacer(minLength: 16)

                FlowSegmentedControl(
                    options: WhisperDecodingMode.allCases,
                    selection: Binding(
                    get: { appModel.transcriptionConfiguration.decodingMode },
                    set: { appModel.setDecodingMode($0) }
                    ),
                    title: \.productLabel
                )
                .frame(width: 220)
                .accessibilityIdentifier("settings-search-depth-selector")
            }
            .padding(12)
            .help("Fast responds sooner; Accurate works harder on difficult audio.")
        }
    }

    private var fillerWordControls: some View {
        HStack(spacing: 16) {
            Text("Treatment")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textPrimary)

            Spacer(minLength: 16)

            FlowSegmentedControl(
                options: FillerWordPolicy.allCases,
                selection: fillerWordPolicyBinding,
                title: \.displayName
            )
            .frame(width: 220)
            .accessibilityIdentifier("settings-filler-words-selector")
        }
        .padding(12)
        .help(appModel.transcriptionConfiguration.fillerWordPolicy.description)
    }

    private var advancedAudioControls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Trim silence",
                description: nil,
                isOn: trimSilenceBinding
            )
            .help("Remove quiet gaps before and after speech.")
            insetDivider
            SettingsToggleRow(
                title: "Normalize audio",
                description: nil,
                isOn: normalizeAudioBinding
            )
            .help("Keep quiet and loud recordings in a steadier range.")
            insetDivider
            WaveformSensitivityRow(value: waveformSensitivityBinding)
            insetDivider
            SettingsToggleRow(
                title: "Keep context",
                description: nil,
                isOn: keepContextBinding
            )
            .help("Use recent words to improve punctuation in longer dictation.")
            insetDivider
            SettingsToggleRow(
                title: "Stop on next key press",
                description: nil,
                isOn: tapStopsOnNextKeyPressBinding
            )
            .help("Stop recording when you start typing.")
            insetDivider
            SettingsToggleRow(
                title: "Activation sound",
                description: nil,
                isOn: dictationActivationSoundBinding
            )
            .help("Play a short sound when dictation starts.")
        }
    }

    #if DEBUG
    private var hudMotionLab: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsLabelRow(
                title: "HUD motion lab",
                description: nil
            )
            .help("Tune the floating pill in real time. Values stay in this local Debug app.")

            HUDMotionSlider(
                title: "Pill response",
                value: hudMotionBinding(\.pillResponse),
                range: 0.18...0.60
            )
            HUDMotionSlider(
                title: "Mic fade out",
                value: hudMotionBinding(\.micFadeOutDuration),
                range: 0.04...0.30
            )
            HUDMotionSlider(
                title: "App icon fade in",
                value: hudMotionBinding(\.appCueFadeInDuration),
                range: 0.04...0.40
            )
            HUDMotionSlider(
                title: "Waveform fade in",
                value: hudMotionBinding(\.waveformFadeInDuration),
                range: 0.06...0.50
            )

            HStack(spacing: 8) {
                Button("Replay transition") {
                    appModel.previewHUDMotionTransition()
                }
                .buttonStyle(CadenceActionButtonStyle(role: .primary))
                .controlSize(.small)

                Button("Reset") {
                    appModel.resetHUDMotionTuning()
                }
                .buttonStyle(CadenceActionButtonStyle(role: .secondary))
                .controlSize(.small)
            }
        }
        .padding(12)
    }

    private func hudMotionBinding(
        _ keyPath: WritableKeyPath<HUDMotionTuning, TimeInterval>
    ) -> Binding<Double> {
        Binding(
            get: { appModel.hudMotionTuning[keyPath: keyPath] },
            set: { value in
                var tuning = appModel.hudMotionTuning
                tuning[keyPath: keyPath] = value
                appModel.setHUDMotionTuning(tuning)
            }
        )
    }
    #endif

    private var vocabularyControls: some View {
        CadenceTextEditorRow(
            title: "Custom words",
            detail: nil,
            text: vocabularyBinding,
            accessibilityIdentifier: "settings-vocabulary-editor"
        )
        .padding(12)
        .help("Add names, companies, and phrases that Cadence should spell correctly.")
    }

    private var calendarControls: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("GoogleG")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            SettingsLabelRow(
                title: "Google Calendar",
                description: calendarDescription
            )

            Spacer(minLength: 12)

            if appModel.googleCalendarConnectionState.isConnected {
                VStack(alignment: .trailing, spacing: 8) {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FlowTheme.success)
                        .accessibilityIdentifier("settings-google-calendar-status")

                    CadenceActionButton(
                        title: "Sign Out",
                        role: .secondary,
                        accessibilityIdentifier: "settings-google-sign-out-button"
                    ) {
                        appModel.disconnectGoogleCalendar()
                    }
                    .accessibilityLabel("Sign out of Google Calendar")
                    .help("Disconnect Google Calendar")
                }
            } else {
                GoogleSignInButton(
                    isConnecting: appModel.isConnectingGoogleCalendar,
                    isEnabled: appModel.isGoogleCalendarSignInAvailable,
                    accessibilityIdentifier: "settings-google-sign-in-button",
                    action: appModel.connectGoogleCalendar
                )
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-google-calendar-account")
    }

    private var calendarConnectionSummaryRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: appModel.googleCalendarConnectionState.isConnected
                ? "checkmark.circle.fill"
                : "calendar.badge.exclamationmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(appModel.googleCalendarConnectionState.isConnected
                    ? FlowTheme.success
                    : FlowTheme.textTertiary)
                .frame(width: 20)

            SettingsLabelRow(
                title: appModel.googleCalendarConnectionState.isConnected
                    ? "Google Calendar connected"
                    : "Calendar not connected",
                description: calendarDescription
            )

            Spacer()

            Button("Manage") {
                selectCategory(.apps)
            }
            .buttonStyle(CadenceActionButtonStyle(role: .secondary))
            .controlSize(.small)
        }
        .padding(12)
    }

    private var privacyControls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Share analytics",
                description: nil,
                isOn: analyticsEnabledBinding
            )
            .help("Share product health signals. Audio, transcripts, custom words, and shortcuts are never included.")

            insetDivider

            HStack {
                SettingsLabelRow(
                    title: "Privacy details",
                    description: nil
                )

                Spacer()

                Button("Open") {
                    if let url = URL(string: "https://github.com/darshshah981/Cadence/blob/main/docs/privacy.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(CadenceActionButtonStyle(role: .secondary))
                .controlSize(.small)
            }
            .padding(12)
            .help("Read the full local-data and analytics policy.")
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
            if let message = appModel.shortcutValidationMessage ?? appModel.hotkeyConflictMessage {
                ShortcutWarningView(message: message)
                    .padding(12)
                insetDivider
            }

            ShortcutSettingRow(
                title: "Press to dictate",
                description: "Hold, or double-press to lock.",
                hint: nil,
                isEnabled: holdEnabledBinding,
                shortcut: holdShortcutBinding,
                onRecordingChange: appModel.setShortcutRecordingActive
            )

            insetDivider

            ShortcutSettingRow(
                title: "Toggle recording",
                description: nil,
                hint: nil,
                isEnabled: tapEnabledBinding,
                shortcut: tapShortcutBinding,
                onRecordingChange: appModel.setShortcutRecordingActive
            )
            .help("Press once to start and again to stop.")

            if appModel.featureFlags.scribeEnabled {
                insetDivider

                ShortcutSettingRow(
                    title: "Open Scribe",
                    description: nil,
                    hint: nil,
                    isEnabled: scribeEnabledBinding,
                    shortcut: scribeShortcutBinding,
                    onRecordingChange: appModel.setShortcutRecordingActive
                )
                .help("Dictate a request, then review the polished result before inserting it.")
            }
        }
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

    private var meetingCaptureSourceBinding: Binding<MeetingCaptureSource> {
        Binding(
            get: { appModel.meetingCaptureSource },
            set: { appModel.setMeetingCaptureSource($0) }
        )
    }

    private var dictationActivationSoundBinding: Binding<Bool> {
        Binding(
            get: { appModel.dictationActivationSoundEnabled },
            set: { appModel.setDictationActivationSoundEnabled($0) }
        )
    }

    private var dictationCompletionSoundBinding: Binding<Bool> {
        Binding(
            get: { appModel.dictationCompletionSoundEnabled },
            set: { appModel.setDictationCompletionSoundEnabled($0) }
        )
    }

    private var spokenShortcutsEnabledBinding: Binding<Bool> {
        Binding(
            get: { appModel.spokenShortcutsEnabled },
            set: { appModel.setSpokenShortcutsEnabled($0) }
        )
    }

    private var appAwarePolishingBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.appAwarePolishingEnabled },
            set: { appModel.setAppAwarePolishingEnabled($0) }
        )
    }

    private var pressEnterCommandBinding: Binding<Bool> {
        Binding(
            get: { appModel.transcriptionConfiguration.pressEnterCommandEnabled },
            set: { appModel.setPressEnterCommandEnabled($0) }
        )
    }

    private var pressEnterCommandPhraseBinding: Binding<String> {
        Binding(
            get: { appModel.transcriptionConfiguration.pressEnterCommandPhrase },
            set: { appModel.setPressEnterCommandPhrase($0) }
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

    private var calendarDescription: String? {
        if let error = appModel.googleCalendarConnectionState.errorMessage, !error.isEmpty {
            return error
        }
        if appModel.googleCalendarConnectionState.isConnected {
            return appModel.googleCalendarConnectionState.accountEmail ?? "Calendar is connected."
        }
        if !appModel.isGoogleCalendarSignInAvailable {
            return "Calendar sign-in is not configured in this build."
        }
        return nil
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
            get: { appModel.settingsPresentationState.isAdvancedExpanded },
            set: { newValue in
                withAnimation(FlowMotion.enabled(FlowMotion.section, reduceMotion: reduceMotion)) {
                    appModel.setAdvancedSettingsExpanded(newValue)
                }
            }
        )
    }
}

private extension SettingsCategoryID {
    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .scribe: "Scribe"
        case .meetings: "Meetings"
        case .apps, .providers: "Apps & Integrations"
        case .privacy: "Privacy"
        case .advanced: "Advanced"
        }
    }

    var description: String {
        switch self {
        case .general:
            "Core behavior and the preferences you change most often."
        case .dictation:
            "Control how recording starts and how Cadence writes."
        case .scribe:
            "Configure reviewable, app-aware drafts when Scribe is enabled."
        case .meetings:
            "Choose what Cadence captures and how meeting notes are created."
        case .apps, .providers:
            "Manage connected accounts and app-specific writing behavior."
        case .privacy:
            "See what Cadence can access and where your data lives."
        case .advanced:
            "Technical controls most people should not need to change."
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        case .scribe: "sparkles"
        case .meetings: "person.2.wave.2"
        case .apps, .providers: "square.grid.2x2"
        case .privacy: "lock"
        case .advanced: "slider.horizontal.3"
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)

            if let description {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
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
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlowTheme.textPrimary)

            if let description {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsActionRow: View {
    let title: String
    let description: String?
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsLabelRow(title: title, description: description)

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(CadenceActionButtonStyle(role: .secondary))
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

private struct AppearanceSlidingSelector: View {
    @Binding var selection: AppearancePreference

    var body: some View {
        FlowSegmentedControl(
            options: AppearancePreference.allCases,
            selection: $selection,
            title: \.displayName
        )
        .accessibilityLabel("Theme")
    }
}

private enum FlowSegmentedStatus {
    case working(help: String)
    case attention(help: String)
}

private struct FlowSegmentedControl<Option: Identifiable & Equatable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var selectedStatus: FlowSegmentedStatus? = nil

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
            HStack(spacing: 6) {
                Text(title(option))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? FlowTheme.textPrimary : FlowTheme.textSecondary)

                if isSelected, let selectedStatus {
                    statusView(selectedStatus)
                }
            }
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

    @ViewBuilder
    private func statusView(_ status: FlowSegmentedStatus) -> some View {
        switch status {
        case .working(let help):
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
                .help(help)
                .accessibilityLabel(help)
        case .attention(let help):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FlowTheme.error)
                .help(help)
                .accessibilityLabel(help)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let description: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: description == nil ? .center : .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)
                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            CadenceToggle(title: title, isOn: $isOn)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(12)
    }
}

private struct WaveformSensitivityRow: View {
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Waveform sensitivity")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Spacer()

                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(FlowTheme.textSecondary)
                    .accessibilityLabel("Waveform sensitivity value")
                    .accessibilityValue("\(Int((value * 100).rounded()))%")
                    .accessibilityIdentifier("settings-waveform-sensitivity-value")
            }

            CadenceSensitivitySlider(
                title: "Waveform sensitivity",
                value: $value,
                range: 0.1...1.6,
                step: 0.1,
                minimumLabel: "Calm",
                maximumLabel: "Lively",
                accessibilityIdentifier: "settings-waveform-sensitivity-slider",
                showsTitle: false
            )
        }
        .padding(12)
        .help("Control how strongly microphone input animates the HUD bars.")
    }
}

#if DEBUG
private struct HUDMotionSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)
                Spacer()
                Text("\(Int((value * 1_000).rounded())) ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlowTheme.textSecondary)
            }
            Slider(value: $value, in: range, step: 0.01)
                .controlSize(.small)
        }
    }
}
#endif

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

private struct ShortcutSettingRow: View {
    let title: String
    let description: String?
    let hint: String?
    @Binding var isEnabled: Bool
    @Binding var shortcut: HotkeyConfiguration
    let onRecordingChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                ShortcutRecorderField(shortcut: $shortcut, onRecordingChange: onRecordingChange)
                    .frame(width: 154, height: 28)

                CadenceToggle(title: "Enable \(title)", isOn: $isEnabled)
                    .labelsHidden()
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
        layer?.cornerRadius = 7
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
        recorderButton.frame = bounds.insetBy(dx: 10, dy: 6)
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
        NSSize(width: 154, height: 28)
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

private struct PersonalShortcutRow: View {
    let title: String
    let detail: String
    let isEditing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var confirmsDeletion = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEditing ? FlowTheme.accent : FlowTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        isEditing ? FlowTheme.accentSubtle : Color.clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help("Edit \(title)")
            .accessibilityLabel("Edit \(title)")

            Button {
                confirmsDeletion = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Delete \(title)")
            .accessibilityLabel("Delete \(title)")
        }
        .padding(12)
        .confirmationDialog("Delete \(title)?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the shortcut from Cadence on this Mac.")
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
            CadenceToggle(title: "Enable \(title)", isOn: $isEnabled)
                .labelsHidden()
                .controlSize(.small)
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

private struct InlinePersonalShortcutEditor: View {
    @State private var draft: PersonalShortcut
    private let isNew: Bool
    let onCancel: () -> Void
    let onSave: (PersonalShortcut) -> Void

    init(
        shortcut: PersonalShortcut,
        onCancel: @escaping () -> Void,
        onSave: @escaping (PersonalShortcut) -> Void
    ) {
        _draft = State(initialValue: shortcut)
        self.isNew = shortcut.trigger.isEmpty
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add shortcut" : "Edit shortcut")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)

            ShortcutEditorField(
                label: "When I say",
                placeholder: "For example, support reply",
                text: $draft.trigger
            )

            ShortcutEditorField(
                label: "Cadence inserts",
                placeholder: "Type the replacement text",
                text: $draft.template
            )

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(CadenceActionButtonStyle(role: .quiet))
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    draft.scope = .global
                    onSave(draft)
                }
                .buttonStyle(CadenceActionButtonStyle(role: .primary))
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .padding(12)
        .background(
            FlowTheme.subtle.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

private struct ShortcutEditorField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FlowTheme.textSecondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .cadenceSettingsFieldChrome()
        }
    }
}

private struct WritingStyleProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WritingStyleProfile
    private let isNew: Bool
    let onSave: (WritingStyleProfile) -> Void

    init(profile: WritingStyleProfile, onSave: @escaping (WritingStyleProfile) -> Void) {
        _draft = State(initialValue: profile)
        self.isNew = profile.name.isEmpty
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add writing profile" : "Edit writing profile")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Profile name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .cadenceSettingsFieldChrome()
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
                CadenceToggle(title: "Preserve code exactly", isOn: $draft.preservesCodeLiterals)
            }
            .controlSize(.small)
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(CadenceActionButtonStyle(role: .quiet))
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save profile") {
                    draft.appBundleIdentifier = nil
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(CadenceActionButtonStyle(role: .primary))
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
