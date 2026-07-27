import CoreGraphics
import Testing
@testable import Cadence

@MainActor
struct PermissionFlowGuidanceTests {
    @Test
    func corePermissionsMapToTheExpectedPermissionFlowPanes() {
        #expect(PermissionFlowGuidanceService.pane(for: .microphone).rawValue == "microphone")
        #expect(PermissionFlowGuidanceService.pane(for: .accessibility).rawValue == "accessibility")
        #expect(PermissionFlowGuidanceService.pane(for: .inputMonitoring).rawValue == "inputMonitoring")
        #expect(PermissionFlowGuidanceService.pane(for: .screenRecording).rawValue == "screenRecording")
    }

    @Test
    func launchFrameStartsAtReadablePanelSizeAndStaysWithinTheScreen() {
        let frame = PermissionFlowGuidanceService.launchFrame(
            around: CGPoint(x: 240, y: 180),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        #expect(frame == CGRect(x: 30, y: 132, width: 420, height: 96))
    }

    @Test
    func launchFrameClampsToTheVisibleScreenNearAnEdge() {
        let frame = PermissionFlowGuidanceService.launchFrame(
            around: CGPoint(x: 1_430, y: 10),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        #expect(frame == CGRect(x: 1_008, y: 12, width: 420, height: 96))
    }
}
