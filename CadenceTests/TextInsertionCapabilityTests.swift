import Testing
@testable import Cadence

struct TextInsertionCapabilityTests {
    @Test
    func failureAfterOnePostedUnicodeCharacterIsUncertain() async throws {
        let poster = FailingUnicodeScalarPoster(failOnCall: 2)
        let service = TextInsertionService(
            isAccessibilityTrusted: { true }, unicodePosterFactory: { poster }
        )

        await #expect(throws: GuardedTextInsertionError.uncertainPartialInsertion) {
            try await service.insert("AB")
        }
        #expect(poster.posted == Array("A".utf16))
    }

    @Test
    func failureBeforeAnyUnicodeCharacterPreservesTheOriginalError() async throws {
        let poster = FailingUnicodeScalarPoster(failOnCall: 1)
        let service = TextInsertionService(
            isAccessibilityTrusted: { true }, unicodePosterFactory: { poster }
        )

        await #expect(throws: CadenceError.eventSourceUnavailable) {
            try await service.insert("AB")
        }
        #expect(poster.posted.isEmpty)
    }

    @Test
    func cancelledBeforeInsertionEmitsNoKeyboardEvents() async throws {
        let poster = FailingUnicodeScalarPoster(failOnCall: Int.max)
        let service = TextInsertionService(
            isAccessibilityTrusted: { true }, unicodePosterFactory: { poster }
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.insert("AB")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(poster.posted.isEmpty)
    }

    @Test
    func cancellationAfterOneCharacterStopsPostingAndReportsUncertainty() async throws {
        let poster = CancelAfterFirstUnicodeScalarPoster()
        let service = TextInsertionService(
            isAccessibilityTrusted: { true }, unicodePosterFactory: { poster }
        )
        await #expect(throws: GuardedTextInsertionError.uncertainPartialInsertion) {
            try await service.insert("AB")
        }
        #expect(poster.posted == Array("A".utf16))
    }

    @Test
    func secureSubroleOverridesTextRoleSettableTextAndCursorHints() {
        for role in ["AXTextField", "AXButton", nil] {
            let assessment = DictationTargetCapabilityPolicy.assess(
                .init(role: role, selectedTextIsSettable: true, hasTextCursorHint: true, subrole: "AXSecureTextField"),
                bundleIdentifier: "com.cadence.synthetic"
            )
            #expect(assessment == .notEditable(.secureTextRole))
            #expect(!assessment.supportsCommandReturn)
        }
    }

    @Test
    func secureEditableAncestorPreventsTypingIntoItsDescendant() {
        #expect(DictationTargetCapabilityPolicy.assess(
            .init(role: "AXStaticText", selectedTextIsSettable: true, editableAncestorIsEditable: true, hasSecureEditableAncestor: true),
            bundleIdentifier: "com.cadence.synthetic"
        ) == .notEditable(.secureTextRole))
    }

    @Test
    func webComposerWithButtonRoleAndTextCursorIsNotDefinitelyNonEditable() {
        let capability = FocusedTextElementCapability(
            role: "AXButton",
            selectedTextIsSettable: false,
            hasTextCursorHint: true
        )
        let assessment = DictationTargetCapabilityPolicy.assess(
            capability, bundleIdentifier: "com.meta.endo"
        )
        #expect(!assessment.isDefinitelyNotEditable)
        #expect(assessment.needsClipboardBackup)
        #expect(!assessment.supportsCommandReturn)
    }

    @Test
    func ordinaryButtonWithoutTextCursorStillCopies() {
        #expect(DictationTargetCapabilityPolicy.assess(
            .init(role: "AXButton", selectedTextIsSettable: false),
            bundleIdentifier: "com.meta.endo"
        ) == .notEditable(.nonTextRole))
    }

    @Test
    func terminalTextAreaAcceptsKeyboardInsertionWithoutSettableTextAttributes() {
        let capability = FocusedTextElementCapability(
            role: "AXTextArea",
            selectedTextIsSettable: false
        )

        #expect(DictationTargetCapabilityPolicy.assess(
            capability,
            bundleIdentifier: "com.apple.Terminal"
        ) == .editable(.standardTextRole))
    }

    @Test
    func standardTextAreaAcceptsKeyboardInsertionWithoutSettableAttributes() {
        let capability = FocusedTextElementCapability(
            role: "AXTextArea",
            selectedTextIsSettable: false
        )

        #expect(DictationTargetCapabilityPolicy.assess(
            capability,
            bundleIdentifier: "com.apple.Safari"
        ) == .editable(.standardTextRole))
    }

    @Test
    func editableAncestorAllowsInsertionForWebEditorFocusedDescendant() {
        let capability = FocusedTextElementCapability(
            role: "AXStaticText",
            selectedTextIsSettable: false,
            editableAncestorIsEditable: true
        )

        #expect(DictationTargetCapabilityPolicy.assess(
            capability,
            bundleIdentifier: "com.apple.Safari"
        ) == .editable(.editableAncestor))
    }

    @Test
    func terminalSecureFieldStillFailsClosed() {
        let capability = FocusedTextElementCapability(
            role: "AXSecureTextField",
            selectedTextIsSettable: true,
            hasTextCursorHint: true
        )

        #expect(DictationTargetCapabilityPolicy.assess(
            capability,
            bundleIdentifier: "com.apple.Terminal"
        ) == .notEditable(.secureTextRole))
    }

    @Test
    func focusedWindowWithoutTextControlStillCopies() {
        let capability = FocusedTextElementCapability(
            role: "AXWindow",
            selectedTextIsSettable: false
        )

        #expect(DictationTargetCapabilityPolicy.assess(
            capability,
            bundleIdentifier: "com.apple.Safari"
        ) == .notEditable(.nonTextRole))
    }

    @Test
    func unrecognizedCustomEditorRoleRemainsUnknownInsteadOfCopyOnly() {
        let capability = FocusedTextElementCapability(
            role: "AXWebArea",
            selectedTextIsSettable: false
        )

        #expect(DictationTargetCapabilityPolicy.assess(
            capability,
            bundleIdentifier: "com.openai.codex"
        ) == .unknown(.unrecognizedRole))
    }
}

private final class FailingUnicodeScalarPoster: UnicodeScalarEventPosting {
    let failOnCall: Int
    private(set) var posted: [UInt16] = []
    private var calls = 0

    init(failOnCall: Int) { self.failOnCall = failOnCall }

    func post(_ scalar: UInt16) throws {
        calls += 1
        if calls == failOnCall { throw CadenceError.eventSourceUnavailable }
        posted.append(scalar)
    }
}

private final class CancelAfterFirstUnicodeScalarPoster: UnicodeScalarEventPosting {
    private(set) var posted: [UInt16] = []

    func post(_ scalar: UInt16) throws {
        posted.append(scalar)
        if posted.count == 1 {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}
