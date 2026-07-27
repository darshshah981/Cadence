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

    static func launchFrame(around point: CGPoint) -> CGRect {
        CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
    }
}
