import Foundation
import OSLog
import SwiftUI

private let scribeSelectedTextSettingsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ScribeSelectedTextSettings"
)

struct ScribeSelectedTextContextSettingsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(
                title: "Use selected text",
                description: nil,
                isOn: Binding(
                    get: { appModel.scribeSelectedTextContextPreferences.isEnabled },
                    set: { appModel.setScribeSelectedTextContextEnabled($0) }
                ),
                accessibilityIdentifier: "scribe-selected-text-context-toggle"
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("When enabled for TextEdit, Compose reads the text you select when a recording starts. Apple Intelligence processes it on this Mac.")
                Text("Selected text is not sent to cloud providers. This preview does not save the selection or its resulting draft to history, including after Copy or Insert.")
            }
            .font(.system(size: 12))
            .foregroundStyle(FlowTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .accessibilityIdentifier("scribe-selected-text-context-disclosure")

            Divider().padding(.horizontal, 12)

            SettingsToggleRow(
                title: "Allow TextEdit",
                description: "Preview support; Accessibility compatibility is still being verified.",
                isOn: Binding(
                    get: { appModel.scribeSelectedTextContextPreferences.textEditAllowed },
                    set: { appModel.setScribeSelectedTextTextEditAllowed($0) }
                ),
                accessibilityIdentifier: "scribe-selected-text-textedit-toggle"
            )
            .disabled(!appModel.scribeSelectedTextContextPreferences.isEnabled)

            if appModel.configuredScribeProviderKind != .legacyLocal {
                Text("These choices apply when Apple Intelligence is selected. Selected text is unavailable with cloud providers.")
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("scribe-selected-text-local-only")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scribe-selected-text-context-settings")
    }
}
