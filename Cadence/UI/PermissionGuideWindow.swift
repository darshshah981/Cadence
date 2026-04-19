import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PermissionGuideKind {
    case accessibility
    case inputMonitoring

    var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        }
    }

    var settingsName: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        }
    }
}

@MainActor
final class PermissionGuideWindowController: NSWindowController {
    private var hostingController: NSHostingController<PermissionGuideView>?

    convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Grant Cadence Access"
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

    func show(kind: PermissionGuideKind, appURL: URL) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Cadence"
        let view = PermissionGuideView(
            kind: kind,
            appURL: appURL,
            appName: appName,
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
        window?.title = "Grant \(appName) Access"
        window?.contentViewController = hostingController
        window?.setContentSize(NSSize(width: 380, height: 340))
        window?.center()
        showWindow(nil)
        window?.orderFrontRegardless()
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

struct PermissionGuideView: View {
    let kind: PermissionGuideKind
    let appURL: URL
    let appName: String
    let onRevealApp: () -> Void
    let onRestartApp: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                AppBundleDragView(appURL: appURL)
                    .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Grant \(appName)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)

                    Text(kind.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FlowTheme.accent)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                PermissionGuideStep(number: 1, text: "Find \(appName) in System Settings.")
                PermissionGuideStep(number: 2, text: "Turn it on for \(kind.settingsName).")
                PermissionGuideStep(number: 3, text: "If it is missing, drag this \(appName) icon into the app list.")
                PermissionGuideStep(number: 4, text: "Come back here and click Restart \(appName).")
            }

            Text("Use this restart button after granting access. The macOS Quit & Reopen prompt can miss menu bar apps.")
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

            HStack(spacing: 8) {
                Button("Reveal App", action: onRevealApp)
                    .buttonStyle(.bordered)

                Button("Restart \(appName)", action: onRestartApp)
                    .buttonStyle(.bordered)

                Spacer()

                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FlowTheme.background)
    }
}

private struct PermissionGuideStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FlowTheme.background)
                .frame(width: 20, height: 20)
                .background(FlowTheme.accent, in: Circle())

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(FlowTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
