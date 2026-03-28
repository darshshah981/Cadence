import SwiftUI

struct MenuContentView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            switch appModel.menuScreen {
            case .home:
                homeScreen
            case .settings:
                SettingsView(appModel: appModel)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await appModel.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            if appModel.menuScreen == .settings {
                Button {
                    appModel.showHomeScreen()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(spacing: 4) {
                Text(appModel.menuScreen == .home ? "FlowState" : "Settings")
                    .font(.system(size: 22, weight: .semibold))
                Text(appModel.menuScreen == .home ? "Native push-to-talk dictation shell" : "Local dictation configuration")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appModel.menuScreen == .settings {
                Color.clear
                    .frame(width: 52, height: 1)
            }
        }
    }

    private var homeScreen: some View {
        Group {
            statusCard

            if !appModel.permissions.allRequiredGranted {
                PermissionsView(appModel: appModel)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Shortcuts: \(appModel.activeShortcutSummary.isEmpty ? "None enabled" : appModel.activeShortcutSummary)", systemImage: "keyboard")
                Label("Current state: \(stateLabel)", systemImage: appModel.menuBarSymbolName)
                Label("Backend: \(appModel.backendDescription)", systemImage: "cpu")
                Label("Preset: \(appModel.transcriptionConfiguration.summary)", systemImage: "slider.horizontal.3")
                if !previewText.isEmpty {
                    Label("Live preview: \(previewText)", systemImage: "waveform")
                        .lineLimit(3)
                }
                Label("Last transcript: \(appModel.lastTranscript.isEmpty ? "None yet" : appModel.lastTranscript)", systemImage: "text.quote")
                    .lineLimit(3)
            }
            .font(.system(size: 12.5))

            HStack {
                Button("Settings") {
                    appModel.showSettingsScreen()
                }

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }

            if let lastError = appModel.lastError {
                Text(lastError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            if let hotkeyConflictMessage = appModel.hotkeyConflictMessage {
                Text(hotkeyConflictMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: appModel.menuBarSymbolName)
                    .font(.system(size: 20, weight: .medium))
                Text(stateLabel)
                    .font(.headline)
            }

            Text("\(appModel.activeShortcutSummary.isEmpty ? "No dictation shortcuts are enabled." : appModel.activeShortcutSummary). FlowState captures microphone audio, runs local Whisper transcription with the active preset, and types the result back into the focused field.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var stateLabel: String {
        switch appModel.state {
        case .idle:
            return "Idle"
        case .listening:
            return "Listening"
        case .finalizing:
            return "Finalizing"
        case .inserting:
            return "Inserting"
        case .error:
            return "Error"
        }
    }

    private var previewText: String {
        [appModel.livePreviewConfirmedText, appModel.livePreviewUnconfirmedText]
            .filter { !$0.isEmpty }
            .joined(separator: appModel.livePreviewConfirmedText.isEmpty || appModel.livePreviewUnconfirmedText.isEmpty ? "" : " ")
    }
}
