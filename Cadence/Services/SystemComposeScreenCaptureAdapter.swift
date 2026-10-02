import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import OSLog
import ScreenCaptureKit

private let composeSystemScreenCaptureLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeSystemScreenCapture")

/// The platform token is opaque to policy and never serialized. Native tokens
/// contain exactly one desktop-independent window filter, never a display.
@MainActor
final class ComposeSystemScreenWindow {
    let identity: ComposeScreenWindowIdentity
    let pixelWidth: Int
    let pixelHeight: Int
    let frame: CGRect
    fileprivate let filter: SCContentFilter?

    init(identity: ComposeScreenWindowIdentity, pixelWidth: Int, pixelHeight: Int, frame: CGRect = .zero) {
        self.identity = identity
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frame = frame
        filter = nil
    }

    fileprivate init(identity: ComposeScreenWindowIdentity, pixelWidth: Int, pixelHeight: Int, frame: CGRect, filter: SCContentFilter) {
        self.identity = identity
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frame = frame
        self.filter = filter
    }
}

@MainActor
protocol ComposeSystemScreenCapturePlatform: AnyObject {
    func hasScreenRecordingPermission() -> Bool
    func processMatches(_ identity: ApplicationProcessIdentity) -> Bool
    func resolveWindow(_ identity: ComposeScreenWindowIdentity) async throws -> ComposeSystemScreenWindow
    func captureWindow(_ window: ComposeSystemScreenWindow, authorization: @MainActor () -> Bool) async throws -> ComposeScreenImage
}

/// Unregistered native adapter. Constructing this type authorizes nothing: its
/// default authority denies every capture. A future integration must supply a
/// trusted, live, invocation-bound window authority and independently enforce
/// U8 policy (including secure/private/unsupported denial) before entry.
///
/// PID, launch date, bundle URL and exact SCWindow ownership are rechecked.
/// ScreenCaptureKit does not expose a window-incarnation token: same-process
/// window-ID reuse is NOT certified here. A trusted authority must invalidate
/// its action when its resolved window changes; there is no title/coordinate
/// heuristic, display fallback, permission request, registration, or storage.
@MainActor
final class SystemComposeScreenCaptureAdapter: ComposeScreenCapturing {
    static let maximumPixels = 4_000_000
    static let maximumImageBytes = 16_000_000
    private let platform: any ComposeSystemScreenCapturePlatform
    private let authority: @MainActor (ComposeScreenWindowIdentity) -> Bool
    private let uptimeNanoseconds: @MainActor () -> UInt64

    init(
        platform: (any ComposeSystemScreenCapturePlatform)? = nil,
        authority: @escaping @MainActor (ComposeScreenWindowIdentity) -> Bool = { _ in false },
        uptimeNanoseconds: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.platform = platform ?? ScreenCaptureKitComposePlatform()
        self.authority = authority
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    func capture(window: ComposeScreenWindowIdentity, timeoutMilliseconds: Int) async throws -> ComposeScreenImage {
        guard (1...2_000).contains(timeoutMilliseconds) else { throw ComposeScreenPlatformFailure.captureFailed }
        try validate(window)
        let startedAt = uptimeNanoseconds()
        let deadline = startedAt.addingReportingOverflow(UInt64(timeoutMilliseconds) * 1_000_000)
        let withinDeadline = { @MainActor [uptimeNanoseconds] in
            let current = uptimeNanoseconds()
            return !deadline.overflow && current >= startedAt && current < deadline.partialValue
        }
        let race = ComposeSystemScreenshotRace(withinDeadline: withinDeadline)
        let image = try await withTaskCancellationHandler {
            try await race.run(timeoutMilliseconds: timeoutMilliseconds) {
                try self.validate(window)
                let resolved = try await self.platform.resolveWindow(window)
                try self.validate(window)
                guard withinDeadline() else { throw ComposeScreenPlatformFailure.timedOut }
                guard resolved.identity == window, resolved.frame == window.expectedFrame else {
                    throw ComposeScreenPlatformFailure.targetUnavailable
                }
                guard Self.validDimensions(resolved.pixelWidth, resolved.pixelHeight) else {
                    throw ComposeScreenCaptureFailure.imageTooLarge
                }
                let image = try await self.platform.captureWindow(resolved, authorization: {
                    withinDeadline() && (try? self.validate(window)) != nil
                })
                try self.validate(window)
                guard withinDeadline() else { throw ComposeScreenPlatformFailure.timedOut }
                guard Self.validDimensions(image.width, image.height) else { throw ComposeScreenCaptureFailure.imageTooLarge }
                guard image.width == resolved.pixelWidth, image.height == resolved.pixelHeight else {
                    throw ComposeScreenPlatformFailure.captureFailed
                }
                if let cgImage = image.cgImage {
                    let bytes = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
                    guard !bytes.overflow, bytes.partialValue <= Self.maximumImageBytes else {
                        throw ComposeScreenCaptureFailure.imageTooLarge
                    }
                }
                let current = try await self.platform.resolveWindow(window)
                try self.validate(window)
                guard current.identity == resolved.identity,
                      current.frame == resolved.frame,
                      current.pixelWidth == resolved.pixelWidth, current.pixelHeight == resolved.pixelHeight else {
                    throw ComposeScreenPlatformFailure.targetUnavailable
                }
                return image
            }
        } onCancel: {
            Task { @MainActor in race.cancel() }
        }
        // The race continuation can be queued behind a revocation. This final
        // synchronous gate prevents that already-produced image escaping.
        try validate(window)
        guard withinDeadline() else { throw ComposeScreenPlatformFailure.timedOut }
        return image
    }

    private func validate(_ window: ComposeScreenWindowIdentity) throws {
        try Task.checkCancellation()
        guard window.windowID != 0, window.processIdentifier > 0,
              let expectedFrame = window.expectedFrame,
              expectedFrame.origin.x.isFinite, expectedFrame.origin.y.isFinite,
              expectedFrame.width.isFinite, expectedFrame.height.isFinite,
              expectedFrame.width > 0, expectedFrame.height > 0,
              let process = window.processIdentity, let launch = process.launchDate,
              launch.timeIntervalSinceReferenceDate.isFinite,
              process.processIdentifier == window.processIdentifier,
              process.bundleIdentifier == window.bundleIdentifier,
              !window.bundleIdentifier.isEmpty, process.bundleURL.isFileURL,
              authority(window) else { throw ComposeScreenPlatformFailure.targetUnavailable }
        guard platform.hasScreenRecordingPermission() else { throw ComposeScreenPlatformFailure.permissionDenied }
        guard platform.processMatches(process) else { throw ComposeScreenPlatformFailure.targetUnavailable }
    }

    fileprivate static func validDimensions(_ width: Int, _ height: Int) -> Bool {
        width > 0 && height > 0 && width <= 8_192 && height <= 8_192
            && width <= maximumPixels / height
    }
}

/// No permission-request API is used. System calls occur only after the
/// adapter's explicit authority and Screen Recording preflight succeed.
@MainActor
private final class ScreenCaptureKitComposePlatform: ComposeSystemScreenCapturePlatform {
    func hasScreenRecordingPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    func processMatches(_ identity: ApplicationProcessIdentity) -> Bool {
        guard let expectedLaunch = identity.launchDate,
              let app = NSRunningApplication(processIdentifier: identity.processIdentifier),
              !app.isTerminated, app.bundleIdentifier == identity.bundleIdentifier,
              app.launchDate == expectedLaunch,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == identity.bundleURL.standardizedFileURL.resolvingSymlinksInPath() else { return false }
        return true
    }

    func resolveWindow(_ identity: ComposeScreenWindowIdentity) async throws -> ComposeSystemScreenWindow {
        // 14.2 supplies explicit child-window exclusion. Older systems stay
        // unsupported instead of broadening the exact-window contract.
        guard #available(macOS 14.2, *) else { throw ComposeScreenPlatformFailure.unsupported }
        try validate(identity)
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try validate(identity)
        let matching = content.windows.filter {
            $0.windowID == identity.windowID && $0.isOnScreen
                && $0.owningApplication?.processID == identity.processIdentifier
                && $0.owningApplication?.bundleIdentifier == identity.bundleIdentifier
        }
        guard matching.count == 1, let window = matching.first,
              window.frame == identity.expectedFrame else {
            throw ComposeScreenPlatformFailure.targetUnavailable
        }
        guard window.frame.origin.x.isFinite, window.frame.origin.y.isFinite,
              window.frame.width.isFinite, window.frame.height.isFinite,
              window.frame.width > 0, window.frame.height > 0 else {
            throw ComposeScreenPlatformFailure.targetUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        filter.includeMenuBar = false
        let width = ceil(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        let height = ceil(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 8_192, height <= 8_192,
              SystemComposeScreenCaptureAdapter.validDimensions(Int(width), Int(height)) else {
            throw ComposeScreenCaptureFailure.imageTooLarge
        }
        return .init(identity: identity, pixelWidth: Int(width), pixelHeight: Int(height), frame: window.frame, filter: filter)
    }

    func captureWindow(_ window: ComposeSystemScreenWindow, authorization: @MainActor () -> Bool) async throws -> ComposeScreenImage {
        guard #available(macOS 14.2, *), let filter = window.filter else { throw ComposeScreenPlatformFailure.unsupported }
        try validate(window.identity)
        guard SystemComposeScreenCaptureAdapter.validDimensions(window.pixelWidth, window.pixelHeight) else {
            throw ComposeScreenCaptureFailure.imageTooLarge
        }
        let configuration = SCStreamConfiguration()
        configuration.width = window.pixelWidth
        configuration.height = window.pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        guard authorization() else { throw ComposeScreenPlatformFailure.targetUnavailable }
        try validate(window.identity)
        // Completion callbacks have no cancellation handle. The enclosing race
        // returns promptly and discards late completion; no image is persisted.
        let image: CGImage = try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: ComposeScreenPlatformFailure.captureFailed) }
            }
        }
        try validate(window.identity)
        return ComposeScreenImage(cgImage: image)
    }

    private func validate(_ identity: ComposeScreenWindowIdentity) throws {
        try Task.checkCancellation()
        guard hasScreenRecordingPermission() else { throw ComposeScreenPlatformFailure.permissionDenied }
        guard let process = identity.processIdentity, processMatches(process) else { throw ComposeScreenPlatformFailure.targetUnavailable }
    }
}

@MainActor
private final class ComposeSystemScreenshotRace {
    private let withinDeadline: @MainActor () -> Bool
    private var continuation: CheckedContinuation<ComposeScreenImage, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false

    init(withinDeadline: @escaping @MainActor () -> Bool) { self.withinDeadline = withinDeadline }

    func run(timeoutMilliseconds: Int, operation: @escaping @MainActor () async throws -> ComposeScreenImage) async throws -> ComposeScreenImage {
        guard !finished else { throw CancellationError() }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            work = Task {
                guard withinDeadline() else { finish(.failure(ComposeScreenPlatformFailure.timedOut)); return }
                do { finish(.success(try await operation())) }
                catch { finish(.failure(error)) }
            }
            timer = Task {
                do { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)) }
                catch { return }
                finish(.failure(ComposeScreenPlatformFailure.timedOut))
            }
        }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<ComposeScreenImage, Error>) {
        guard !finished else { return }
        let finalResult: Result<ComposeScreenImage, Error> = {
            if case .success = result, !withinDeadline() { return .failure(ComposeScreenPlatformFailure.timedOut) }
            return result
        }()
        finished = true
        timer?.cancel(); work?.cancel()
        continuation?.resume(with: finalResult)
        continuation = nil
    }
}
