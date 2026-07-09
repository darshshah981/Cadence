import AppKit
import OSLog

private let appDelegateLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "AppDelegate"
)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var openMainWindow: (() -> Void)? {
        didSet {
            guard pendingMainWindowOpen else { return }
            pendingMainWindowOpen = false
            DispatchQueue.main.async {
                requestMainWindowOpen(reason: "pending-registration")
            }
        }
    }

    private static var pendingMainWindowOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        Self.requestMainWindowOpen(reason: "launch")
        Self.retryMainWindowOpenAfterLaunch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate()
        Self.requestMainWindowOpen(reason: "reopen")
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.hasVisibleMainWindow else { return }
        Self.requestMainWindowOpen(reason: "became-active")
    }

    private static var hasVisibleMainWindow: Bool {
        NSApp.windows.contains { window in
            window.title == "Cadence" && window.isVisible
        }
    }

    private static func requestMainWindowOpen(reason: String) {
        guard let openMainWindow else {
            pendingMainWindowOpen = true
            appDelegateLogger.info("Deferred main window open reason=\(reason, privacy: .public)")
            return
        }

        appDelegateLogger.info("Opening main window reason=\(reason, privacy: .public)")
        openMainWindow()
    }

    private static func retryMainWindowOpenAfterLaunch() {
        for delay in [0.25, 0.75, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !Self.hasVisibleMainWindow else { return }
                Self.requestMainWindowOpen(reason: "launch-retry-\(delay)")
            }
        }
    }
}
