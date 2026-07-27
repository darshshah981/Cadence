import AppKit
import SwiftUI

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let rootModel: AppModel
    @StateObject private var appModel: AppModel

    @MainActor
    init() {
        let model = AppModel()
        self.rootModel = model
        _appModel = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            CadenceMenuBarMenu(appModel: appModel)
        } label: {
            CadenceMenuBarIcon(isRecording: appModel.isActivelyRecording)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(appModel: appModel)
                .padding(18)
                .frame(width: 420, height: 560)
                .background(FlowTheme.background)
                .preferredColorScheme(appModel.appearancePreference.colorScheme)
        }
    }
}

private struct CadenceMenuBarIcon: View {
    let isRecording: Bool

    var body: some View {
        Image(systemName: isRecording ? "waveform.circle.fill" : "waveform.circle")
            .symbolRenderingMode(.monochrome)
            .imageScale(.medium)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isRecording ? "Cadence, recording" : "Cadence")
    }
}

private struct CadenceMenuBarMenu: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Button("Open Cadence") {
            appModel.showMainWindow()
        }
        .keyboardShortcut("o")

        if appModel.isCadenceBarHidden {
            Button("Show Cadence bar") {
                appModel.showCadenceBar()
            }
        }

        if appModel.featureFlags.granolaEnabled {
            Divider()
            upcomingSection
        }

        Divider()

        transcriptMenu

        Divider()

        Button("Quit Cadence") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var upcomingSection: some View {
        if appModel.googleCalendarConnectionState.isConnected {
            Section("Upcoming") {
                Button(appModel.isRefreshingCalendar ? "Refreshing Calendar..." : "Refresh Calendar") {
                    appModel.refreshUpcomingCalendarMeetingsFromUI()
                }
                .disabled(appModel.isRefreshingCalendar)

                let groups = CalendarEventDashboard.groups(events: appModel.upcomingCalendarMeetings)
                if groups.isEmpty {
                    Text("No meetings today or tomorrow")
                } else {
                    ForEach(groups) { group in
                        Menu(group.title) {
                            ForEach(group.events.prefix(6)) { event in
                                Button(calendarMenuTitle(for: event)) {
                                    if event.meetingURL != nil {
                                        _ = appModel.startCalendarEventCapture(event)
                                    } else {
                                        appModel.openCalendarEvent(event)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            Section("Upcoming") {
                Button {
                    appModel.connectGoogleCalendar()
                } label: {
                    Label {
                        Text(appModel.isConnectingGoogleCalendar ? "Opening Google..." : "Sign in with Google")
                    } icon: {
                        Image("GoogleG")
                            .renderingMode(.original)
                    }
                }
                .disabled(appModel.isConnectingGoogleCalendar || !appModel.isGoogleCalendarSignInAvailable)

                if let error = appModel.googleCalendarConnectionState.errorMessage, !error.isEmpty {
                    Text(Self.menuText(error))
                } else if !appModel.isGoogleCalendarSignInAvailable {
                    Text("Google Sign-In not configured")
                }
            }
        }
    }

    private var transcriptMenu: some View {
        Menu("Recent Transcripts") {
            if appModel.transcriptHistory.isEmpty {
                Text("No recent transcripts")
            } else {
                ForEach(appModel.transcriptHistory.prefix(8)) { item in
                    Button(transcriptMenuTitle(for: item)) {
                        appModel.copyTranscript(item)
                    }
                }
            }
        }
    }

    private func calendarMenuTitle(for event: GoogleCalendarEvent) -> String {
        let action = event.meetingURL == nil ? "" : "Join "
        let time = event.startDate.formatted(.dateTime.hour().minute())
        return Self.menuText("\(action)\(time) \(event.title)")
    }

    private func transcriptMenuTitle(for item: TranscriptHistoryItem) -> String {
        let prefix = appModel.copiedTranscriptID == item.id ? "Copied " : ""
        let composeLabel = item.isComposeResult ? "Compose · " : ""
        return Self.menuText(prefix + composeLabel + item.text)
    }

    private static func menuText(_ raw: String, maxLength: Int = 30) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > maxLength else {
            return normalized.isEmpty ? "Untitled" : normalized
        }
        let index = normalized.index(normalized.startIndex, offsetBy: maxLength - 1)
        return normalized[..<index].trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
