import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Up Cadence"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

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
            onRevealApp: {
                NSWorkspace.shared.activateFileViewerSelecting([appURL])
            },
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
        window?.setContentSize(NSSize(width: 430, height: 520))
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
    let onRevealApp: () -> Void
    let onRestartApp: () -> Void
    let onClose: () -> Void

    @State private var iconNudge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            instruction
            permissionList
            appPath
            actions
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FlowTheme.background)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                iconNudge = true
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                AppBundleDragView(appURL: appURL)
                    .frame(width: 66, height: 66)
                    .offset(x: iconNudge ? 8 : 0, y: iconNudge ? -3 : 0)
                    .scaleEffect(iconNudge ? 1.04 : 1)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FlowTheme.background)
                    .frame(width: 24, height: 24)
                    .background(FlowTheme.accent, in: Circle())
                    .offset(x: 5, y: 5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Set up \(appName)")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(state.permissions.allRequiredGranted ? "Everything is ready." : "Grant the access Cadence needs.")
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textSecondary)
            }
        }
    }

    private var instruction: some View {
        Text(activeInstruction)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(FlowTheme.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
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
                actionTitle: "Request",
                action: onRequestMicrophone
            )
            divider
            PermissionWizardRow(
                title: "Accessibility",
                description: "Allow Cadence to insert text into the focused app.",
                isGranted: state.permissions.accessibilityGranted,
                actionTitle: "Open Settings",
                action: onRequestAccessibility
            )
            divider
            PermissionWizardRow(
                title: "Input Monitoring",
                description: "Allow global shortcuts to work while other apps are active.",
                isGranted: state.permissions.inputMonitoringGranted,
                actionTitle: "Open Settings",
                action: onRequestInputMonitoring
            )
        }
        .background(FlowTheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FlowTheme.border, lineWidth: 1)
        )
    }

    private var appPath: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("If Cadence is missing from System Settings, drag the app icon above into the list.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(appURL.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlowTheme.textTertiary)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Reveal App", action: onRevealApp)
                .buttonStyle(.bordered)

            Button("Check Again", action: onRefresh)
                .buttonStyle(.bordered)

            Button("Restart \(appName)", action: onRestartApp)
                .buttonStyle(.bordered)

            Spacer()

            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
    }

    private var divider: some View {
        Rectangle()
            .fill(FlowTheme.border)
            .frame(height: 1)
            .padding(.leading, 12)
    }

    private var activeInstruction: String {
        if !state.permissions.microphoneGranted {
            return "Start with Microphone. Click Request, then allow Cadence when macOS asks."
        }

        if !state.permissions.accessibilityGranted {
            return "Open Accessibility, turn on Cadence, or drag this Cadence icon into the list if it is missing."
        }

        if !state.permissions.inputMonitoringGranted {
            return "Open Input Monitoring, turn on Cadence, or drag this Cadence icon into the list if it is missing."
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
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isGranted ? FlowTheme.success : FlowTheme.error)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FlowTheme.textPrimary)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !isGranted {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(minHeight: 66)
    }
}

private struct AppBundleDragView: NSViewRepresentable {
    let appURL: URL

    func makeNSView(context: Context) -> DraggableAppIconView {
        DraggableAppIconView(appURL: appURL)
    }

    func updateNSView(_ nsView: DraggableAppIconView, context: Context) {
        nsView.appURL = appURL
    }
}

private final class DraggableAppIconView: NSImageView {
    var appURL: URL {
        didSet {
            image = NSWorkspace.shared.icon(forFile: appURL.path)
        }
    }

    init(appURL: URL) {
        self.appURL = appURL
        super.init(frame: .zero)
        image = NSWorkspace.shared.icon(forFile: appURL.path)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(appURL.absoluteString, forType: .fileURL)
        pasteboardItem.setString(appURL.path, forType: .string)

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
}

extension DraggableAppIconView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
