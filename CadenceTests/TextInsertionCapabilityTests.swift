import Testing
@testable import Cadence

struct TextInsertionCapabilityTests {
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
            selectedTextIsSettable: true
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
