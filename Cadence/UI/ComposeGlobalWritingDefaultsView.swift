import SwiftUI
import OSLog

private let composeGlobalDefaultsViewLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeGlobalDefaultsView")

struct ComposeGlobalWritingDefaultsView: View {
    @ObservedObject var appModel: AppModel
    @State private var draft = ComposeGlobalWritingDefaults()
    @State private var loaded = ComposeGlobalWritingDefaults()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Use my writing defaults", isOn: $draft.isEnabled)
                .disabled(appModel.scribeGlobalWritingDefaultsUnavailable)
                .accessibilityIdentifier("compose-global-defaults-enabled")
            Picker("Tone", selection: $draft.tone) {
                ForEach(ComposeGlobalWritingDefaults.Tone.allCases, id: \.self) { tone in
                    Text(tone.title).tag(tone)
                }
            }.disabled(!draft.isEnabled || appModel.scribeGlobalWritingDefaultsUnavailable).accessibilityIdentifier("compose-global-defaults-tone")
            Toggle("Prefer concise drafts", isOn: $draft.preferConcise)
                .disabled(!draft.isEnabled || appModel.scribeGlobalWritingDefaultsUnavailable).accessibilityIdentifier("compose-global-defaults-concise")
            Text("Applies to new Compose recordings. Your saved app profiles take priority. Spoken directions override conflicting defaults for that request. Cadence does not learn these choices from your drafts.")
                .font(.caption).foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if appModel.scribeGlobalWritingDefaultsUnavailable {
                Text("Saved defaults could not be read. They have been preserved and are not applied.")
                    .font(.caption).accessibilityIdentifier("compose-global-defaults-unavailable")
                Button("Remove unreadable defaults") { perform { try appModel.removeUnreadableScribeGlobalWritingDefaults() } }
                    .accessibilityIdentifier("compose-global-defaults-remove-unreadable")
            }
            if let message { Text(message).font(.caption).accessibilityIdentifier("compose-global-defaults-notice") }
            HStack {
                Button("Reset") { perform { try appModel.resetScribeGlobalWritingDefaults(replacing: loaded) } }
                    .disabled(loaded == .init()).accessibilityIdentifier("compose-global-defaults-reset")
                Spacer()
                Button("Cancel") { draft = loaded; message = nil }
                    .disabled(draft == loaded).accessibilityIdentifier("compose-global-defaults-cancel")
                Button("Save") { perform { try appModel.saveScribeGlobalWritingDefaults(draft, replacing: loaded) } }
                    .disabled(draft == loaded).accessibilityIdentifier("compose-global-defaults-save")
            }.disabled(appModel.scribeGlobalWritingDefaultsUnavailable)
        }
        .padding(12)
        .onAppear {
            appModel.reloadScribeGlobalWritingDefaults()
            loaded = appModel.scribeGlobalWritingDefaults; draft = loaded
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            loaded = appModel.scribeGlobalWritingDefaults; draft = loaded
            message = "Saved for new recordings."
        } catch {
            message = "Defaults changed or could not be saved. Reopen this section before trying again."
        }
    }
}
