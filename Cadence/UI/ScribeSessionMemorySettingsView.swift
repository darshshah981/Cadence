import SwiftUI

/// Opt-in local session memory for verified saved TextEdit documents.
struct ScribeSessionMemorySettingsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Recognize the current document",
                description: nil,
                isOn: Binding(
                    get: { appModel.scribeSessionMemoryPreferences.isEnabled },
                    set: { appModel.setScribeSessionMemoryEnabled($0) }
                ),
                accessibilityIdentifier: "scribe-session-memory-identity-toggle"
            )

            Text("When you start Compose in a saved TextEdit document, Cadence may identify that document on this Mac. Identifying it does not read its contents or save facts. The separate controls below let you save session facts, remember drafts you choose, and use relevant facts in local drafts.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .accessibilityIdentifier("scribe-session-memory-identity-disclosure")

            Divider().padding(.horizontal, 12)

            SettingsToggleRow(
                title: "Allow TextEdit",
                description: "Saved, regular documents only. Other apps remain unsupported.",
                isOn: Binding(
                    get: { appModel.scribeSessionMemoryPreferences.textEditAllowed },
                    set: { appModel.setScribeSessionMemoryTextEditAllowed($0) }
                ),
                accessibilityIdentifier: "scribe-session-memory-textedit-toggle"
            )
            .disabled(!appModel.scribeSessionMemoryPreferences.isEnabled)

            Divider().padding(.horizontal, 12)

            SettingsToggleRow(
                title: "Remember facts I explicitly state",
                description: "Only for this saved TextEdit document during this app session.",
                isOn: Binding(
                    get: { appModel.scribeSessionMemoryPreferences.rememberExplicitFacts },
                    set: { appModel.setScribeSessionMemoryRememberExplicitFacts($0) }
                ),
                accessibilityIdentifier: "scribe-session-memory-retention-toggle"
            )
            .disabled(!appModel.scribeSessionMemoryPreferences.permitsTextEditUse)

            Text("In Compose, say “Remember that …” to save a fact, “What do you remember for this document?” to inspect, “Cadence, correct memory [old fact] should be [new fact]” to correct a recent fact, or “Forget this document” to remove session memory. Facts stay on this Mac, expire within 30 minutes, and are never added to your Compose history.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .accessibilityIdentifier("scribe-session-memory-retention-disclosure")

            Divider().padding(.horizontal, 12)

            SettingsToggleRow(
                title: "Remember drafts I copy or insert",
                description: "For this verified TextEdit document and app session only. Copying or inserting does not mean a message was sent.",
                isOn: Binding(
                    get: { appModel.scribeSessionMemoryPreferences.rememberChosenDrafts },
                    set: { appModel.setScribeSessionMemoryRememberChosenDrafts($0) }
                ),
                accessibilityIdentifier: "scribe-session-memory-chosen-drafts-toggle"
            )
            .disabled(!appModel.scribeSessionMemoryPreferences.permitsTextEditUse)

            Text("Only the reviewed Compose draft you chose is remembered after a successful Copy or confirmed Insert. It is labeled as a draft, never treated as a fact or proof of delivery, and is excluded from generation. Inspect or forget it by voice; it expires within 30 minutes. Turning this control off clears session memory for all documents.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .accessibilityIdentifier("scribe-session-memory-chosen-drafts-disclosure")

            Divider().padding(.horizontal, 12)

            SettingsToggleRow(
                title: "Use relevant facts in local drafts",
                description: "Only with Apple Intelligence, for the same verified TextEdit document. Cloud providers never receive these facts.",
                isOn: Binding(
                    get: { appModel.scribeSessionMemoryPreferences.useFactsInLocalDrafts },
                    set: { appModel.setScribeSessionMemoryUseFactsInLocalDrafts($0) }
                ),
                accessibilityIdentifier: "scribe-session-memory-draft-use-toggle"
            )
            .disabled(!appModel.scribeSessionMemoryPreferences.permitsTextEditRetention)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scribe-session-memory-settings")
    }
}
