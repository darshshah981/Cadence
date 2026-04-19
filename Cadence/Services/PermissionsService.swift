import AVFoundation
import ApplicationServices
import AppKit
import Foundation
import IOKit.hidsystem

@MainActor
final class PermissionsService {
    private enum PrivacyPane {
        static let microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        static let inputMonitoring = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    }

    func snapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: inputMonitoringGranted()
        )
    }

    func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                openPrivacyPane(PrivacyPane.microphone)
            }
            return granted
        case .denied, .restricted:
            openPrivacyPane(PrivacyPane.microphone)
            return false
        @unknown default:
            openPrivacyPane(PrivacyPane.microphone)
            return false
        }
    }

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane(PrivacyPane.accessibility)
    }

    func requestInputMonitoringAccess() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        _ = CGRequestListenEventAccess()
        openPrivacyPane(PrivacyPane.inputMonitoring)
    }

    func appLocationSummary() -> String {
        Bundle.main.bundleURL.path
    }

    private func openPrivacyPane(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func inputMonitoringGranted() -> Bool {
        let hidAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        return CGPreflightListenEventAccess() && hidAccess == kIOHIDAccessTypeGranted
    }
}
