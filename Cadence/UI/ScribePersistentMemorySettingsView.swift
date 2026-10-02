import SwiftUI

/// Separate consent for encrypted, explicitly saved facts. Session memory's
/// short-lived choice never enables this storage domain.
struct ScribePersistentMemorySettingsView: View {
    @ObservedObject var appModel: AppModel
    @State private var showsEnableConfirmation = false
    @State private var showsForgetConfirmation = false
    @State private var operationMessage: String?
    @State private var operationSucceeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved memory")
                .font(.headline)
            Text("This separate feature can keep facts you explicitly confirm for a verified, saved TextEdit document. Facts expire after 30 days and are encrypted on this Mac. They are not sent to cloud writing providers.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Turning saved memory off stops access but does not delete stored facts. Use Forget all saved facts to erase Cadence's current records. Older encrypted copies may remain in device or system backups, and deletion cannot recall content already shared outside Cadence.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if appModel.scribePersistentMemoryPreferences.isEnabled {
                Text(appModel.scribePersistentMemoryAvailable
                    ? "In a saved TextEdit document, use Compose to say “Cadence, remember for later that …” and review the exact fact before saving. You can also say “Cadence, what do you remember for this document?”, “Cadence, correct saved memory [old fact] should be [new fact]”, or “Cadence, forget saved facts for this document”. Corrections and forgetting require review."
                    : "Saved memory is currently unavailable. Existing encrypted records are preserved.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                Button("Turn off saved memory") {
                    appModel.disableScribePersistentMemory()
                    operationMessage = nil
                }
                .accessibilityIdentifier("scribe-persistent-memory-disable")
                SettingsToggleRow(
                    title: "Use relevant saved facts in local drafts",
                    description: "Only with Apple Intelligence in the same verified TextEdit document. Cloud writing providers never receive saved facts.",
                    isOn: Binding(
                        get: { appModel.scribePersistentMemoryPreferences.useFactsInLocalDrafts },
                        set: { appModel.setScribePersistentMemoryUseFactsInLocalDrafts($0) }
                    ),
                    accessibilityIdentifier: "scribe-persistent-memory-draft-use-toggle"
                )
                .disabled(!appModel.scribePersistentMemoryAvailable)
            } else if appModel.featureFlags.composePersistentMemoryEnabled {
                Button("Enable saved memory…") { showsEnableConfirmation = true }
                    .accessibilityIdentifier("scribe-persistent-memory-enable")
            }

            if appModel.scribePersistentMemoryPreferences.acceptedDisclosureRevision > 0 {
                Button("Forget all saved facts…", role: .destructive) {
                    showsForgetConfirmation = true
                }
                .accessibilityIdentifier("scribe-persistent-memory-forget-all")
            }
            if let message = operationMessage ?? appModel.scribePersistentMemoryStatus {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(operationMessage != nil && operationSucceeded
                        ? FlowTheme.success : FlowTheme.error)
                    .accessibilityIdentifier("scribe-persistent-memory-status")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .confirmationDialog(
            "Enable saved memory?", isPresented: $showsEnableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable for saved TextEdit documents") {
                do {
                    try appModel.enableScribePersistentMemory()
                    operationMessage = nil
                } catch {
                    operationSucceeded = false
                    operationMessage = "Saved memory could not be enabled. No fact was saved."
                }
            }
        } message: {
            Text("Cadence will create encrypted local storage and a Keychain key. Only facts you separately confirm can be saved. Each fact expires within 30 days. Turning this off does not erase saved facts; backups may retain older encrypted copies.")
        }
        .confirmationDialog(
            "Forget all saved facts?", isPresented: $showsForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget all saved facts", role: .destructive) {
                do {
                    let hadStore = try appModel.forgetAllScribePersistentMemory()
                    operationSucceeded = true
                    operationMessage = hadStore
                        ? "Saved facts were removed from Cadence's current store."
                        : "No saved-memory store was present."
                } catch {
                    operationSucceeded = false
                    operationMessage = "Saved facts could not be removed. Existing data was preserved."
                }
            }
        } message: {
            Text("This removes Cadence's current saved facts across documents. It cannot erase older copies in device or system backups.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scribe-persistent-memory-settings")
    }
}
