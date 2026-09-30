import OSLog
import SwiftUI

private let composeTextEditDefaultsViewLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeTextEditDefaultsView"
)

struct ComposeTextEditWritingDefaultsView: View {
    @ObservedObject var appModel: AppModel
    @State private var draft = ComposeTextEditWritingDefaults()
    @State private var loaded = ComposeTextEditWritingDefaults()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Tone in TextEdit", selection: $draft.tone) {
                ForEach(ComposeGlobalWritingDefaults.Tone.allCases, id: \.self) { tone in
                    Text(tone.title).tag(tone)
                }
            }
            .disabled(appModel.scribeTextEditWritingDefaultsUnavailable)
            .accessibilityIdentifier("compose-textedit-defaults-tone")
            Toggle("Prefer concise drafts in TextEdit", isOn: $draft.preferConcise)
                .disabled(appModel.scribeTextEditWritingDefaultsUnavailable)
                .accessibilityIdentifier("compose-textedit-defaults-concise")
            Text("Applies only when a new Compose recording starts in TextEdit on this Mac. A spoken direction for this request takes priority. Cadence does not learn from your drafts.")
                .font(.caption)
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if appModel.scribeTextEditWritingDefaultsSupersededByProfile {
                Text("Your active TextEdit app profile takes priority. These choices are saved, but will apply only after that profile is turned off.")
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("compose-textedit-defaults-profile-priority")
            }
            if appModel.scribeTextEditWritingDefaultsUnavailable {
                Text("Saved app preferences could not be read. They have been preserved and are not applied.")
                    .font(.caption)
                    .accessibilityIdentifier("compose-textedit-defaults-unavailable")
                Button("Remove unreadable app preferences") {
                    perform(successMessage: "Unreadable app preferences removed.") {
                        try appModel.removeUnreadableScribeScopedWritingPreferences()
                    }
                }
                .accessibilityIdentifier("compose-textedit-defaults-remove-unreadable")
            }
            if let message {
                Text(message).font(.caption)
                    .accessibilityIdentifier("compose-textedit-defaults-notice")
            }
            HStack {
                Button("Reset") {
                    perform(successMessage: "TextEdit writing defaults reset.") {
                        try appModel.resetScribeTextEditWritingDefaults(replacing: loaded)
                    }
                }
                .disabled(loaded == .init())
                .accessibilityIdentifier("compose-textedit-defaults-reset")
                Spacer()
                Button("Cancel") { draft = loaded; message = nil }
                    .disabled(draft == loaded)
                    .accessibilityIdentifier("compose-textedit-defaults-cancel")
                Button("Save") {
                    perform(successMessage: "Saved for new TextEdit recordings.") {
                        try appModel.saveScribeTextEditWritingDefaults(draft, replacing: loaded)
                    }
                }
                .disabled(draft == loaded)
                .accessibilityIdentifier("compose-textedit-defaults-save")
            }
            .disabled(appModel.scribeTextEditWritingDefaultsUnavailable)
        }
        .padding(12)
        .onAppear {
            appModel.reloadScribeTextEditWritingDefaults()
            loaded = appModel.scribeTextEditWritingDefaults
            draft = loaded
        }
    }

    private func perform(successMessage: String, _ action: () throws -> Void) {
        do {
            try action()
            loaded = appModel.scribeTextEditWritingDefaults
            draft = loaded
            message = successMessage
        } catch {
            message = "App preferences changed or could not be saved. Reopen this section before trying again."
        }
    }
}
