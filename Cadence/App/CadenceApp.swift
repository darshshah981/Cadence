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
        ZStack {
            CadenceMenuBarWaveShape()
                .stroke(
                    Color.primary,
                    style: StrokeStyle(
                        lineWidth: CadenceMenuBarIconMetrics.strokeWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            Circle()
                .fill(Color.primary.opacity(isRecording ? 1 : 0.58))
                .frame(
                    width: CadenceMenuBarIconMetrics.dotDiameter(isRecording: isRecording),
                    height: CadenceMenuBarIconMetrics.dotDiameter(isRecording: isRecording)
                )
                .position(
                    x: CadenceMenuBarIconMetrics.dotCenter.x,
                    y: CadenceMenuBarIconMetrics.dotCenter.y
                )
                .accessibilityHidden(true)
        }
        .frame(
            width: CadenceMenuBarIconMetrics.frameSize,
            height: CadenceMenuBarIconMetrics.frameSize
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRecording ? "Cadence, recording" : "Cadence")
    }
}

enum CadenceMenuBarIconMetrics {
    static let frameSize: CGFloat = 18
    static let strokeWidth: CGFloat = 1.8
    static let dotCenter = CGPoint(x: 16.1, y: 8.7)

    static func dotDiameter(isRecording: Bool) -> CGFloat {
        isRecording ? 4.2 : 2.8
    }
}

struct CadenceMenuBarWaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: width * 0.08, y: height * 0.58))
        path.addCurve(
            to: CGPoint(x: width * 0.38, y: height * 0.34),
            control1: CGPoint(x: width * 0.19, y: height * 0.62),
            control2: CGPoint(x: width * 0.24, y: height * 0.25)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.62, y: height * 0.67),
            control1: CGPoint(x: width * 0.48, y: height * 0.34),
            control2: CGPoint(x: width * 0.50, y: height * 0.68)
        )
        path.addCurve(
            to: CGPoint(x: width * 0.81, y: height * 0.45),
            control1: CGPoint(x: width * 0.71, y: height * 0.67),
            control2: CGPoint(x: width * 0.72, y: height * 0.45)
        )
        return path
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

        Divider()

        upcomingSection

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
        return Self.menuText(prefix + item.text)
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
