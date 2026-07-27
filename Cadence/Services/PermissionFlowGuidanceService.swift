import AppKit
import OSLog
import PermissionFlow

private let permissionFlowLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "PermissionFlow"
)

enum CadencePermissionGuidanceDestination {
    case microphone
    case accessibility
    case inputMonitoring
    case screenRecording
}

@MainActor
protocol PermissionGuidanceServing: AnyObject {
    func present(_ destination: CadencePermissionGuidanceDestination)
}

@MainActor
final class PermissionFlowGuidanceService: PermissionGuidanceServing {
    private static let launchPanelSize = CGSize(width: 420, height: 96)
    private static let screenInset: CGFloat = 12

    private let appURL: URL
    private let controller: PermissionFlowController

    init(appURL: URL = Bundle.main.bundleURL) {
        self.appURL = appURL
        controller = PermissionFlow.makeController(
            configuration: .init(
                requiredAppURLs: [appURL],
                promptForAccessibilityTrust: false
            )
        )
    }

    func present(_ destination: CadencePermissionGuidanceDestination) {
        let pane = Self.pane(for: destination)
        permissionFlowLogger.info("Opening guided permission flow for \(pane.rawValue, privacy: .public)")
        controller.authorize(
            pane: pane,
            suggestedAppURLs: [appURL],
            sourceFrameInScreen: Self.launchFrame(around: NSEvent.mouseLocation)
        )
    }

    static func pane(for destination: CadencePermissionGuidanceDestination) -> PermissionFlowPane {
        switch destination {
        case .microphone:
            return .microphone
        case .accessibility:
            return .accessibility
        case .inputMonitoring:
            return .inputMonitoring
        case .screenRecording:
            return .screenRecording
        }
    }

    static func launchFrame(
        around point: CGPoint,
        visibleFrame suppliedVisibleFrame: CGRect? = nil
    ) -> CGRect {
        let visibleFrame = suppliedVisibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: launchPanelSize)
        let availableSize = CGSize(
            width: max(1, visibleFrame.width - (screenInset * 2)),
            height: max(1, visibleFrame.height - (screenInset * 2))
        )
        let size = CGSize(
            width: min(launchPanelSize.width, availableSize.width),
            height: min(launchPanelSize.height, availableSize.height)
        )
        let proposedOrigin = CGPoint(
            x: point.x - (size.width * 0.5),
            y: point.y - (size.height * 0.5)
        )
        let minimumOrigin = CGPoint(
            x: visibleFrame.minX + screenInset,
            y: visibleFrame.minY + screenInset
        )
        let maximumOrigin = CGPoint(
            x: visibleFrame.maxX - screenInset - size.width,
            y: visibleFrame.maxY - screenInset - size.height
        )

        return CGRect(
            origin: CGPoint(
                x: min(max(proposedOrigin.x, minimumOrigin.x), maximumOrigin.x),
                y: min(max(proposedOrigin.y, minimumOrigin.y), maximumOrigin.y)
            ),
            size: size
        )
    }
}
