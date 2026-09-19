import AppKit
import OSLog
import PermissionFlow

private let permissionFlowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "PermissionFlow"
)

enum CadencePermissionGuidanceDestination: Equatable {
    case microphone
    case accessibility
    case inputMonitoring
    case screenRecording
}

/// A file reference to the running app, not an image or a copied app bundle.
final class PermissionAppDragWriter: NSObject, NSPasteboardWriting {
    let url: URL

    init(url: URL = Bundle.main.bundleURL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL: return url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"): return [url.path]
        default: return nil
        }
    }
}

@MainActor
protocol PermissionGuidanceServing: AnyObject {
    @discardableResult func present(_ destination: CadencePermissionGuidanceDestination) -> Bool
}

/// Keeps the library's pane mapping, without its floating panel or cross-process
/// Accessibility/window tracking. Cadence owns the guidance and progress inline.
@MainActor
final class PermissionFlowGuidanceService: PermissionGuidanceServing {
    private let openURL: (URL) -> Bool
    private let now: () -> Date
    private var lastOpen: (destination: CadencePermissionGuidanceDestination, date: Date)?

    init(
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.openURL = openURL
        self.now = now
    }

    @discardableResult
    func present(_ destination: CadencePermissionGuidanceDestination) -> Bool {
        let date = now()
        if let lastOpen, lastOpen.destination == destination,
           date.timeIntervalSince(lastOpen.date) < 1 { return true }
        let opened = openURL(Self.pane(for: destination).settingsURL)
        if opened { lastOpen = (destination, date) }
        permissionFlowLogger.info("Permission settings handoff succeeded: \(opened, privacy: .public)")
        return opened
    }

    static func pane(for destination: CadencePermissionGuidanceDestination) -> PermissionFlowPane {
        switch destination {
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        case .screenRecording: return .screenRecording
        }
    }
}
