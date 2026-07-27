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
        PermissionsSnapshot(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: inputMonitoringGranted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess()
        )
    }

    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                permissionGuidance.present(.microphone)
            }
            return granted
        case .denied, .restricted:
            permissionGuidance.present(.microphone)
            return false
        @unknown default:
            permissionGuidance.present(.microphone)
            return false
        }
    }

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        permissionGuidance.present(.accessibility)
    }

    func requestInputMonitoringAccess() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = CGRequestListenEventAccess()
        permissionGuidance.present(.inputMonitoring)
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
