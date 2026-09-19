import AVFoundation
import ApplicationServices
import AppKit
import Foundation
import IOKit.hidsystem

@MainActor
protocol DictationPermissionsServing: AnyObject {
    func snapshot() -> PermissionsSnapshot
    func requestMicrophoneAccess() async -> Bool
}

@MainActor
enum ScribePermissionGate {
    static func evaluate(using service: DictationPermissionsServing) async -> PermissionsSnapshot {
        var permissions = service.snapshot()
        if !permissions.microphoneGranted {
            _ = await service.requestMicrophoneAccess()
            permissions = service.snapshot()
        }
        return permissions
    }
}

@MainActor
final class PermissionsService: DictationPermissionsServing {
    private let permissionGuidance: any PermissionGuidanceServing

    init(permissionGuidance: (any PermissionGuidanceServing)? = nil) {
        self.permissionGuidance = permissionGuidance ?? PermissionFlowGuidanceService()
    }

    func snapshot() -> PermissionsSnapshot {
        coreSnapshot(screenRecordingGranted: CGPreflightScreenCaptureAccess())
    }

    func coreSnapshot(screenRecordingGranted: Bool) -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: inputMonitoringGranted(),
            screenRecordingGranted: screenRecordingGranted
        )
    }

    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            // One prompt. If the user declines the native dialog we do not
            // immediately shove System Settings at them; the setup UI offers
            // a deliberate "Open System Settings" action instead.
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// True when the native TCC prompt is still available for the microphone
    /// (versus a prior explicit denial that requires System Settings).
    var microphonePromptAvailable: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    var inputMonitoringPromptAvailable: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown
    }

    func requestInputMonitoringPrompt() {
        _ = CGRequestListenEventAccess()
    }

    @discardableResult
    func openSettings(for permission: CorePermission) -> Bool {
        switch permission {
        case .microphone: return permissionGuidance.present(.microphone)
        case .accessibility: return permissionGuidance.present(.accessibility)
        case .inputMonitoring: return permissionGuidance.present(.inputMonitoring)
        }
    }

    func requestScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            permissionGuidance.present(.screenRecording)
        }
        return granted
    }

    func appLocationSummary() -> String {
        Bundle.main.bundleURL.path
    }

    private func inputMonitoringGranted() -> Bool {
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        return CGPreflightListenEventAccess() && hidAccess == kIOHIDAccessTypeGranted
    }
}

/// Polls only during a user-initiated handoff, then stops on grant, cancellation,
/// or a bounded timeout. No System Settings AX calls and no background idle loop.
@MainActor
final class PermissionSetupMonitor {
    private var task: Task<Void, Never>?
    deinit { task?.cancel() }

    @discardableResult
    func start(
        interval: Duration = .milliseconds(500),
        maximumChecks: Int = 240,
        refresh: @escaping @MainActor () async -> Bool,
        onTimeout: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        task?.cancel()
        let next = Task { @MainActor in
            for index in 0..<maximumChecks {
                guard !Task.isCancelled else { return }
                if await refresh() { return }
                guard !Task.isCancelled else { return }
                if index < maximumChecks - 1 {
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
            guard !Task.isCancelled else { return }
            onTimeout()
        }
        task = next
        return next
    }

    func stop() { task?.cancel(); task = nil }
}
