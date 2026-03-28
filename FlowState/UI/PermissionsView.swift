import SwiftUI

struct PermissionsView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(.headline)

            permissionRow(
                title: "Microphone",
                granted: appModel.permissions.microphoneGranted,
                actionTitle: "Request",
                action: appModel.requestMicrophoneAccess
            )

            permissionRow(
                title: "Accessibility",
                granted: appModel.permissions.accessibilityGranted,
                actionTitle: "Open Prompt",
                action: appModel.requestAccessibilityAccess
            )

            permissionRow(
                title: "Input Monitoring",
                granted: appModel.permissions.inputMonitoringGranted,
                actionTitle: "Open Settings",
                action: appModel.requestInputMonitoringAccess
            )

            Text("If macOS still shows the wrong status, remove old FlowState entries in Privacy & Security and enable the exact app bundle you launched from this path:\n\(Bundle.main.bundleURL.path)")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func permissionRow(title: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .primary)

            Spacer()

            if !granted {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .font(.system(size: 12.5))
    }
}
