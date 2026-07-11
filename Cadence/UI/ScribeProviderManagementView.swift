import SwiftUI

struct ScribeProviderManagementView: View {
    @ObservedObject var appModel: AppModel
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(appModel.scribeProviderStatus)
                        .font(.caption)
                        .foregroundStyle(FlowTheme.textSecondary)
                }
                Spacer()
                CadenceActionButton(
                    title: appModel.configuredScribeProviderKind == nil ? "Set up" : "Replace",
                    role: .secondary
                ) { appModel.presentScribeProviderSetup() }
                .accessibilityIdentifier("scribe-provider-setup")
            }

            if let kind = appModel.configuredScribeProviderKind {
                Divider()
                Toggle(
                    "Enable \(kind.displayName) for new Scribe requests",
                    isOn: Binding(
                        get: { appModel.configuredScribeProviderIsEnabled },
                        set: { appModel.setConfiguredScribeProviderEnabled($0) }
                    )
                )
                .toggleStyle(.switch)

                DisclosureGroup("Review data sent to \(kind.displayName)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cadence sends the current dictated text, compiled writing behavior, and selected text only for Respond or Edit. It does not send audio, window titles, nearby text, meetings, history, or the analytics ID.")
                        if let recipient = appModel.configuredScribeRecipient {
                            Text("Recipient: \(recipient)")
                                .font(.system(.caption, design: .monospaced))
                        }
                        if kind == .deepSeek {
                            Link(
                                "DeepSeek Privacy Policy — reviewed 10 July 2026",
                                destination: URL(string: "https://cdn.deepseek.com/policies/en-US/deepseek-privacy-policy.html")!
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textSecondary)
                    .padding(.top, 4)
                }

                HStack {
                    Spacer()
                    CadenceActionButton(
                        title: "Remove \(kind.displayName) from Cadence",
                        role: .destructive
                    ) { confirmsRemoval = true }
                }
                .confirmationDialog(
                    "Remove \(kind.displayName) from Cadence",
                    isPresented: $confirmsRemoval,
                    titleVisibility: .visible
                ) {
                    Button("Remove \(kind.displayName) from Cadence", role: .destructive) {
                        appModel.removeConfiguredScribeProvider()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(ScribeProviderDisclosure.removal(provider: kind.displayName))
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("Local Scribe diagnostics")
                    .font(.headline)
                Text("A bounded, content-free local ring records coarse setup and recovery outcomes. It is separate from analytics and is never uploaded automatically.")
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textSecondary)
                HStack {
                    CadenceActionButton(title: "Clear Scribe diagnostics", role: .destructive) {
                        appModel.clearScribeDiagnostics()
                    }
                    Spacer()
                    CadenceActionButton(title: "Export Scribe diagnostics…", role: .quiet) {
                        appModel.exportScribeDiagnostics()
                    }
                }
            }
        }
    }

    private var statusTitle: String {
        switch appModel.scribeProviderReadiness {
        case .ready: return "Provider ready"
        case .validating: return "Checking provider"
        case .disabled: return "Provider disabled"
        case .setupRequired: return "Choose a provider"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        case .configurationInvalid, .needsAttention: return "Provider needs attention"
        case .deprecated: return "Cadence update required"
        case .removed: return "Provider removed"
        }
    }

    private var statusSymbol: String {
        if case .ready = appModel.scribeProviderReadiness { return "checkmark.circle.fill" }
        if case .validating = appModel.scribeProviderReadiness { return "clock.arrow.circlepath" }
        return "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if case .ready = appModel.scribeProviderReadiness { return FlowTheme.success }
        return FlowTheme.textTertiary
    }
}
