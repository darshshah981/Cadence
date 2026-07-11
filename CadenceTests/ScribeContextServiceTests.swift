import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeContextServiceTests {
    @Test
    func composeCapturesTargetWithoutReadingSelection() throws {
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "window-a",
                selectedText: "should not be read",
                isSecureField: false,
                selectionIdentity: .init(location: 7, length: 0)
            )
        )
        let service = ScribeContextService(reader: reader)

        let capture = try service.capture(for: .compose)

        #expect(capture.scope == .none)
        #expect(capture.selectedText.isEmpty)
        #expect(capture.selectionIdentity == .init(location: 7, length: 0))
        #expect(reader.selectionReadRequests == [false])
        #expect(try service.verifyTarget(for: capture))
        #expect(reader.currentFocusReadRequests == [false])
    }

    @Test
    func selectedTextIsNormalizedAndDisclosed() throws {
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "window-a",
                selectedText: "Cafe\u{301}",
                isSecureField: false
            )
        )
        let service = ScribeContextService(reader: reader)

        let capture = try service.capture(for: .respond)

        #expect(capture.scope == .selectedText)
        #expect(capture.selectedText == "Caf\u{00E9}")
        #expect(capture.disclosure == "Using selected text")
        #expect(reader.selectionReadRequests == [true])
    }

    @Test
    func contextCaptureFailsClosedForDeniedSecureMissingAndOversizedSelection() {
        let target = ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: nil)
        let cases: [(ScribeAccessibilityReadSnapshot, Bool, ScribeContextError)] = [
            (.init(target: target, verificationToken: "a", selectedText: nil, isSecureField: false), false, .accessibilityDenied),
            (.init(target: target, verificationToken: "a", selectedText: "secret", isSecureField: true), true, .secureField),
            (.init(target: target, verificationToken: "a", selectedText: "", isSecureField: false), true, .noSelection),
            (.init(target: target, verificationToken: "a", selectedText: String(repeating: "é", count: 16_385), isSecureField: false), true, .contextTooLarge)
        ]

        for (snapshot, trusted, expectedError) in cases {
            let reader = StubScribeAccessibilityReader(snapshot: snapshot, isTrusted: trusted)
            let service = ScribeContextService(reader: reader)

            #expect(throws: expectedError) {
                try service.capture(for: .edit)
            }
        }
    }

    @Test
    func targetVerificationDetectsWindowChangeAndClearedCapture() throws {
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
                verificationToken: "window-a",
                selectedText: "Draft",
                isSecureField: false
            )
        )
        let service = ScribeContextService(reader: reader)
        let capture = try service.capture(for: .edit)

        reader.snapshot = .init(
            target: capture.target,
            verificationToken: "window-b",
            selectedText: "Draft",
            isSecureField: false
        )
        #expect(throws: ScribeContextError.targetChanged) {
            try service.verifyTarget(for: capture)
        }

        service.clear(capture)
        #expect(throws: ScribeContextError.captureCleared) {
            try service.verifyTarget(for: capture)
        }
    }

    @Test
    func targetVerificationRejectsChangedSelectionInSameElement() throws {
        let target = ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit")
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: target,
                verificationToken: "window-a",
                selectedText: "First selection",
                isSecureField: false,
                selectionIdentity: .init(location: 2, length: 15)
            )
        )
        let service = ScribeContextService(reader: reader)
        let capture = try service.capture(for: .edit)

        reader.snapshot = .init(
            target: target,
            verificationToken: "window-a",
            selectedText: "Second selection",
            isSecureField: false,
            selectionIdentity: .init(location: 30, length: 16)
        )

        #expect(throws: ScribeContextError.targetChanged) {
            try service.verifyTarget(for: capture)
        }
    }

    @Test
    func verificationUsesFreshSystemFocusAndRejectsMovedComposeCaret() throws {
        let target = ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit")
        let signature = TargetRecognitionSignature(
            role: "AXTextArea",
            subrole: nil,
            identifierAncestry: ["editor"]
        )
        let reader = StubScribeAccessibilityReader(
            snapshot: .init(
                target: target,
                verificationToken: "window-a",
                selectedText: nil,
                isSecureField: false,
                selectionIdentity: .init(location: 3, length: 0),
                recognitionSignature: signature
            )
        )
        let service = ScribeContextService(reader: reader)
        let capture = try service.capture(for: .compose)

        reader.currentSnapshot = .init(
            target: target,
            verificationToken: "window-a",
            selectedText: nil,
            isSecureField: false,
            selectionIdentity: .init(location: 9, length: 0),
            recognitionSignature: signature
        )

        #expect(throws: ScribeContextError.targetChanged) {
            try service.verifyTarget(for: capture)
        }
        #expect(reader.currentFocusReadRequests == [false])
    }
}

@MainActor
private final class StubScribeAccessibilityReader: ScribeAccessibilityReading {
    var snapshot: ScribeAccessibilityReadSnapshot
    var currentSnapshot: ScribeAccessibilityReadSnapshot?
    var isTrusted: Bool
    private(set) var selectionReadRequests: [Bool] = []
    private(set) var currentFocusReadRequests: [Bool] = []

    init(snapshot: ScribeAccessibilityReadSnapshot, isTrusted: Bool = true) {
        self.snapshot = snapshot
        self.isTrusted = isTrusted
    }

    func pinFocusedTarget() throws {}

    func readPinnedSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot {
        selectionReadRequests.append(includeSelection)
        return snapshot
    }

    func readCurrentFocusSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot {
        currentFocusReadRequests.append(includeSelection)
        return currentSnapshot ?? snapshot
    }

    func replacePinnedSelection(with text: String) throws -> Bool { true }
    func clearPinnedTarget() {}
}
