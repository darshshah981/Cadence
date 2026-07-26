import AppKit
import OSLog
import SwiftUI

private let mainWindowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "MainWindow"
)

@MainActor
final class MainWindowController: NSWindowController {
    private var hostingController: NSHostingController<MainWindowView>?

    var hasVisibleWindow: Bool {
        window?.isVisible == true
    }

    convenience init() {
        #if DEBUG
        let fixtureContentWidth = ScribeLaunchFixtures.current == .settings
            ? (ScribeLaunchFixtures.panelWidth ?? 720)
            : nil
        let fixtureWindowWidth = fixtureContentWidth.map { $0 + 221 }
        #endif
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: {
                    #if DEBUG
                    fixtureWindowWidth ?? 1228
                    #else
                    1228
                    #endif
                }(),
                height: 768
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cadence"
        window.isReleasedWhenClosed = false
        #if DEBUG
        window.minSize = NSSize(width: fixtureWindowWidth ?? 980, height: 640)
        #else
        window.minSize = NSSize(width: 980, height: 640)
        #endif
        window.titlebarAppearsTransparent = true
        self.init(window: window)
    }

    func show(appModel: AppModel) {
        if hostingController == nil {
            let view = MainWindowView(appModel: appModel)
            let hostingController = NSHostingController(rootView: view)
            self.hostingController = hostingController
            window?.contentViewController = hostingController
            window?.center()
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        mainWindowLogger.info("Main window visible=\(self.window?.isVisible ?? false, privacy: .public) key=\(self.window?.isKeyWindow ?? false, privacy: .public) appWindows=\(NSApp.windows.count, privacy: .public) token=\(Self.verificationToken, privacy: .public)")
    }

    private static var verificationToken: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--cadence-verify-token"),
              arguments.indices.contains(arguments.index(after: index)) else {
            return "none"
        }
        return arguments[arguments.index(after: index)]
    }
}

private enum MainWindowDestination: Hashable {
    case dashboard
    case meetings
    case ask
    case speechToText
    case meetingNote(UUID)
    case settings
}

private enum MainSidebarItem: Hashable {
    case home
    case allNotes
    case ask
    case speechToText
    case settings
}

private enum StenoLayout {
    static let toolbarHeight: CGFloat = 48
    static let contentMaxWidth: CGFloat = 720
    static let contentTopPadding: CGFloat = 56
    static let contentHorizontalPadding: CGFloat = 52
    static let contentBottomPadding: CGFloat = 56
    static let settingsTopPadding: CGFloat = 16
}

private func accessibilityIdentifierSuffix(_ rawValue: String) -> String {
    let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let characters = rawValue.unicodeScalars.map { scalar -> Character in
        allowedCharacters.contains(scalar) ? Character(scalar) : "-"
    }
    let suffix = String(characters).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return suffix.isEmpty ? "unknown" : suffix
}

struct MainWindowView: View {
    @ObservedObject var appModel: AppModel
    @State private var selection: MainWindowDestination = .dashboard
    @State private var activeSidebarItem: MainSidebarItem = .home

    var body: some View {
        HStack(spacing: 0) {
            StenoSidebar(
                appModel: appModel,
                selection: $selection,
                activeItem: $activeSidebarItem,
                onNewNote: createAndOpenNote
            )
            .frame(width: 220)

            Rectangle()
                .fill(FlowTheme.border.opacity(0.45))
                .frame(width: 1)

            ZStack(alignment: .topTrailing) {
                detail
                    .clipped()

                if showsTopToolbar {
                    StenoTopToolbar(
                        appModel: appModel,
                        showsNewNote: appModel.featureFlags.granolaEnabled
                            && selection != .speechToText,
                        onNewNote: createAndOpenNote
                    )
                    .padding(.top, 10)
                    .padding(.trailing, 22)
                    .frame(height: StenoLayout.toolbarHeight, alignment: .topTrailing)
                    .background(FlowTheme.background.opacity(0.98))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(FlowTheme.background)
        .preferredColorScheme(appModel.appearancePreference.colorScheme)
        .task {
            await appModel.refreshPermissions()
        }
        .sheet(
            isPresented: Binding(
                get: { appModel.isOnboardingPresented },
                set: { if !$0 { appModel.skipOnboarding() } }
            )
        ) {
            OnboardingView(appModel: appModel)
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
                    await appModel.discoverScribeModels(
                        for: provider,
                        credential: credential,
                        disclosureAccepted: accepted,
                        matching: query
                    )
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
    }

    private var showsTopToolbar: Bool {
        switch selection {
        case .meetingNote, .settings:
            return false
        case .dashboard, .meetings, .ask, .speechToText:
            return true
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .dashboard:
            StenoHomeContent(appModel: appModel) {
                selection = .meetings
                activeSidebarItem = .allNotes
            } onOpenNote: { note in
                appModel.selectMeetingNote(id: note.id)
                selection = .meetingNote(note.id)
                activeSidebarItem = .allNotes
            } onOpenSettings: {
                openSettings()
            } onJoinCalendarEvent: { event in
                appModel.joinCalendarEvent(event)
            }
        case .meetings:
            StenoAllNotesContent(appModel: appModel) { note in
                appModel.selectMeetingNote(id: note.id)
                selection = .meetingNote(note.id)
                activeSidebarItem = .allNotes
            }
        case .ask:
            StenoGlobalAskContent(appModel: appModel) { note in
                appModel.selectMeetingNote(id: note.id)
                selection = .meetingNote(note.id)
                activeSidebarItem = .allNotes
            }
        case .speechToText:
            StenoSpeechHistoryContent(appModel: appModel)
        case .meetingNote(let noteID):
            MeetingNoteSelectionDetail(appModel: appModel, noteID: noteID) {
                selection = .meetings
                activeSidebarItem = .allNotes
            }
        case .settings:
            SettingsView(
                appModel: appModel,
                maxContentWidth: .infinity,
                contentPadding: EdgeInsets(
                    top: StenoLayout.settingsTopPadding,
                    leading: 24,
                    bottom: 24,
                    trailing: 24
                )
            )
            #if DEBUG
            // Fixture windows include the main sidebar and its divider. Pin the
            // settings detail itself so GeometryReader receives the requested
            // 520/559/560/720 content width without a one-point split-view loss.
            .frame(width: ScribeLaunchFixtures.current == .settings ? ScribeLaunchFixtures.panelWidth : nil)
            #endif
            .background(FlowTheme.background)
        }
    }

    private func createAndOpenNote() {
        guard let note = appModel.createMeetingNote(openWindow: false) else { return }
        selection = .meetingNote(note.id)
        activeSidebarItem = .allNotes
    }

    private func openSettings() {
        selection = .settings
        activeSidebarItem = .settings
    }
}

private struct StenoSidebar: View {
    @ObservedObject var appModel: AppModel
    @Binding var selection: MainWindowDestination
    @Binding var activeItem: MainSidebarItem
    let onNewNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Cadence")
                .font(.system(size: 18, weight: .regular, design: .serif))
                .foregroundStyle(FlowTheme.brandText)
            .padding(.top, 18)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            Rectangle()
                .fill(FlowTheme.border.opacity(0.45))
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            VStack(spacing: 1) {
                StenoSidebarRow(
                    title: "Today",
                    count: nil,
                    systemImage: "house",
                    isSelected: activeItem == .home,
                    accessibilityIdentifier: "sidebar-home"
                ) {
                    selection = .dashboard
                    activeItem = .home
                }

                if appModel.featureFlags.granolaEnabled {
                    StenoSidebarRow(
                        title: "All notes",
                        count: appModel.meetingNotes.count,
                        systemImage: "tray",
                        isSelected: activeItem == .allNotes,
                        accessibilityIdentifier: "sidebar-all-notes"
                    ) {
                        selection = .meetings
                        activeItem = .allNotes
                    }

                    StenoSidebarRow(
                        title: "Ask notes",
                        count: nil,
                        systemImage: "sparkle.magnifyingglass",
                        isSelected: activeItem == .ask,
                        accessibilityIdentifier: "sidebar-ask"
                    ) {
                        selection = .ask
                        activeItem = .ask
                    }
                }

                StenoSidebarRow(
                    title: "Dictation history",
                    count: nil,
                    systemImage: "clock.arrow.circlepath",
                    isSelected: activeItem == .speechToText,
                    accessibilityIdentifier: "sidebar-speech-to-text"
                ) {
                    selection = .speechToText
                    activeItem = .speechToText
                }

                StenoSidebarRow(
                    title: "Settings",
                    count: nil,
                    systemImage: "gearshape",
                    isSelected: activeItem == .settings,
                    accessibilityIdentifier: "sidebar-settings"
                ) {
                    selection = .settings
                    activeItem = .settings
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .background(FlowTheme.subtle)
    }
}

private struct StenoSidebarRow: View {
    let title: String
    let count: Int?
    let systemImage: String
    let isSelected: Bool
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? FlowTheme.textPrimary : FlowTheme.textSecondary)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if let count {
                    Text("\(count)")
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? FlowTheme.elevated : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? FlowTheme.border.opacity(0.8) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var accessibilityLabel: String {
        if let count {
            return "\(title), \(count)"
        }
        return title
    }
}

private struct StenoTopToolbar: View {
    @ObservedObject var appModel: AppModel
    let showsNewNote: Bool
    let onNewNote: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                appModel.cycleAppearancePreference()
            } label: {
                toolbarIconLabel(appModel.appearancePreference.toolbarSystemImage)
            }
            .buttonStyle(.plain)
            .help("Appearance: \(appModel.appearancePreference.displayName)")
            .accessibilityLabel("Appearance")
            .accessibilityValue(appModel.appearancePreference.displayName)
            .accessibilityIdentifier("toolbar-appearance-toggle")

            if showsNewNote {
                Button(action: onNewNote) {
                    HStack(spacing: 8) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                        Text("New note")
                    }
                }
                .buttonStyle(CadenceActionButtonStyle(role: .secondary))
                .controlSize(.large)
                .accessibilityLabel("New note")
                .accessibilityIdentifier("toolbar-new-note")
            }
        }
    }

    private func toolbarIconLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(FlowTheme.textSecondary)
            .frame(width: 28, height: 28)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct StenoHomeContent: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsOtherTodayEvents = false
    let onOpenAllNotes: () -> Void
    let onOpenNote: (MeetingNote) -> Void
    let onOpenSettings: () -> Void
    let onJoinCalendarEvent: (GoogleCalendarEvent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .padding(.bottom, appModel.featureFlags.granolaEnabled ? 20 : 30)

                if appModel.featureFlags.granolaEnabled {
                    upcomingSectionHeader
                        .padding(.bottom, 14)

                    upcomingContent
                        .padding(.bottom, 46)

                    StenoSectionHeader(title: "Recent notes", count: appModel.meetingNotes.count)
                        .padding(.bottom, 8)

                    previousRows
                }

                StenoSectionHeader(title: "Recent dictations", count: appModel.transcriptHistory.count)
                    .padding(.top, appModel.featureFlags.granolaEnabled ? 38 : 0)
                    .padding(.bottom, 8)

                recentDictationRows
            }
            .frame(maxWidth: StenoLayout.contentMaxWidth, alignment: .topLeading)
            .padding(.top, StenoLayout.contentTopPadding)
            .padding(.bottom, StenoLayout.contentBottomPadding)
            .padding(.horizontal, StenoLayout.contentHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(FlowTheme.background)
    }

    @ViewBuilder
    private var upcomingSectionHeader: some View {
        HStack(spacing: 10) {
            Text("Upcoming")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text("\(upcomingEventCount)")
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.textTertiary)
            Spacer()

            if appModel.googleCalendarConnectionState.isConnected {
                Button {
                    appModel.refreshUpcomingCalendarMeetingsFromUI()
                } label: {
                    Image(systemName: appModel.isRefreshingCalendar ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(appModel.isRefreshingCalendar)
                .help("Refresh calendar")
                .accessibilityLabel(
                    appModel.isRefreshingCalendar ? "Refreshing calendar" : "Refresh calendar"
                )
                .accessibilityIdentifier("home-calendar-refresh-button")
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlowTheme.border.opacity(0.55))
                .frame(height: 1)
        }
    }

    private var upcomingEventCount: Int {
        todayEvents.count
    }

    private var todayEvents: [GoogleCalendarEvent] {
        CalendarEventDashboard.todayEvents(events: appModel.upcomingCalendarMeetings)
    }

    @ViewBuilder
    private var upcomingContent: some View {
        if !appModel.googleCalendarConnectionState.isConnected {
            StenoCalendarSignInCard(
                state: appModel.googleCalendarConnectionState,
                isConnecting: appModel.isConnectingGoogleCalendar,
                onSignIn: appModel.connectGoogleCalendar
            )
        } else if appModel.isRefreshingCalendar && appModel.upcomingCalendarMeetings.isEmpty {
            StenoEmptyLine(text: "Loading calendar...")
        } else {
            if todayEvents.isEmpty {
                StenoEmptyLine(text: "No more events today")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let nextEvent = todayEvents.first {
                        StenoUpcomingCard(
                            event: nextEvent,
                            onJoinCalendarEvent: onJoinCalendarEvent
                        )
                    }

                    if todayEvents.count > 1 {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                showsOtherTodayEvents.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(todayEvents.count - 1) others today")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Image(systemName: showsOtherTodayEvents ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(FlowTheme.textSecondary)
                            .padding(.horizontal, 4)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            showsOtherTodayEvents
                                ? "Collapse \(todayEvents.count - 1) other events today"
                                : "Expand \(todayEvents.count - 1) other events today"
                        )
                        .accessibilityIdentifier("calendar-other-events-toggle")

                        if showsOtherTodayEvents {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(todayEvents.dropFirst())) { event in
                                    StenoUpcomingCard(
                                        event: event,
                                        onJoinCalendarEvent: onJoinCalendarEvent
                                    )
                                }
                            }
                            .transition(.opacity)
                            .accessibilityIdentifier("calendar-other-events-list")
                        }
                    }
                }
            }
        }
    }

    private var previousRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appModel.meetingNotes.isEmpty {
                StenoEmptyLine(text: "No notes yet")
            } else {
                ForEach(Array(appModel.meetingNotes.prefix(8).enumerated()), id: \.element.id) { index, note in
                    StenoPreviousNoteRow(note: note, showsTopSeparator: index > 0) {
                        onOpenNote(note)
                    }
                }
            }
        }
    }

    private var recentDictationRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appModel.transcriptHistory.isEmpty {
                StenoEmptyLine(text: "No recent dictations")
            } else {
                ForEach(
                    Array(appModel.transcriptHistory.prefix(6).enumerated()),
                    id: \.element.id
                ) { index, item in
                    StenoTranscriptHistoryRow(item: item, showsTopSeparator: index > 0) {
                        appModel.copyTranscript(item)
                    }
                }
            }
        }
    }
}

private struct StenoAllNotesContent: View {
    @ObservedObject var appModel: AppModel
    let onOpenNote: (MeetingNote) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("All notes")
                    .font(.system(size: 26, weight: .regular, design: .serif))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .padding(.bottom, 6)

                Text("Recordings, notes, and transcripts in one place.")
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .padding(.bottom, 28)

                if appModel.meetingNotes.isEmpty {
                    StenoEmptyLine(text: "No notes yet")
                } else {
                    ForEach(noteGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            StenoSectionHeader(title: group.title, count: group.notes.count)
                                .padding(.bottom, 4)

                            ForEach(Array(group.notes.enumerated()), id: \.element.id) { index, note in
                                StenoPreviousNoteRow(note: note, showsTopSeparator: index > 0) {
                                    onOpenNote(note)
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .frame(maxWidth: StenoLayout.contentMaxWidth, alignment: .topLeading)
            .padding(.top, StenoLayout.contentTopPadding)
            .padding(.bottom, StenoLayout.contentBottomPadding)
            .padding(.horizontal, StenoLayout.contentHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(FlowTheme.background)
    }

    private var noteGroups: [StenoNoteGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: appModel.meetingNotes) { note in
            calendar.startOfDay(for: note.updatedAt)
        }

        return groups.keys.sorted(by: >).map { date in
            StenoNoteGroup(
                date: date,
                title: groupTitle(for: date, calendar: calendar),
                notes: groups[date, default: []].sorted { $0.updatedAt > $1.updatedAt }
            )
        }
    }

    private func groupTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
}

private struct StenoNoteGroup: Identifiable {
    let date: Date
    let title: String
    let notes: [MeetingNote]

    var id: Date { date }
}

private struct StenoGlobalAskContent: View {
    @ObservedObject var appModel: AppModel
    let onOpenNote: (MeetingNote) -> Void
    @State private var question = ""
    @State private var answer: GlobalAskAnswer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Ask notes")
                    .font(.system(size: 26, weight: .regular, design: .serif))
                    .foregroundStyle(FlowTheme.textPrimary)

                askField

                if let answer {
                    globalAnswerView(answer)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(appModel.meetingNotes.count) notes indexed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(FlowTheme.textSecondary)

                        HStack(spacing: 8) {
                            askSuggestion("What did I discuss recently?")
                            askSuggestion("What action items are open?")
                            askSuggestion("Find decisions")
                        }
                    }
                }
            }
            .frame(maxWidth: StenoLayout.contentMaxWidth, alignment: .topLeading)
            .padding(.top, StenoLayout.contentTopPadding)
            .padding(.bottom, StenoLayout.contentBottomPadding)
            .padding(.horizontal, StenoLayout.contentHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(FlowTheme.background)
    }

    private var askField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FlowTheme.textTertiary)

            TextField("Ask across notes", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(submit)
                .accessibilityLabel("Ask across notes")
                .accessibilityIdentifier("global-ask-field")

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(canSubmit ? FlowTheme.background : FlowTheme.textTertiary)
                    .background(canSubmit ? FlowTheme.textPrimary : FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Ask notes")
            .accessibilityIdentifier("global-ask-submit-button")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }

    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func askSuggestion(_ text: String) -> some View {
        Button {
            question = text
            submit()
        } label: {
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(FlowTheme.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func globalAnswerView(_ answer: GlobalAskAnswer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(answer.answer)
                .font(.system(size: 14))
                .foregroundStyle(FlowTheme.textPrimary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if !answer.matches.isEmpty {
                StenoSectionHeader(title: "Sources", count: answer.matches.count)
                    .padding(.bottom, 2)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(answer.matches.enumerated()), id: \.element.id) { index, match in
                        Button {
                            onOpenNote(match.note)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(match.note.displayTitle)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(FlowTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(match.source)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(FlowTheme.textTertiary)
                                }

                                Text(match.snippet)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(FlowTheme.textSecondary)
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Rectangle()
                                        .fill(FlowTheme.border.opacity(0.48))
                                        .frame(height: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func submit() {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer = GlobalAskAnswer.answer(question: trimmed, notes: appModel.meetingNotes)
    }
}

private struct StenoSpeechHistoryContent: View {
    @ObservedObject var appModel: AppModel
    @State private var showsExpandedHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Dictation history")
                        .font(.system(size: 26, weight: .regular, design: .serif))
                        .foregroundStyle(FlowTheme.textPrimary)

                    if !appModel.transcriptHistory.isEmpty {
                        Text("\(appModel.transcriptHistory.count)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FlowTheme.textTertiary)
                    }

                    Spacer()
                }
                .padding(.bottom, 18)

                if let latest = visibleTranscripts.first {
                    StenoLatestTranscriptCard(item: latest) {
                        appModel.copyTranscript(latest)
                    }
                    .padding(.bottom, 28)
                }

                if appModel.transcriptHistory.isEmpty {
                    StenoEmptyLine(text: "No speech-to-text history yet")
                } else if !earlierTranscripts.isEmpty {
                    StenoSectionHeader(title: "Earlier", count: earlierTranscripts.count)
                        .padding(.bottom, 4)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(earlierTranscripts.enumerated()), id: \.element.id) { index, item in
                            StenoTranscriptHistoryRow(item: item, showsTopSeparator: index > 0) {
                                appModel.copyTranscript(item)
                            }
                        }
                    }
                }

                historyFooter
                    .padding(.top, appModel.transcriptHistory.isEmpty ? 0 : 20)
            }
            .frame(maxWidth: StenoLayout.contentMaxWidth, alignment: .topLeading)
            .padding(.top, StenoLayout.contentTopPadding)
            .padding(.bottom, StenoLayout.contentBottomPadding)
            .padding(.horizontal, StenoLayout.contentHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(FlowTheme.background)
    }

    @ViewBuilder
    private var historyFooter: some View {
        if appModel.transcriptHistory.count > TranscriptHistoryPolicy.initialPreviewCount,
           !showsExpandedHistory {
            CadenceActionButton(
                title: "Show more",
                role: .secondary,
                accessibilityIdentifier: "dictation-history-show-more"
            ) {
                showsExpandedHistory = true
            }
        } else if !appModel.transcriptHistory.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if appModel.transcriptHistory.count > TranscriptHistoryPolicy.expandedPreviewCount {
                    Text(
                        "Showing the newest \(TranscriptHistoryPolicy.expandedPreviewCount). "
                            + "Export includes all \(appModel.transcriptHistory.count)."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textTertiary)
                }

                CadenceActionButton(
                    title: "Export history",
                    role: .secondary,
                    accessibilityIdentifier: "dictation-history-export"
                ) {
                    appModel.exportTranscriptHistory()
                }
            }
        }
    }

    private var visibleTranscripts: [TranscriptHistoryItem] {
        let count = showsExpandedHistory
            ? TranscriptHistoryPolicy.expandedVisibleCount(totalCount: appModel.transcriptHistory.count)
            : TranscriptHistoryPolicy.initialVisibleCount(totalCount: appModel.transcriptHistory.count)
        return Array(appModel.transcriptHistory.prefix(count))
    }

    private var earlierTranscripts: [TranscriptHistoryItem] {
        Array(visibleTranscripts.dropFirst())
    }
}

private struct StenoSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text("\(count)")
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.textTertiary)
            Spacer()
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlowTheme.border.opacity(0.55))
                .frame(height: 1)
        }
    }
}

private struct StenoCalendarSignInCard: View {
    let state: GoogleCalendarConnectionState
    let isConnecting: Bool
    let onSignIn: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FlowTheme.textSecondary)
                .frame(width: 30, height: 30)
                .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your calendar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(statusText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            GoogleSignInButton(
                isConnecting: isConnecting,
                isEnabled: state.isConfigured,
                accessibilityIdentifier: "google-sign-in-button",
                action: primaryAction
            )
        }
        .padding(14)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border.opacity(0.75), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-sign-in-card")
    }

    private var statusText: String {
        if isConnecting {
            return "Complete Google sign-in in the browser window."
        }
        if !state.isConfigured {
            return state.errorMessage ?? "Google Sign-In is not configured in this build."
        }
        return state.errorMessage ?? "Use your Google account to show meetings today and tomorrow."
    }

    private func primaryAction() {
        onSignIn()
    }
}

private struct StenoUpcomingCard: View {
    let event: GoogleCalendarEvent
    let onJoinCalendarEvent: (GoogleCalendarEvent) -> Void

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.startDate.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .monospacedDigit()
                Text(durationText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
            }
            .frame(width: 72, alignment: .leading)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(FlowTheme.border.opacity(0.5))
                    .frame(width: 1)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(event.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineLimit(1)

                Text(detailText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if let provider = event.meetingProvider {
                Button {
                    onJoinCalendarEvent(event)
                } label: {
                    HStack(spacing: 6) {
                        MeetingProviderIcon(provider: provider)
                        Text("Join")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(FlowTheme.background)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(FlowTheme.textPrimary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Join \(provider.displayName) meeting \(event.title)")
                .accessibilityIdentifier("calendar-event-join-\(accessibilityIdentifierSuffix(event.id))")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .medium))
                    Text("No meeting link included")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(FlowTheme.textTertiary)
                .accessibilityIdentifier("calendar-event-no-meeting-link-\(accessibilityIdentifierSuffix(event.id))")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 72)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border.opacity(0.75), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("calendar-event-card-\(accessibilityIdentifierSuffix(event.id))")
    }

    private var accessibilityLabel: String {
        "\(event.title), \(event.startDate.formatted(.dateTime.hour().minute())), \(detailText)"
    }

    private var durationText: String {
        let minutes = max(Int(event.endDate.timeIntervalSince(event.startDate) / 60), 0)
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    private var detailText: String {
        if !event.attendeeEmails.isEmpty {
            return "\(event.attendeeEmails.count) attendees"
        }
        if let calendarTitle = event.calendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !calendarTitle.isEmpty {
            return calendarTitle
        }
        return event.meetingURL == nil ? "Calendar event" : "Video meeting"
    }
}

private struct MeetingProviderIcon: View {
    let provider: GoogleMeetingProvider

    var body: some View {
        ZStack {
            Circle()
                .fill(providerColor)

            if provider == .microsoftTeams {
                Text("T")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
            } else if let assetName = provider.assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 9, height: 9)
            } else {
                Image(systemName: "video.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.white)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    private var providerColor: Color {
        switch provider {
        case .googleMeet:
            return Color(red: 0.00, green: 0.54, blue: 0.48)
        case .zoom:
            return Color(red: 0.04, green: 0.36, blue: 1.00)
        case .microsoftTeams:
            return Color(red: 0.39, green: 0.40, blue: 0.66)
        case .other:
            return FlowTheme.textSecondary
        }
    }
}

private struct StenoTranscriptHistoryRow: View {
    let item: TranscriptHistoryItem
    var showsTopSeparator = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(item.createdAt.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)

                Text(item.text)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .top) {
                if showsTopSeparator {
                    Rectangle()
                        .fill(FlowTheme.border.opacity(0.48))
                        .frame(height: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy transcript from \(item.createdAt.formatted(.dateTime.hour().minute()))")
        .accessibilityValue(item.text)
        .accessibilityIdentifier("speech-history-row-\(item.id.uuidString)")
    }
}

private struct StenoLatestTranscriptCard: View {
    let item: TranscriptHistoryItem
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                Spacer()
                CadenceActionButton(
                    title: "Copy",
                    role: .quiet,
                    accessibilityIdentifier: "speech-latest-copy-button",
                    action: onCopy
                )
                .accessibilityLabel("Copy latest transcript")
            }

            Text(item.text)
                .font(.system(size: 14))
                .foregroundStyle(FlowTheme.textPrimary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }
}

private struct StenoPreviousNoteRow: View {
    let note: MeetingNote
    var showsTopSeparator = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(note.updatedAt.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 12.5))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(note.displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .lineLimit(1)

                    Text(note.previewText)
                        .font(.system(size: 13))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                if let durationText {
                    Text(durationText)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .top) {
                if showsTopSeparator {
                    Rectangle()
                        .fill(FlowTheme.border.opacity(0.48))
                        .frame(height: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open note \(note.displayTitle)")
        .accessibilityValue(note.previewText)
        .accessibilityIdentifier("previous-note-row-\(note.id.uuidString)")
    }

    private var durationText: String? {
        guard let duration = note.effectiveAudioRecordings.last?.duration,
              duration > 0 else { return nil }
        if duration < 60 {
            return "\(Int(duration.rounded()))s"
        }
        return "\(Int(duration / 60))m"
    }
}

private struct StenoEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(FlowTheme.textSecondary)
            .padding(.vertical, 14)
    }
}

private struct GlobalAskMatch: Identifiable, Equatable {
    let id = UUID()
    let note: MeetingNote
    let source: String
    let snippet: String
}

private struct GlobalAskAnswer: Equatable {
    let question: String
    let answer: String
    let matches: [GlobalAskMatch]

    static func answer(question: String, notes: [MeetingNote]) -> GlobalAskAnswer {
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedQuery = query.lowercased()

        if lowercasedQuery.contains("action") || lowercasedQuery.contains("todo") || lowercasedQuery.contains("next") {
            let matches = notes.flatMap { note in
                (note.summary?.actionItems ?? []).map { item in
                    GlobalAskMatch(
                        note: note,
                        source: "Action item",
                        snippet: item.owner.map { "\($0): \(item.text)" } ?? item.text
                    )
                }
            }
            return GlobalAskAnswer(
                question: question,
                answer: matches.isEmpty ? "I could not find action items in your saved summaries yet." : "I found \(matches.count) action \(matches.count == 1 ? "item" : "items") across your notes.",
                matches: Array(matches.prefix(8))
            )
        }

        if lowercasedQuery.contains("decision") {
            let matches = notes.flatMap { note in
                (note.summary?.decisions ?? []).map {
                    GlobalAskMatch(note: note, source: "Decision", snippet: $0)
                }
            }
            return GlobalAskAnswer(
                question: question,
                answer: matches.isEmpty ? "I could not find decisions in your saved summaries yet." : "I found \(matches.count) decision \(matches.count == 1 ? "entry" : "entries") across your notes.",
                matches: Array(matches.prefix(8))
            )
        }

        let keywords = query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }

        let matches = notes.compactMap { note -> GlobalAskMatch? in
            let candidates = noteSearchCandidates(for: note)
            guard let best = candidates.first(where: { candidate in
                keywords.contains { candidate.text.lowercased().contains($0) }
            }) else { return nil }
            return GlobalAskMatch(note: note, source: best.source, snippet: best.text)
        }

        let answerText: String
        if matches.isEmpty {
            answerText = notes.isEmpty ? "No notes are available yet." : "I could not find a strong match. Try a person, topic, decision, or action item."
        } else {
            answerText = "I found \(matches.count) matching \(matches.count == 1 ? "note" : "notes")."
        }

        return GlobalAskAnswer(question: question, answer: answerText, matches: Array(matches.prefix(8)))
    }

    private static func noteSearchCandidates(for note: MeetingNote) -> [(source: String, text: String)] {
        var candidates = [(source: String, text: String)]()
        candidates.append(("Title", note.displayTitle))

        if !note.userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(("Notes", note.userNotes))
        }

        if let summary = note.summary?.overview,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(("Summary", summary))
        }

        candidates.append(contentsOf: note.transcriptSegments.map { ("Transcript", $0.text) })
        return candidates
    }
}

private struct MeetingNoteSelectionDetail: View {
    @ObservedObject var appModel: AppModel
    let noteID: UUID
    let onBack: () -> Void

    var body: some View {
        MeetingNotesView(appModel: appModel, presentation: .embedded, onBack: onBack)
            .background(FlowTheme.background)
            .task(id: noteID) {
                appModel.selectMeetingNote(id: noteID)
            }
    }
}

private struct MainSidebarHeader: View {
    let status: String
    let statusTint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(FlowTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cadence")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.brandText)
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusTint)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

private struct MainSidebarNewNoteButton: View {
    let action: () -> Void

    var body: some View {
        CadenceActionButton(title: "New note", role: .primary, action: action)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

private struct MainSidebarRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct DashboardDetailView: View {
    @ObservedObject var appModel: AppModel
    let onOpenMeetings: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 300), spacing: 16),
                    GridItem(.flexible(minimum: 300), spacing: 16)
                ], spacing: 16) {
                    DictationPanel(appModel: appModel, onOpenSettings: onOpenSettings)
                    MeetingPanel(appModel: appModel, onOpenMeetings: onOpenMeetings)
                }

                RecentWorkPanel(
                    transcripts: Array(appModel.transcriptHistory.prefix(4)),
                    notes: Array(appModel.meetingNotes.prefix(4)),
                    onOpenMeetings: onOpenMeetings,
                    onCopy: { _ = appModel.copyTranscript($0) }
                )
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .topLeading)
        }
        .background(FlowTheme.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Today")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(appModel.backendDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                _ = appModel.createMeetingNote()
                onOpenMeetings()
            } label: {
                Label("New Note", systemImage: "square.and.pencil")
            }
            .buttonStyle(CadenceActionButtonStyle(role: .primary))
            .controlSize(.large)
        }
    }
}

private struct DictationPanel: View {
    @ObservedObject var appModel: AppModel
    let onOpenSettings: () -> Void

    var body: some View {
        MainPanel {
            VStack(alignment: .leading, spacing: 18) {
                PanelTitle(title: "Dictation", systemImage: CadenceIconography.dictation)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(statusTitle)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)

                    Circle()
                        .fill(statusTint)
                        .frame(width: 8, height: 8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    MetricRow(title: "Mode", value: appModel.primaryTriggerMode.displayName)
                    MetricRow(title: "Shortcut", value: appModel.activeShortcutSummary.isEmpty ? "Off" : appModel.activeShortcutSummary)
                    MetricRow(title: "Quality", value: appModel.dictationQualityPreset.displayName)
                }

                HStack(spacing: 10) {
                    CadenceActionButton(title: appModel.permissions.allRequiredGranted ? "Check" : "Review", role: .secondary) {
                        if appModel.permissions.allRequiredGranted {
                            appModel.runSetupCheck()
                        } else {
                            appModel.openPermissionsWizard()
                        }
                    }

                    CadenceActionButton(title: "Tune", role: .secondary, action: onOpenSettings)
                }
            }
        }
    }

    private var statusTitle: String {
        if appModel.userFacingErrorMessage != nil {
            return "Needs attention"
        }
        if !appModel.permissions.allRequiredGranted {
            return "Setup needed"
        }
        switch appModel.state {
        case .idle:
            return "Ready"
        case .listening:
            return "Recording"
        case .finalizing, .inserting:
            return "Working"
        case .error:
            return "Needs attention"
        }
    }

    private var statusTint: Color {
        switch appModel.state {
        case .idle:
            return appModel.permissions.allRequiredGranted ? FlowTheme.success : FlowTheme.accent
        case .listening:
            return FlowTheme.accent
        case .finalizing, .inserting:
            return FlowTheme.teal
        case .error:
            return FlowTheme.error
        }
    }
}

private struct MeetingPanel: View {
    @ObservedObject var appModel: AppModel
    let onOpenMeetings: () -> Void

    var body: some View {
        MainPanel {
            VStack(alignment: .leading, spacing: 18) {
                PanelTitle(title: "Meetings", systemImage: "text.badge.checkmark")

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meetingTitle)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    MetricRow(title: "Calendar", value: appModel.googleCalendarConnectionState.isConnected ? "Connected" : "Not connected")
                    MetricRow(title: "Capture", value: captureTitle)
                    MetricRow(title: "Notes", value: "\(appModel.meetingNotes.count)")
                }

                if let session = appModel.meetingCaptureSession {
                    MeetingCaptureInlineStatus(session: session)
                }

                HStack(spacing: 10) {
                    CadenceActionButton(title: "New", role: .primary) {
                        _ = appModel.createMeetingNote()
                        onOpenMeetings()
                    }

                    CadenceActionButton(title: "Open", role: .secondary, action: onOpenMeetings)
                }
            }
        }
    }

    private var meetingTitle: String {
        if let session = appModel.meetingCaptureSession {
            return session.noteTitle
        }
        if let detected = appModel.detectedCalendarMeeting {
            return detected.title
        }
        return appModel.meetingNotes.first?.displayTitle ?? "No notes"
    }

    private var captureTitle: String {
        if let session = appModel.meetingCaptureSession {
            switch session.phase {
            case .starting:
                return "Starting"
            case .recording:
                return "Recording"
            case .finalizing:
                return "Transcribing"
            }
        }

        switch appModel.systemAudioCaptureState {
        case .idle:
            return "Ready"
        case .starting:
            return "Starting"
        case .capturing:
            return "Recording"
        case .stopping:
            return "Finalizing"
        case .failed:
            return "Unavailable"
        }
    }
}

private struct MeetingCaptureInlineStatus: View {
    let session: MeetingCaptureSessionSummary

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineLimit(1)

                Text("\(session.source.displayName) • \(durationDescription) captured")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        switch session.phase {
        case .starting:
            return "Preparing capture"
        case .recording:
            return "Recording into meeting note"
        case .finalizing:
            return "Transcribing in background"
        }
    }

    private var symbolName: String {
        switch session.phase {
        case .starting:
            return "dot.radiowaves.left.and.right"
        case .recording:
            return "waveform"
        case .finalizing:
            return "text.bubble"
        }
    }

    private var tint: Color {
        session.phase == .recording ? FlowTheme.accent : FlowTheme.teal
    }

    private var durationDescription: String {
        let totalSeconds = max(Int((Double(session.capturedFrameCount) / 16_000).rounded()), 0)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct RecentWorkPanel: View {
    let transcripts: [TranscriptHistoryItem]
    let notes: [MeetingNote]
    let onOpenMeetings: () -> Void
    let onCopy: (TranscriptHistoryItem) -> Void

    var body: some View {
        MainPanel {
            VStack(alignment: .leading, spacing: 16) {
                PanelTitle(title: "Recent", systemImage: "clock")

                if transcripts.isEmpty && notes.isEmpty {
                    Text("Nothing yet")
                        .font(.system(size: 14))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(transcripts) { transcript in
                            RecentRow(
                                title: transcript.text,
                                detail: transcript.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                                systemImage: "quote.bubble"
                            ) {
                                onCopy(transcript)
                            }
                            if transcript.id != transcripts.last?.id || !notes.isEmpty {
                                Divider()
                            }
                        }

                        ForEach(notes) { note in
                            RecentRow(
                                title: note.displayTitle,
                                detail: note.updatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                                systemImage: "doc.text"
                            ) {
                                onOpenMeetings()
                            }
                            if note.id != notes.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MainPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FlowTheme.border, lineWidth: 1)
            )
    }
}

private struct PanelTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(FlowTheme.textSecondary)
    }
}

private struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(FlowTheme.textSecondary)
            Spacer()
            Text(value)
                .foregroundStyle(FlowTheme.textPrimary)
                .lineLimit(1)
        }
        .font(.system(size: 13))
    }
}

private struct RecentRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(FlowTheme.textTertiary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .lineLimit(1)

                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.textSecondary)
                }

                Spacer()
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}
