import AppKit
import Foundation
import Testing
@testable import Cadence

@MainActor
struct PermissionFlowGuidanceTests {
    @Test
    func appDragCarriesTheExactBundleFileURLForSettings() throws {
        let appURL = URL(fileURLWithPath: "/Applications/Cadence Debug.app", isDirectory: true)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects([PermissionAppDragWriter(url: appURL)]))
        let encoded = try #require(board.string(forType: .fileURL))
        #expect(URL(string: encoded) == appURL)
        #expect(board.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] == [appURL.path])
        #expect(PermissionAppDragWriter().url == Bundle.main.bundleURL)
    }
    @Test
    func corePermissionsMapToTheExpectedPermissionFlowPanes() {
        #expect(PermissionFlowGuidanceService.pane(for: .microphone).rawValue == "microphone")
        #expect(PermissionFlowGuidanceService.pane(for: .accessibility).rawValue == "accessibility")
        #expect(PermissionFlowGuidanceService.pane(for: .inputMonitoring).rawValue == "inputMonitoring")
        #expect(PermissionFlowGuidanceService.pane(for: .screenRecording).rawValue == "screenRecording")
    }

    @Test
    func repeatedTapDoesNotReopenSettingsButAnotherStepAndLaterRetryCan() {
        var date = Date(timeIntervalSince1970: 100)
        var opened: [URL] = []
        let service = PermissionFlowGuidanceService(openURL: { opened.append($0); return true }, now: { date })
        #expect(service.present(.accessibility))
        #expect(service.present(.accessibility))
        #expect(opened.count == 1)
        #expect(service.present(.inputMonitoring))
        #expect(opened.count == 2)
        date = date.addingTimeInterval(2)
        #expect(service.present(.inputMonitoring))
        #expect(opened.count == 3)
        #expect(opened[0] == PermissionFlowGuidanceService.pane(for: .accessibility).settingsURL)
    }

    @Test
    func failedOpenIsReportedAndCanRetryImmediately() {
        var calls = 0
        let service = PermissionFlowGuidanceService(openURL: { _ in calls += 1; return calls > 1 })
        #expect(!service.present(.microphone))
        #expect(service.present(.microphone))
        #expect(calls == 2)
    }

    @Test
    func permissionJourneySkipsGrantedStepsAndNeverRequiresScreenRecording() {
        var progress = PermissionSetupProgress()
        var snapshot = PermissionsSnapshot(microphoneGranted: false, accessibilityGranted: false, inputMonitoringGranted: false, screenRecordingGranted: false)
        #expect(progress.next(in: snapshot) == .microphone)
        let beganMicrophone = progress.begin(.microphone, snapshot: snapshot)
        #expect(beganMicrophone)
        let beganWhileRequesting = progress.begin(.accessibility, snapshot: snapshot)
        #expect(!beganWhileRequesting)
        snapshot = PermissionsSnapshot(microphoneGranted: true, accessibilityGranted: false, inputMonitoringGranted: false)
        progress.reconcile(snapshot)
        #expect(progress.phase == .idle)
        #expect(progress.next(in: snapshot) == .accessibility)
        let beganAccessibility = progress.begin(.accessibility, snapshot: snapshot)
        #expect(beganAccessibility)
        progress.waiting()
        progress.reconcile(snapshot)
        #expect(progress.phase == .waiting)
        progress.notDetected()
        #expect(progress.phase == .notDetected)
        snapshot = PermissionsSnapshot(microphoneGranted: true, accessibilityGranted: true, inputMonitoringGranted: false)
        progress.reconcile(snapshot)
        #expect(progress.next(in: snapshot) == .inputMonitoring)
        snapshot = PermissionsSnapshot(microphoneGranted: true, accessibilityGranted: true, inputMonitoringGranted: true)
        #expect(progress.next(in: snapshot) == nil)
        #expect(snapshot.allRequiredGranted)
    }

    @Test
    func delayedGrantIsObservedAndStopsFurtherChecks() async {
        let monitor = PermissionSetupMonitor()
        var checks = 0
        var timeouts = 0
        await monitor.start(interval: .milliseconds(1), maximumChecks: 20, refresh: {
            checks += 1
            return checks == 9
        }, onTimeout: { timeouts += 1 }).value
        #expect(checks == 9)
        #expect(timeouts == 0)
    }

    @Test
    func retryCancelsEarlierMonitorAndTimeoutIsBounded() async {
        let monitor = PermissionSetupMonitor()
        var oldChecks = 0
        var oldTimeouts = 0
        let old = monitor.start(interval: .seconds(1), refresh: {
            oldChecks += 1
            return false
        }, onTimeout: { oldTimeouts += 1 })
        var checks = 0
        var timeouts = 0
        let replacement = monitor.start(interval: .milliseconds(1), maximumChecks: 3, refresh: {
            checks += 1
            return false
        }, onTimeout: { timeouts += 1 })
        await replacement.value
        await old.value
        #expect(oldChecks == 0)
        #expect(oldTimeouts == 0)
        #expect(checks == 3)
        #expect(timeouts == 1)
    }

    @Test
    func cancelledMonitorCannotPublishTimeout() async {
        let monitor = PermissionSetupMonitor()
        var calls = 0
        let task = monitor.start(refresh: { calls += 1; return false }, onTimeout: { calls += 1 })
        monitor.stop()
        await task.value
        #expect(calls == 0)
    }
}
