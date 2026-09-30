import CoreGraphics
import Foundation
import Testing
@testable import Cadence

@MainActor
struct SystemComposeScreenCaptureAdapterTests {
    @Test
    func elapsedDeadlineRejectsSuccessEvenWhenTimerHasNotRun() async {
        let platform = Platform()
        var nanoseconds: UInt64 = 0
        platform.afterPixels = { nanoseconds = 100_000_000 }
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true }, uptimeNanoseconds: { nanoseconds })
        await #expect(throws: ComposeScreenPlatformFailure.timedOut) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.pixelReads == 1)
    }

    @Test
    func elapsedDeadlineBeforeWorkStartsAvoidsWindowEnumeration() async {
        let platform = Platform()
        var first = true
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true }, uptimeNanoseconds: {
            if first { first = false; return 0 }; return 100_000_000
        })
        await #expect(throws: ComposeScreenPlatformFailure.timedOut) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.resolved.isEmpty)
        #expect(platform.pixelReads == 0)
    }
    @Test
    func defaultAuthorityAndMissingProcessIdentityPerformNoPlatformAccess() async {
        let platform = Platform()
        let defaultAdapter = SystemComposeScreenCaptureAdapter(platform: platform)
        await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
            try await defaultAdapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        let explicit = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        var missing = window()
        missing.processIdentity = nil
        await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
            try await explicit.capture(window: missing, timeoutMilliseconds: 100)
        }
        #expect(platform.permissionChecks == 0)
        #expect(platform.resolved.isEmpty)
        #expect(platform.pixelReads == 0)
    }

    @Test
    func missingOrInvalidExpectedFramePerformsNoPlatformAccess() async {
        let platform = Platform()
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        var missing = window()
        missing.expectedFrame = nil
        var empty = window()
        empty.expectedFrame = .zero
        for target in [missing, empty] {
            await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
                try await adapter.capture(window: target, timeoutMilliseconds: 100)
            }
        }
        #expect(platform.permissionChecks == 0)
        #expect(platform.resolved.isEmpty)
    }

    @Test
    func screenPermissionAndProcessMismatchStopBeforeWindowEnumeration() async {
        let platform = Platform()
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        platform.permitted = false
        await #expect(throws: ComposeScreenPlatformFailure.permissionDenied) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        platform.permitted = true
        platform.processValid = false
        await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.resolved.isEmpty)
        #expect(platform.pixelReads == 0)
    }

    @Test
    func exactWindowIsResolvedBeforeAndAfterOneBoundedImage() async throws {
        let platform = Platform(), target = window()
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { $0 == target })
        let image = try await adapter.capture(window: target, timeoutMilliseconds: 100)
        #expect(platform.resolved == [target, target])
        #expect(platform.captured == [target])
        #expect(platform.pixelReads == 1)
        #expect(image.width == 100 && image.height == 40)
    }

    @Test
    func oversizedConfigurationIsDeniedBeforePixelsAreRead() async {
        let platform = Platform()
        platform.width = 2_001; platform.height = 2_000
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        await #expect(throws: ComposeScreenCaptureFailure.imageTooLarge) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.pixelReads == 0)
    }

    @Test
    func ownershipMismatchCannotSelectAnotherResolvedWindow() async {
        let platform = Platform()
        platform.resolvedOverride = .init(windowID: 99, processIdentifier: 44, bundleIdentifier: "other.app")
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.pixelReads == 0)
    }

    @Test
    func revocationDuringResolutionStopsBeforePixelCapture() async {
        let platform = Platform()
        var allowed = true
        platform.afterResolve = { allowed = false }
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in allowed })
        await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.pixelReads == 0)
    }

    @Test
    func platformEntryRevalidatesAuthorizationBeforeReadingPixels() async {
        let platform = Platform()
        var allowed = true
        platform.beforePixels = { allowed = false }
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in allowed })
        await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.pixelReads == 0)
    }

    @Test
    func changedProcessOrPermissionAfterCaptureCannotPublishImage() async {
        for changesPermission in [true, false] {
            let platform = Platform()
            platform.afterPixels = {
                if changesPermission { platform.permitted = false }
                else { platform.processValid = false }
            }
            let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
            let expected: ComposeScreenPlatformFailure = changesPermission ? .permissionDenied : .targetUnavailable
            await #expect(throws: expected) {
                try await adapter.capture(window: window(), timeoutMilliseconds: 100)
            }
            #expect(platform.pixelReads == 1)
        }
    }

    @Test
    func unexpectedReturnedSizeCannotBeLabeledAsExactWindowImage() async {
        let platform = Platform()
        platform.returnedWidth = 90
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        await #expect(throws: ComposeScreenPlatformFailure.captureFailed) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
    }

    @Test
    func movedWindowAfterCaptureCannotPublishImage() async {
        let platform = Platform()
        platform.afterPixels = { platform.frame.origin.x += 20 }
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.pixelReads == 1)
        #expect(platform.resolved.count == 2)
    }

    @Test
    func windowMovedBeforeCaptureCannotReadPixels() async {
        let platform = Platform()
        platform.frame.origin.x = 20
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        await #expect(throws: ComposeScreenPlatformFailure.targetUnavailable) {
            try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        #expect(platform.pixelReads == 0)
        #expect(platform.resolved.count == 1)
    }

    @Test
    func cancelledUncooperativeResolutionNeverStartsPixelCapture() async throws {
        let platform = Platform()
        platform.suspendResolution = true
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        let task = Task { try await adapter.capture(window: window(), timeoutMilliseconds: 1_000) }
        await platform.waitUntilSuspended()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        platform.resume()
        await Task.yield()
        #expect(platform.pixelReads == 0)
    }

    @Test
    func deadlineReturnsBeforeUncooperativeCaptureAndDropsLateImage() async {
        let platform = Platform()
        platform.suspendPixels = true
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        let task = Task { try await adapter.capture(window: window(), timeoutMilliseconds: 30) }
        await platform.waitUntilSuspended()
        await #expect(throws: ComposeScreenPlatformFailure.timedOut) { try await task.value }
        platform.resume()
        await Task.yield()
        #expect(platform.pixelReads == 1)
        #expect(platform.resolved.count == 1)
    }

    @Test
    func invalidBudgetAndPrecancelledTaskReadNothing() async {
        let platform = Platform()
        let adapter = SystemComposeScreenCaptureAdapter(platform: platform, authority: { _ in true })
        for timeout in [0, -1, 2_001, Int.max] {
            await #expect(throws: ComposeScreenPlatformFailure.captureFailed) {
                try await adapter.capture(window: window(), timeoutMilliseconds: timeout)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.capture(window: window(), timeoutMilliseconds: 100)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(platform.permissionChecks == 0)
        #expect(platform.resolved.isEmpty)
    }

    private func window() -> ComposeScreenWindowIdentity {
        .init(windowID: 7, processIdentifier: 42, bundleIdentifier: "test.editor", processIdentity: .init(
            processIdentifier: 42, bundleIdentifier: "test.editor", bundleURL: URL(fileURLWithPath: "/Applications/Test.app"), incarnation: UUID(), launchDate: Date(timeIntervalSince1970: 1)),
              expectedFrame: .init(x: 0, y: 0, width: 100, height: 40))
    }

    private final class Platform: ComposeSystemScreenCapturePlatform {
        var permitted = true, processValid = true
        var width = 100, height = 40
        var frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        var returnedWidth: Int?
        var resolvedOverride: ComposeScreenWindowIdentity?
        var afterResolve: (() -> Void)?
        var beforePixels: (() -> Void)?
        var afterPixels: (() -> Void)?
        var suspendResolution = false, suspendPixels = false
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var permissionChecks = 0
        private(set) var resolved: [ComposeScreenWindowIdentity] = []
        private(set) var captured: [ComposeScreenWindowIdentity] = []
        private(set) var pixelReads = 0
        func hasScreenRecordingPermission() -> Bool { permissionChecks += 1; return permitted }
        func processMatches(_ identity: ApplicationProcessIdentity) -> Bool { processValid }
        func resolveWindow(_ identity: ComposeScreenWindowIdentity) async throws -> ComposeSystemScreenWindow {
            resolved.append(identity)
            if suspendResolution { await withCheckedContinuation { continuation = $0 } }
            afterResolve?()
            return .init(identity: resolvedOverride ?? identity, pixelWidth: width, pixelHeight: height, frame: frame)
        }
        func captureWindow(_ window: ComposeSystemScreenWindow, authorization: @MainActor () -> Bool) async throws -> ComposeScreenImage {
            beforePixels?()
            guard authorization() else { throw ComposeScreenPlatformFailure.targetUnavailable }
            captured.append(window.identity); pixelReads += 1
            if suspendPixels { await withCheckedContinuation { continuation = $0 } }
            afterPixels?()
            return .init(width: returnedWidth ?? width, height: height)
        }
        func waitUntilSuspended() async { while continuation == nil { await Task.yield() } }
        func resume() { continuation?.resume(); continuation = nil }
    }
}
