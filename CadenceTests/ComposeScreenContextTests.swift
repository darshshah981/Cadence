import Foundation
import CoreGraphics
import Testing
@testable import Cadence

@MainActor
struct ComposeScreenContextTests {
    @Test
    func missingFocusedWindowFrameStopsBeforeCaptureOrOCR() async {
        let fixture = Fixture()
        var window = fixture.target.window
        window.expectedFrame = nil
        let target = ComposeScreenContextTarget(action: fixture.target.action, window: window)
        #expect(await fixture.service.capture(target: target) == .unavailable(.invalidTarget))
        #expect(await fixture.capture.callCount == 0)
        #expect(await fixture.ocr.callCount == 0)
    }

    @Test
    func elapsedDeadlineAtQueuedPublicationRejectsOtherwiseValidSnapshot() async {
        let fixture = Fixture()
        var nanoseconds: UInt64 = 0
        var budget = ComposeScreenCaptureBudget()
        budget.timeoutMilliseconds = 500
        let service = ComposeScreenContextService(captureAdapter: fixture.capture, ocr: fixture.ocr, verifier: fixture.verifier,
            policy: { fixture.policy }, permissions: { fixture.permissions }, currentTarget: { fixture.currentTarget }, now: { fixture.now },
            beforePublication: { nanoseconds = 500_000_000 }, uptimeNanoseconds: { nanoseconds })
        #expect(await service.capture(target: fixture.target, budget: budget) == .unavailable(.timedOut))
        #expect(await fixture.ocr.callCount == 1)
    }

    @Test
    func elapsedDeadlineBeforeScheduledWorkMakesNoPlatformCalls() async {
        let fixture = Fixture()
        var firstClockRead = true
        let service = ComposeScreenContextService(captureAdapter: fixture.capture, ocr: fixture.ocr, verifier: fixture.verifier,
            policy: { fixture.policy }, permissions: { fixture.permissions }, currentTarget: { fixture.currentTarget }, now: { fixture.now },
            uptimeNanoseconds: {
                if firstClockRead { firstClockRead = false; return 0 }
                return 500_000_000
            })
        #expect(await service.capture(target: fixture.target) == .unavailable(.timedOut))
        #expect(await fixture.capture.callCount == 0)
        #expect(await fixture.verifier.callCount == 0)
    }
    @Test
    func revocationAtQueuedResultPublicationDiscardsCompletedSnapshot() async {
        let fixture = Fixture()
        var publicationReached = false
        let service = ComposeScreenContextService(captureAdapter: fixture.capture, ocr: fixture.ocr, verifier: fixture.verifier,
            policy: { fixture.policy }, permissions: { fixture.permissions }, currentTarget: { fixture.currentTarget }, now: { fixture.now },
            beforePublication: { publicationReached = true; fixture.policy.isEnabled = false })
        #expect(await service.capture(target: fixture.target) == .unavailable(.policy(.disabled)))
        #expect(publicationReached)
        #expect(await fixture.ocr.callCount == 1)
    }

    @Test
    func changedActionAtQueuedResultPublicationDiscardsCompletedSnapshot() async {
        let fixture = Fixture()
        let service = ComposeScreenContextService(captureAdapter: fixture.capture, ocr: fixture.ocr, verifier: fixture.verifier,
            policy: { fixture.policy }, permissions: { fixture.permissions }, currentTarget: { fixture.currentTarget }, now: { fixture.now },
            beforePublication: { fixture.currentTarget = nil })
        #expect(await service.capture(target: fixture.target) == .unavailable(.targetChanged))
        #expect(await fixture.ocr.callCount == 1)
    }
    @Test
    func capturesOnlyPinnedWindowAndKeepsOnlyBoundedLocalLines() async {
        let fixture = Fixture()
        await fixture.ocr.setResult(.init(lines: [line("Visible reply")], isClipped: false))
        guard case let .captured(snapshot) = await fixture.service.capture(target: fixture.target) else {
            Issue.record("Expected bounded OCR snapshot")
            return
        }
        #expect(await fixture.capture.windows == [fixture.target.window])
        #expect(snapshot.screenText == "Visible reply")
        #expect(snapshot.lines.map(\.text) == ["Visible reply"])
        #expect(snapshot.limitations.isEmpty)
    }

    @Test
    func ambiguousColumnResultCarriesAVisibleLimitation() async {
        let fixture = Fixture()
        await fixture.ocr.setResult(.init(
            lines: [line("Left item"), line("Right item")],
            isClipped: false, hasAmbiguousColumns: true
        ))
        guard case let .captured(snapshot) = await fixture.service.capture(target: fixture.target) else {
            Issue.record("Expected a bounded OCR snapshot")
            return
        }
        #expect(snapshot.limitations.contains(.ambiguousColumns))
        #expect(!snapshot.limitations.contains(.clipped))
    }

    @Test
    func livePolicyIsReadAgainAfterEveryAsynchronousBoundary() async {
        let afterVerifier = Fixture()
        await afterVerifier.verifier.suspend(at: 1)
        let verifierTask = Task { await afterVerifier.service.capture(target: afterVerifier.target) }
        await afterVerifier.verifier.waitForCall(1)
        afterVerifier.policy.isEnabled = false
        await afterVerifier.verifier.resolvePending()
        #expect(await verifierTask.value == .unavailable(.policy(.disabled)))
        #expect(await afterVerifier.capture.callCount == 0)

        let afterCapture = Fixture()
        await afterCapture.capture.suspendNextCall()
        let captureTask = Task { await afterCapture.service.capture(target: afterCapture.target) }
        await afterCapture.capture.waitForCall(1)
        afterCapture.policy.isEnabled = false
        await afterCapture.capture.resolvePending()
        #expect(await captureTask.value == .unavailable(.policy(.disabled)))
        #expect(await afterCapture.ocr.callCount == 0)

        let afterOCR = Fixture()
        await afterOCR.ocr.suspendNextCall()
        let ocrTask = Task { await afterOCR.service.capture(target: afterOCR.target) }
        await afterOCR.ocr.waitForCall(1)
        afterOCR.permissions.screenRecording = false
        await afterOCR.ocr.resolvePending()
        #expect(await ocrTask.value == .unavailable(.policy(.missingPlatformPermission)))
    }

    @Test
    func currentActionIsReadAgainAfterCaptureAndLateResultCannotCreateSnapshot() async {
        let fixture = Fixture()
        await fixture.capture.suspendNextCall()
        let task = Task { await fixture.service.capture(target: fixture.target) }
        await fixture.capture.waitForCall(1)
        fixture.currentTarget = nil
        await fixture.capture.resolvePending()
        #expect(await task.value == .unavailable(.targetChanged))
        #expect(await fixture.ocr.callCount == 0)
    }

    @Test
    func totalDeadlineReturnsWithoutWaitingForHungVerifierOrAdapter() async {
        var budget = ComposeScreenCaptureBudget()
        budget.timeoutMilliseconds = 30
        let verifierFixture = Fixture()
        await verifierFixture.verifier.suspend(at: 1)
        let verifierTask = Task { await verifierFixture.service.capture(target: verifierFixture.target, budget: budget) }
        await verifierFixture.verifier.waitForCall(1)
        #expect(await verifierTask.value == .unavailable(.timedOut))
        await verifierFixture.verifier.resolvePending()

        let captureFixture = Fixture()
        await captureFixture.capture.suspendNextCall()
        let captureTask = Task { await captureFixture.service.capture(target: captureFixture.target, budget: budget) }
        await captureFixture.capture.waitForCall(1)
        #expect(await captureTask.value == .unavailable(.timedOut))
        await captureFixture.capture.resolvePending()
        try? await Task.sleep(for: .milliseconds(5))
        #expect(await captureFixture.ocr.callCount == 0)

        let ocrFixture = Fixture()
        await ocrFixture.ocr.suspendNextCall()
        let ocrTask = Task { await ocrFixture.service.capture(target: ocrFixture.target, budget: budget) }
        await ocrFixture.ocr.waitForCall(1)
        #expect(await ocrTask.value == .unavailable(.timedOut))
        await ocrFixture.ocr.resolvePending()
    }

    @Test
    func cancellationWinsAndIgnoresLateUncooperativeCapture() async {
        let fixture = Fixture()
        await fixture.capture.suspendNextCall()
        let task = Task { await fixture.service.capture(target: fixture.target) }
        await fixture.capture.waitForCall(1)
        task.cancel()
        #expect(await task.value == .unavailable(.cancelled))
        await fixture.capture.resolvePending()
        try? await Task.sleep(for: .milliseconds(5))
        #expect(await fixture.ocr.callCount == 0)
    }

    @Test
    func preservesWholeUnicodeLinesAndNeverRetainsMoreTextThanByteBudget() async {
        let fixture = Fixture()
        await fixture.ocr.setResult(.init(lines: [line("é"), line("é")], isClipped: false))
        var budget = ComposeScreenCaptureBudget()
        budget.maximumUTF8Bytes = 3
        guard case let .captured(snapshot) = await fixture.service.capture(target: fixture.target, budget: budget) else {
            Issue.record("Expected first complete Unicode line")
            return
        }
        #expect(snapshot.screenText == "é")
        #expect(snapshot.screenText.utf8.count == 2)
        #expect(snapshot.lines.map(\.text) == ["é"])
        #expect(snapshot.limitations.contains(.byteLimit))
    }

    @Test
    func hugeOrMalformedOCRLinesNeverEscapeTheBoundedSnapshot() async {
        let huge = Fixture()
        await huge.ocr.setResult(.init(lines: [line(String(repeating: "x", count: 20))], isClipped: false))
        var budget = ComposeScreenCaptureBudget()
        budget.maximumUTF8Bytes = 8
        #expect(await huge.service.capture(target: huge.target, budget: budget) == .unavailable(.contextTooLarge))

        let malformed = Fixture()
        let bad = ComposeOCRLine(text: "unsafe", confidence: .infinity, boundingBox: .zero)
        await malformed.ocr.setResult(.init(lines: [bad], isClipped: false))
        #expect(await malformed.service.capture(target: malformed.target) == .unavailable(.recognitionFailed))
    }

    private func line(_ text: String, confidence: Float = 0.95) -> ComposeOCRLine {
        .init(text: text, confidence: confidence, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
    }

    @MainActor
    private final class Fixture {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let target: ComposeScreenContextTarget
        let capture: ScreenCaptureFake
        let ocr: OCRFake
        let verifier: ScreenTargetVerifierFake
        var currentTarget: ComposeScreenContextTarget?
        var policy: ScribeContextPolicySnapshot
        var permissions = ScribeContextPlatformPermissions(screenRecording: true)
        lazy var service = ComposeScreenContextService(
            captureAdapter: capture, ocr: ocr, verifier: verifier,
            policy: { [unowned self] in self.policy }, permissions: { [unowned self] in self.permissions },
            currentTarget: { [unowned self] in self.currentTarget }, now: { [unowned self] in self.now }
        )

        init() {
            let action = ScribeContextActionBinding(actionID: UUID(), captureID: UUID(), target: .init(processIdentifier: 41, bundleIdentifier: "com.example.Editor"), opaqueSurfaceID: "synthetic-window", eligibility: .eligible)
            target = .init(action: action, window: .init(windowID: 9, processIdentifier: 41, bundleIdentifier: "com.example.Editor",
                                                    expectedFrame: .init(x: 0, y: 0, width: 100, height: 40)))
            currentTarget = target
            capture = ScreenCaptureFake(image: .init(width: 100, height: 40))
            ocr = OCRFake(result: .init(lines: [ComposeOCRLine(text: "default", confidence: 0.95, boundingBox: .init(x: 0, y: 0, width: 1, height: 1))], isClipped: false))
            verifier = ScreenTargetVerifierFake()
            policy = .init(isEnabled: true, captureGrants: [.init(id: UUID(), scope: .application(bundleIdentifier: "com.example.Editor"), categories: [.screenshot], window: .init(acceptedAt: now.addingTimeInterval(-1), expiresAt: now.addingTimeInterval(60)))])
        }
    }
}

private actor ScreenCaptureFake: ComposeScreenCapturing {
    private let image: ComposeScreenImage
    private var pending: CheckedContinuation<ComposeScreenImage, any Error>?
    private var observer: CheckedContinuation<Void, Never>?
    private var shouldSuspend = false
    private(set) var windows: [ComposeScreenWindowIdentity] = []
    private(set) var callCount = 0
    init(image: ComposeScreenImage) { self.image = image }
    func capture(window: ComposeScreenWindowIdentity, timeoutMilliseconds _: Int) async throws -> ComposeScreenImage {
        windows.append(window); callCount += 1; observer?.resume(); observer = nil
        if shouldSuspend { shouldSuspend = false; return try await withCheckedThrowingContinuation { pending = $0 } }
        return image
    }
    func suspendNextCall() { shouldSuspend = true }
    func waitForCall(_ count: Int) async { if callCount < count { await withCheckedContinuation { observer = $0 } } }
    func resolvePending() { pending?.resume(returning: image); pending = nil }
}

private actor OCRFake: ComposeScreenOCRRecognizing {
    private var result: ComposeOCRResult
    private var pending: CheckedContinuation<ComposeOCRResult, any Error>?
    private var observer: CheckedContinuation<Void, Never>?
    private var shouldSuspend = false
    private(set) var callCount = 0
    init(result: ComposeOCRResult) { self.result = result }
    func recognize(image _: ComposeScreenImage, maximumLines _: Int, timeoutMilliseconds _: Int) async throws -> ComposeOCRResult {
        callCount += 1; observer?.resume(); observer = nil
        if shouldSuspend { shouldSuspend = false; return try await withCheckedThrowingContinuation { pending = $0 } }
        return result
    }
    func setResult(_ result: ComposeOCRResult) { self.result = result }
    func suspendNextCall() { shouldSuspend = true }
    func waitForCall(_ count: Int) async { if callCount < count { await withCheckedContinuation { observer = $0 } } }
    func resolvePending() { pending?.resume(returning: result); pending = nil }
}

private actor ScreenTargetVerifierFake: ComposeScreenTargetVerifying {
    private var suspendedCall: Int?
    private var pending: CheckedContinuation<Bool, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    func verify(_: ComposeScreenContextTarget) async -> Bool {
        callCount += 1; observer?.resume(); observer = nil
        if suspendedCall == callCount { return await withCheckedContinuation { pending = $0 } }
        return true
    }
    func suspend(at call: Int) { suspendedCall = call }
    func waitForCall(_ count: Int) async { if callCount < count { await withCheckedContinuation { observer = $0 } } }
    func resolvePending() { pending?.resume(returning: true); pending = nil }
}
