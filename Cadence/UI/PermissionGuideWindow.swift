import AppKit
import SwiftUI

@MainActor
final class PermissionWizardState: ObservableObject {
    @Published var permissions: PermissionsSnapshot

    init(permissions: PermissionsSnapshot) {
        self.permissions = permissions
    }
}

@MainActor
final class PermissionGuideWindowController: NSWindowController {
    private var hostingController: NSHostingController<PermissionWizardView>?
    private var state: PermissionWizardState?

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Up Cadence"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 460, height: 460)
        panel.maxSize = NSSize(width: 460, height: 460)

        self.init(window: panel)
    }

    func show(
        permissions: PermissionsSnapshot,
        appURL: URL,
        onRequestMicrophone: @escaping () -> Void,
        onRequestAccessibility: @escaping () -> Void,
        onRequestInputMonitoring: @escaping () -> Void,
        onRefresh: @escaping () -> Void
    ) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Cadence"
        let state = PermissionWizardState(permissions: permissions)
        self.state = state
        let view = PermissionWizardView(
            state: state,
            appURL: appURL,
            appName: appName,
            onRequestMicrophone: onRequestMicrophone,
            onRequestAccessibility: onRequestAccessibility,
            onRequestInputMonitoring: onRequestInputMonitoring,
            onRefresh: onRefresh,
            onRestartApp: {
                Self.relaunch(appURL: appURL)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )

        let hostingController = NSHostingController(rootView: view)
        self.hostingController = hostingController
        window?.title = "Set Up \(appName)"
        window?.contentViewController = hostingController
        window?.setContentSize(NSSize(width: 460, height: 460))
        window?.center()
        showWindow(nil)
        window?.orderFrontRegardless()
    }

    func updatePermissions(_ permissions: PermissionsSnapshot) {
        state?.permissions = permissions
    }

    private static func relaunch(appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.1; done
            /usr/bin/open "$1"
            """,
            String(ProcessInfo.processInfo.processIdentifier),
            appURL.path
        ]
        try? process.run()
        NSApp.terminate(nil)
    }
}

private struct PermissionWizardView: View {
    @ObservedObject var state: PermissionWizardState

    let appURL: URL
    let appName: String
    let onRequestMicrophone: () -> Void
    let onRequestAccessibility: () -> Void
    let onRequestInputMonitoring: () -> Void
    let onRefresh: () -> Void
    let onRestartApp: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            instruction
            permissionList
            Spacer(minLength: 0)
            actions
        }
        .padding(18)
        .frame(width: 460, height: 460, alignment: .topLeading)
        .background(FlowTheme.background)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .scaledToFit()
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text("Set up \(appName)")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .lineLimit(1)

                Text(state.permissions.allRequiredGranted ? "Everything is ready." : "Grant the access Cadence needs.")
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 64)
    }

    private var instruction: some View {
        Text(activeInstruction)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(FlowTheme.textPrimary)
            .lineLimit(3)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlowTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FlowTheme.accentBorder, lineWidth: 1)
            )
    }

    private var permissionList: some View {
        VStack(spacing: 0) {
            PermissionWizardRow(
                title: "Microphone",
                description: "Allow recording when you dictate.",
                isGranted: state.permissions.microphoneGranted,
                actionTitle: "Grant",
                action: onRequestMicrophone
            )
            divider
            PermissionWizardRow(
                title: "Accessibility",
                description: "Allow Cadence to insert text into the focused app.",
                isGranted: state.permissions.accessibilityGranted,
                actionTitle: "Grant",
                action: onRequestAccessibility
            )
            divider
            PermissionWizardRow(
                title: "Input Monitoring",
                description: "Allow global shortcuts to work while other apps are active.",
                isGranted: state.permissions.inputMonitoringGranted,
                actionTitle: "Grant",
                action: onRequestInputMonitoring
            )
        }
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }

    private var actions: some View {
        HStack(spacing: 8) {
            CadenceActionButton(title: "Check Again", role: .secondary, action: onRefresh)
            CadenceActionButton(title: "Restart \(appName)", role: .secondary, action: onRestartApp)
            Spacer()
            CadenceActionButton(title: "Done", role: .primary, isDefault: true, action: onClose)
        }
        .controlSize(.regular)
        .padding(12)
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(FlowTheme.border)
            .frame(height: 1)
            .padding(.leading, 12)
    }

    private var activeInstruction: String {
        if !state.permissions.microphoneGranted {
            return "Choose Grant. Cadence will open the correct macOS permission screen for you."
        }

        if !state.permissions.accessibilityGranted {
            return "Choose Grant, then use the floating Cadence card beside System Settings."
        }

        if !state.permissions.inputMonitoringGranted {
            return "Choose Grant, then use the floating Cadence card beside System Settings."
        }

        return "All permissions are enabled. Restart Cadence if macOS asked you to relaunch."
    }
}

private struct PermissionWizardRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "arrow.up.right.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isGranted ? FlowTheme.success : FlowTheme.textSecondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            if !isGranted {
                CadenceActionButton(title: actionTitle, role: .secondary, action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(minHeight: 66)
    }
}
