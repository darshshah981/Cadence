import CoreGraphics
import Foundation
import Testing
@testable import Cadence

struct ComposeScreenWindowPickerTests {
    @Test
    func singleChosenWindowBindsExactIDToPinnedProcess() throws {
        let capture = makeCapture()
        let result = try ComposeScreenWindowPickerPolicy.resolve(
            styleIsWindow: true,
            windows: [window()], capture: capture
        )
        #expect(result.windowID == 7)
        #expect(result.processIdentity == capture.applicationTarget.process)
        #expect(result.expectedFrame == window().frame)
        #expect(result.bundleIdentifier == capture.applicationTarget.process.bundleIdentifier)
    }

    @Test
    func displayAppMultipleOrWrongProcessSelectionCannotBecomeTarget() {
        let capture = makeCapture()
        let wrong = ComposePickedWindowMetadata(
            windowID: 8, processIdentifier: 43, bundleIdentifier: "other.app",
            frame: window().frame, isOnScreen: true
        )
        let variants: [(Bool, [ComposePickedWindowMetadata])] = [
            (false, [window()]), (true, []), (true, [window(), window()]),
            (true, [wrong]),
            (true, [.init(windowID: 0, processIdentifier: 42,
                          bundleIdentifier: "test.editor", frame: window().frame, isOnScreen: true)]),
            (true, [.init(windowID: 7, processIdentifier: 42,
                          bundleIdentifier: "test.editor", frame: window().frame, isOnScreen: false)]),
            (true, [.init(windowID: 7, processIdentifier: 42,
                          bundleIdentifier: "test.editor", frame: .zero, isOnScreen: true)])
        ]
        for (styleIsWindow, windows) in variants {
            #expect(throws: ComposeScreenWindowPickerError.invalidSelection) {
                try ComposeScreenWindowPickerPolicy.resolve(
                    styleIsWindow: styleIsWindow, windows: windows, capture: capture
                )
            }
        }
    }

    @Test
    func staleOrNonComposeCaptureCannotBindPickerChoice() {
        let capture = makeCapture()
        let stale = ScribeContextSnapshot(
            id: UUID(), target: capture.target, selectedText: "",
            applicationTarget: capture.applicationTarget
        )
        #expect(throws: ComposeScreenWindowPickerError.targetChanged) {
            try ComposeScreenWindowPickerPolicy.resolve(
                styleIsWindow: true, windows: [window()], capture: stale
            )
        }
        let dictationTarget = ApplicationTargetCapture(
            id: capture.id, process: capture.applicationTarget.process,
            identityRevision: 1, captureRevision: 1, source: .dictation
        )
        let dictation = ScribeContextSnapshot(
            id: capture.id, target: capture.target, selectedText: "",
            applicationTarget: dictationTarget
        )
        #expect(throws: ComposeScreenWindowPickerError.targetChanged) {
            try ComposeScreenWindowPickerPolicy.resolve(
                styleIsWindow: true, windows: [window()], capture: dictation
            )
        }
    }

    private func makeCapture() -> ScribeContextSnapshot {
        let id = UUID()
        let process = ApplicationProcessIdentity(
            processIdentifier: 42, bundleIdentifier: "test.editor",
            bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
            incarnation: UUID(), launchDate: Date(timeIntervalSince1970: 100)
        )
        return .init(
            id: id,
            target: .init(processIdentifier: 42, bundleIdentifier: "test.editor"),
            selectedText: "",
            applicationTarget: .init(
                id: id, process: process, identityRevision: 1,
                captureRevision: 1, source: .scribeAccessibility
            )
        )
    }

    private func window() -> ComposePickedWindowMetadata {
        .init(
            windowID: 7, processIdentifier: 42, bundleIdentifier: "test.editor",
            frame: .init(x: 20, y: 30, width: 600, height: 400), isOnScreen: true
        )
    }
}
