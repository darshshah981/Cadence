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
    func launchFrameIsCenteredOnThePermissionAction() {
        let frame = PermissionFlowGuidanceService.launchFrame(
            around: CGPoint(x: 240, y: 180)
        )

        #expect(frame == CGRect(x: 224, y: 164, width: 32, height: 32))
    }
}
