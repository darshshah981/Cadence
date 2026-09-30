import AppKit
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit

private let composeScreenWindowPickerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeScreenWindowPicker"
)

enum ComposeScreenWindowPickerError: Error, Equatable {
    case unavailable
    case busy
    case invalidSelection
    case targetChanged
    case timedOut
    case cancelled
}

@MainActor
protocol ComposeScreenWindowChoosing: AnyObject {
    func chooseWindow(
        actionID: UUID, capture: ScribeContextSnapshot, expectedFrame: CGRect
    ) async throws -> ComposeScreenWindowIdentity
}

/// Closed metadata from a system-picker result. No title, pixels, OCR text,
/// window contents, or display-wide fallback enters this value.
struct ComposePickedWindowMetadata: Equatable {
    let windowID: UInt32
    let processIdentifier: Int32
    let bundleIdentifier: String
    let frame: CGRect
    let isOnScreen: Bool
}

enum ComposeScreenWindowPickerPolicy {
    static func resolve(
        styleIsWindow: Bool,
        windows: [ComposePickedWindowMetadata],
        capture: ScribeContextSnapshot,
        expectedFrame: CGRect
    ) throws -> ComposeScreenWindowIdentity {
        let process = capture.applicationTarget.process
        guard capture.applicationTarget.id == capture.id,
              capture.applicationTarget.source == .scribeAccessibility,
              capture.target.processIdentifier == process.processIdentifier,
              capture.target.bundleIdentifier == process.bundleIdentifier,
              process.processIdentifier > 0,
              process.launchDate != nil,
              !process.bundleIdentifier.isEmpty,
              process.bundleURL.isFileURL else {
            throw ComposeScreenWindowPickerError.targetChanged
        }
        guard styleIsWindow, windows.count == 1, let chosen = windows.first,
              chosen.windowID != 0, chosen.isOnScreen,
              chosen.processIdentifier == process.processIdentifier,
              chosen.bundleIdentifier == process.bundleIdentifier,
              expectedFrame == chosen.frame,
              valid(chosen.frame) else {
            throw ComposeScreenWindowPickerError.invalidSelection
        }
        return .init(
            windowID: chosen.windowID,
            processIdentifier: chosen.processIdentifier,
            bundleIdentifier: chosen.bundleIdentifier,
            processIdentity: process,
            expectedFrame: chosen.frame
        )
    }

    static func valid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }
}

/// An explicit, one-shot system window choice for a pinned Compose action.
/// Constructing this type or enabling a future UI route does not capture a
/// screenshot. The caller must separately authorize screen capture, local OCR,
/// provider use, and the action's surface eligibility. No filter is retained
/// after the choice completes.
@MainActor
final class SystemComposeScreenWindowPicker: NSObject, ComposeScreenWindowChoosing,
    @preconcurrency SCContentSharingPickerObserver {
    private struct Pending {
        let actionID: UUID
        let capture: ScribeContextSnapshot
        let expectedFrame: CGRect
        let priorConfiguration: SCContentSharingPickerConfiguration
        let priorActive: Bool
        let continuation: CheckedContinuation<ComposeScreenWindowIdentity, Error>
    }

    private let picker: SCContentSharingPicker
    private let enabled: @MainActor () -> Bool
    private let currentActionID: @MainActor () -> UUID?
    private let currentCapture: @MainActor () -> ScribeContextSnapshot?
    private var pending: Pending?
    private var timeoutTask: Task<Void, Never>?

    init(
        picker: SCContentSharingPicker = .shared,
        enabled: @escaping @MainActor () -> Bool = { false },
        currentActionID: @escaping @MainActor () -> UUID? = { nil },
        currentCapture: @escaping @MainActor () -> ScribeContextSnapshot? = { nil }
    ) {
        self.picker = picker
        self.enabled = enabled
        self.currentActionID = currentActionID
        self.currentCapture = currentCapture
    }

    func chooseWindow(
        actionID: UUID, capture: ScribeContextSnapshot, expectedFrame: CGRect
    ) async throws -> ComposeScreenWindowIdentity {
        try Task.checkCancellation()
        guard #available(macOS 15.2, *) else {
            throw ComposeScreenWindowPickerError.unavailable
        }
        guard enabled() else { throw ComposeScreenWindowPickerError.unavailable }
        guard pending == nil, !picker.isActive else { throw ComposeScreenWindowPickerError.busy }
        guard ComposeScreenWindowPickerPolicy.valid(expectedFrame),
              isCurrent(actionID: actionID, capture: capture) else {
            throw ComposeScreenWindowPickerError.targetChanged
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending == nil, !picker.isActive,
                      enabled(), isCurrent(actionID: actionID, capture: capture) else {
                    continuation.resume(throwing: ComposeScreenWindowPickerError.targetChanged)
                    return
                }
                let priorConfiguration = picker.defaultConfiguration
                pending = .init(
                    actionID: actionID, capture: capture,
                    expectedFrame: expectedFrame,
                    priorConfiguration: priorConfiguration, priorActive: picker.isActive,
                    continuation: continuation
                )
                var configuration = SCContentSharingPickerConfiguration()
                configuration.allowedPickerModes = .singleWindow
                configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "Cadence"]
                configuration.allowsChangingSelectedContent = false
                picker.defaultConfiguration = configuration
                picker.add(self)
                picker.isActive = true
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(60))
                    } catch {
                        return
                    }
                    self?.finish(.failure(ComposeScreenWindowPickerError.timedOut))
                }
                picker.present(using: .window)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(ComposeScreenWindowPickerError.cancelled))
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard picker === self.picker, stream == nil else { return }
        finish(.failure(ComposeScreenWindowPickerError.cancelled))
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        guard picker === self.picker, stream == nil, let pending else { return }
        guard enabled(), isCurrent(actionID: pending.actionID, capture: pending.capture),
              processIsCurrent(pending.capture.applicationTarget.process) else {
            finish(.failure(ComposeScreenWindowPickerError.targetChanged))
            return
        }
        guard #available(macOS 15.2, *) else {
            finish(.failure(ComposeScreenWindowPickerError.unavailable))
            return
        }
        let windows = filter.includedWindows.map { window in
            ComposePickedWindowMetadata(
                windowID: window.windowID,
                processIdentifier: window.owningApplication?.processID ?? 0,
                bundleIdentifier: window.owningApplication?.bundleIdentifier ?? "",
                frame: window.frame, isOnScreen: window.isOnScreen
            )
        }
        do {
            let identity = try ComposeScreenWindowPickerPolicy.resolve(
                styleIsWindow: filter.style == .window,
                windows: windows, capture: pending.capture,
                expectedFrame: pending.expectedFrame
            )
            finish(.success(identity))
        } catch {
            finish(.failure(ComposeScreenWindowPickerError.invalidSelection))
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        // Platform errors may contain names or private metadata. Collapse them
        // to a fixed category before surfacing or logging anything.
        composeScreenWindowPickerLogger.debug("System window picker unavailable")
        finish(.failure(ComposeScreenWindowPickerError.unavailable))
    }

    private func isCurrent(actionID: UUID, capture: ScribeContextSnapshot) -> Bool {
        currentActionID() == actionID && currentCapture() == capture
    }

    private func processIsCurrent(_ process: ApplicationProcessIdentity) -> Bool {
        guard let launchDate = process.launchDate,
              let app = NSRunningApplication(processIdentifier: process.processIdentifier),
              !app.isTerminated, app.bundleIdentifier == process.bundleIdentifier,
              app.launchDate == launchDate,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
                == process.bundleURL else { return false }
        return true
    }

    private func finish(_ result: Result<ComposeScreenWindowIdentity, Error>) {
        guard let pending else { return }
        self.pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        picker.remove(self)
        picker.defaultConfiguration = pending.priorConfiguration
        picker.isActive = pending.priorActive
        pending.continuation.resume(with: result)
    }
}
