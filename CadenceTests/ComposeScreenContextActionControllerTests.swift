import CoreGraphics
import Foundation
import Testing
@testable import Cadence

@MainActor
struct ComposeScreenContextActionControllerTests {
    @Test
    func missingScreenshotGrantStopsBeforeTheSystemPicker() async {
        let fixture = Fixture(granted: false)
        #expect(await fixture.controller.captureForExplicitChoice(
            actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
        ) == .unavailable(.policy(.disabled)))
        #expect(fixture.picker.callCount == 0)
        #expect(fixture.frameReadCount == 0)
        #expect(await fixture.screen.callCount == 0)
    }

    @Test
    func privateSurfaceOrInvalidBudgetNeverOpensPicker() async {
        let fixture = Fixture()
        #expect(await fixture.controller.captureForExplicitChoice(
            actionID: fixture.actionID, capture: fixture.capture, eligibility: .privateSurface
        ) == .unavailable(.policy(.ineligibleSurface)))
        var budget = ComposeScreenCaptureBudget()
        budget.maximumPixels = 0
        #expect(await fixture.controller.captureForExplicitChoice(
            actionID: fixture.actionID, capture: fixture.capture,
            eligibility: .eligible, budget: budget
        ) == .unavailable(.invalidBudget))
        #expect(fixture.picker.callCount == 0)
        #expect(fixture.frameReadCount == 0)
    }

    @Test
    func missingPinnedWindowGeometryNeverOpensPicker() async {
        let fixture = Fixture()
        fixture.focusedFrame = nil
        #expect(await fixture.controller.captureForExplicitChoice(
            actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
        ) == .unavailable(.invalidTarget))
        #expect(fixture.picker.callCount == 0)
        #expect(await fixture.screen.callCount == 0)
    }

    @Test
    func oneExplicitChoiceCapturesOnlyThePinnedWindow() async {
        let fixture = Fixture()
        guard case let .captured(snapshot) = await fixture.controller.captureForExplicitChoice(
            actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
        ) else {
            Issue.record("Expected bounded OCR context")
            return
        }
        #expect(snapshot.screenText == "Synthetic visible context")
        #expect(snapshot.target.window == fixture.window)
        #expect(await fixture.screen.windows == [fixture.window])
        #expect(fixture.picker.callCount == 1)
        #expect(fixture.frameReadCount == 1)
    }

    @Test
    func revokedGrantWhilePickerIsOpenNeverStartsPixelCapture() async {
        let fixture = Fixture()
        fixture.picker.suspendNextChoice = true
        let task = Task {
            await fixture.controller.captureForExplicitChoice(
                actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
            )
        }
        await fixture.picker.waitForChoice()
        fixture.policy.isEnabled = false
        fixture.picker.finishChoice(with: fixture.window)
        #expect(await task.value == .unavailable(.policy(.disabled)))
        #expect(await fixture.screen.callCount == 0)
    }

    @Test
    func switchedActionWhileCaptureIsPendingCannotPublishOCR() async {
        let fixture = Fixture()
        await fixture.screen.suspendNextCapture()
        let task = Task {
            await fixture.controller.captureForExplicitChoice(
                actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
            )
        }
        await fixture.screen.waitForCapture()
        fixture.currentActionID = nil
        await fixture.screen.finishCapture()
        #expect(await task.value == .unavailable(.targetChanged))
        #expect(await fixture.ocr.callCount == 0)
    }

    @Test
    func unexpectedPickerWindowIsRejectedBeforeCapture() async {
        let fixture = Fixture()
        fixture.picker.selectedWindow = .init(
            windowID: 42, processIdentifier: 77, bundleIdentifier: "different.app",
            processIdentity: fixture.capture.applicationTarget.process,
            expectedFrame: fixture.window.expectedFrame
        )
        #expect(await fixture.controller.captureForExplicitChoice(
            actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
        ) == .unavailable(.invalidTarget))
        #expect(await fixture.screen.callCount == 0)
    }

    @Test
    func anotherWindowInTheSameAppIsNotThePinnedEditor() async {
        let fixture = Fixture()
        fixture.picker.selectedWindow = .init(
            windowID: 8, processIdentifier: 42, bundleIdentifier: "test.editor",
            processIdentity: fixture.capture.applicationTarget.process,
            expectedFrame: .init(x: 30, y: 30, width: 100, height: 40)
        )
        #expect(await fixture.controller.captureForExplicitChoice(
            actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
        ) == .unavailable(.invalidTarget))
        #expect(await fixture.screen.callCount == 0)
    }

    @Test
    func secondActionCannotRaceAnOpenPicker() async {
        let fixture = Fixture()
        fixture.picker.suspendNextChoice = true
        let first = Task {
            await fixture.controller.captureForExplicitChoice(
                actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
            )
        }
        await fixture.picker.waitForChoice()
        #expect(await fixture.controller.captureForExplicitChoice(
            actionID: fixture.actionID, capture: fixture.capture, eligibility: .eligible
        ) == .unavailable(.invalidTarget))
        fixture.picker.finishChoice(with: fixture.window)
        guard case .captured = await first.value else {
            Issue.record("First explicit choice should complete")
            return
        }
        #expect(fixture.picker.callCount == 1)
    }

    @MainActor
    private final class Fixture {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let actionID = UUID()
        let capture: ScribeContextSnapshot
        let window: ComposeScreenWindowIdentity
        let picker: PickerFake
        let screen = ScreenFake()
        let ocr = OCRFake()
        var policy: ScribeContextPolicySnapshot
        var currentActionID: UUID?
        var currentCapture: ScribeContextSnapshot?
        var targetIsCurrent = true
        var focusedFrame: CGRect? = .init(x: 20, y: 30, width: 100, height: 40)
        var frameReadCount = 0
        lazy var controller = ComposeScreenContextActionController(
            picker: picker, captureAdapter: screen, ocr: ocr,
            policy: { [unowned self] in self.policy },
            permissions: { .init(screenRecording: true) },
            actionIsCurrent: { [unowned self] id in self.currentActionID == id },
            captureIsCurrent: { [unowned self] capture in self.currentCapture == capture },
            focusedWindowFrame: { [unowned self] _ in
                self.frameReadCount += 1
                return self.focusedFrame
            },
            targetIsCurrent: { [unowned self] _ in self.targetIsCurrent },
            now: { [unowned self] in self.now }
        )

        init(granted: Bool = true) {
            let id = UUID()
            let process = ApplicationProcessIdentity(
                processIdentifier: 42, bundleIdentifier: "test.editor",
                bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
                incarnation: UUID(), launchDate: Date(timeIntervalSince1970: 100)
            )
            capture = .init(
                id: id, target: .init(processIdentifier: 42, bundleIdentifier: "test.editor"),
                selectedText: "",
                applicationTarget: .init(
                    id: id, process: process, identityRevision: 1,
                    captureRevision: 1, source: .scribeAccessibility
                )
            )
            window = .init(
                windowID: 7, processIdentifier: 42, bundleIdentifier: "test.editor",
                processIdentity: process,
                expectedFrame: .init(x: 20, y: 30, width: 100, height: 40)
            )
            picker = PickerFake(selectedWindow: window)
            currentActionID = actionID
            currentCapture = capture
            policy = .init(isEnabled: granted, captureGrants: [.init(
                id: UUID(), scope: .application(bundleIdentifier: "test.editor"),
                categories: [.screenshot],
                window: .init(acceptedAt: now.addingTimeInterval(-1),
                              expiresAt: now.addingTimeInterval(60))
            )])
        }
    }
}

@MainActor
private final class PickerFake: ComposeScreenWindowChoosing {
    var selectedWindow: ComposeScreenWindowIdentity
    var suspendNextChoice = false
    private var pending: CheckedContinuation<ComposeScreenWindowIdentity, Error>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    init(selectedWindow: ComposeScreenWindowIdentity) { self.selectedWindow = selectedWindow }
    func chooseWindow(actionID _: UUID, capture _: ScribeContextSnapshot,
                      expectedFrame _: CGRect) async throws -> ComposeScreenWindowIdentity {
        callCount += 1
        observer?.resume(); observer = nil
        if suspendNextChoice {
            suspendNextChoice = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return selectedWindow
    }
    func waitForChoice() async {
        if callCount == 0 { await withCheckedContinuation { observer = $0 } }
    }
    func finishChoice(with window: ComposeScreenWindowIdentity) {
        pending?.resume(returning: window); pending = nil
    }
}

private actor ScreenFake: ComposeScreenCapturing {
    private var pending: CheckedContinuation<ComposeScreenImage, Error>?
    private var observer: CheckedContinuation<Void, Never>?
    private var shouldSuspend = false
    private(set) var windows: [ComposeScreenWindowIdentity] = []
    private(set) var callCount = 0
    func capture(window: ComposeScreenWindowIdentity, timeoutMilliseconds _: Int) async throws -> ComposeScreenImage {
        callCount += 1; windows.append(window)
        observer?.resume(); observer = nil
        if shouldSuspend {
            shouldSuspend = false
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return .init(width: 100, height: 40)
    }
    func suspendNextCapture() { shouldSuspend = true }
    func waitForCapture() async {
        if callCount == 0 { await withCheckedContinuation { observer = $0 } }
    }
    func finishCapture() { pending?.resume(returning: .init(width: 100, height: 40)); pending = nil }
}

private actor OCRFake: ComposeScreenOCRRecognizing {
    private(set) var callCount = 0
    func recognize(image _: ComposeScreenImage, maximumLines _: Int, timeoutMilliseconds _: Int) async throws -> ComposeOCRResult {
        callCount += 1
        return .init(lines: [.init(
            text: "Synthetic visible context", confidence: 0.95,
            boundingBox: .init(x: 0, y: 0, width: 1, height: 1)
        )], isClipped: false)
    }
}
