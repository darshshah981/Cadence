import SwiftUI

struct ScribeProviderManagementView: View {
    @ObservedObject var appModel: AppModel
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if case .ready = appModel.scribeProviderReadiness {
                        CadenceComposeIcon(size: 20)
                    } else {
                        Image(systemName: statusSymbol)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(statusColor)
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
            .padding(12)

            if let kind = appModel.configuredScribeProviderKind {
                insetDivider

                SettingsToggleRow(
                    title: "Use \(kind.displayName)",
                    description: "Use this provider for new Compose drafts.",
                    isOn: Binding(
                        get: { appModel.configuredScribeProviderIsEnabled },
                        set: { appModel.setConfiguredScribeProviderEnabled($0) }
                    )
                )

                insetDivider

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ScribeProviderDisclosure.directDictationSummary)
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
                    .padding(.top, 8)
                } label: {
                    Text("Data sent to \(kind.displayName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FlowTheme.textPrimary)
                }
                .padding(12)

                insetDivider

                HStack(spacing: 8) {
                    Text("Provider connection")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FlowTheme.textPrimary)
                    Spacer()
                    CadenceActionButton(
                        title: "Remove",
                        role: .destructive
                    ) { confirmsRemoval = true }
                }
                .padding(12)
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

        }
    }

    private var insetDivider: some View {
        Rectangle()
            .fill(FlowTheme.border)
            .frame(height: 1)
            .padding(.leading, 12)
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
        if case .validating = appModel.scribeProviderReadiness { return "clock.arrow.circlepath" }
        return "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if case .ready = appModel.scribeProviderReadiness { return FlowTheme.textPrimary }
        return FlowTheme.textTertiary
    }
}
