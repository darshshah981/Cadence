import SwiftUI

struct WritingEnvironmentsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Adapt Scribe to the app",
                isOn: Binding(
                    get: { appModel.scribeAppAdaptationEnabled },
                    set: { appModel.setScribeAppAdaptationEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .accessibilityIdentifier("scribe-adaptation-toggle")
            Text("Recognition stays on this Mac. A new action snapshots one behavior; changing Settings never mutates a request already in progress.")
                .font(.caption)
                .foregroundStyle(FlowTheme.textSecondary)

            if case .rejected = appModel.writingEnvironmentPreferenceState {
                recoveryCard
            } else {
                environmentCard(id: .slack)
                environmentCard(id: .claudeCode)
                environmentCard(id: .global)
            }

            if appModel.showsLegacyWritingProfileNotice {
                legacyNotice
            }
        }
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Writing environment preferences could not be loaded", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text("Scribe uses Other apps · Neutral until you restore defaults. Provider credentials, shortcuts, Dictation, meetings, and legacy profiles are untouched.")
                .font(.caption)
                .foregroundStyle(FlowTheme.textSecondary)
            CadenceActionButton(title: "Restore writing environment defaults", role: .secondary) {
                appModel.restoreWritingEnvironmentDefaults()
            }
        }
        .padding(12)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private func environmentCard(id: WritingEnvironmentID) -> some View {
        let definition = WritingEnvironmentCatalog.releaseOne.environment(id: id)!
        let enabled = preference(for: id)?.isEnabled ?? true
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.displayName)
                        .font(.headline)
                    Text(environmentDetail(id))
                        .font(.caption)
                        .foregroundStyle(FlowTheme.textTertiary)
                        .accessibilityIdentifier("scribe-environment-detail-\(id.rawValue)")
                }
                Spacer()
                if id != .global {
                    Toggle(
                        "Enable \(definition.displayName)",
                        isOn: Binding(
                            get: { enabled },
                            set: { appModel.setWritingEnvironmentEnabled($0, for: id) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            if definition.supportedBehaviorIDs.count > 1 {
                Picker(
                    "Writing behavior",
                    selection: Binding(
                        get: { preference(for: id)?.selectedBehaviorID ?? definition.defaultBehaviorID },
                        set: { appModel.setWritingEnvironmentBehavior($0, for: id) }
                    )
                ) {
                    ForEach(definition.supportedBehaviorIDs) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!enabled)
            } else {
                Text(definition.defaultBehaviorID.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(enabled ? FlowTheme.textSecondary : FlowTheme.textTertiary)
            }

            if id != .global, preference(for: id) != nil {
                HStack {
                    Spacer()
                    CadenceActionButton(title: "Reset \(definition.displayName)", role: .quiet) {
                        appModel.resetWritingEnvironment(id)
                    }
                }
            }
        }
        .padding(12)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
        .opacity(enabled ? 1 : 0.72)
    }

    private var legacyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Writing environments now use release-tested Slack and Claude Code behaviors. Your previous writing profiles were kept for rollback but were not applied automatically.")
                .font(.caption)
                .foregroundStyle(FlowTheme.textSecondary)
            HStack {
                CadenceActionButton(title: "Keep legacy profiles", role: .quiet) {
                    appModel.dismissLegacyWritingProfileNotice()
                }
                Spacer()
                CadenceActionButton(title: "Remove legacy writing profiles", role: .destructive) {
                    appModel.removeLegacyWritingProfiles()
                }
            }
        }
        .padding(12)
        .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
    }

    private func preference(for id: WritingEnvironmentID) -> WritingEnvironmentPreference? {
        guard case let .valid(preferences) = appModel.writingEnvironmentPreferenceState else {
            return nil
        }
        return preferences.first { $0.environmentID == id }
    }

    private func environmentDetail(_ id: WritingEnvironmentID) -> String {
        switch id {
        case .slack:
            return "Exact Slack app identity · defaults to Neutral"
        case .claudeCode:
            return "Certified Code prompt in Claude Desktop only · other Claude surfaces use Other apps"
        case .global:
            return "Total fallback for unknown, disabled, ambiguous, or unsupported targets"
        }
    }
}
