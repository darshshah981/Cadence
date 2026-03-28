import AVFoundation
import ApplicationServices
import AppKit
import Foundation

@MainActor
final class PermissionsService {
    private enum PrivacyPane {
        static let accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        static let inputMonitoring = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    }

    func snapshot() -> PermissionsSnapshot {
        PermissionsSnapshot(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityGranted: AXIsProcessTrusted(),
            inputMonitoringGranted: CGPreflightListenEventAccess()
        )
    }

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacyPane(PrivacyPane.accessibility)
    }

    func requestInputMonitoringAccess() {
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
}
