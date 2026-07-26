import ApplicationServices
import Foundation

protocol TextInsertionServing: AnyObject {
    func insert(_ text: String) async throws
    func pressReturn() async throws
    func deleteLastInsertion() async throws
}

@MainActor
protocol DictationTargetCapabilityServing: AnyObject {
    func assessFocusedElement(
        for capture: ApplicationTargetCapture
    ) -> DictationTargetCapabilityAssessment
}

enum DictationTargetCapabilityReason: String, Equatable, Sendable {
    case accessibilityUnavailable
    case focusedElementUnavailable
    case roleUnavailable
    case selectedTextSettable
    case standardTextRole
    case editableAncestor
    case secureTextRole
    case nonTextRole
    case unrecognizedRole
}

enum DictationTargetCapabilityAssessment: Equatable, Sendable {
    case editable(DictationTargetCapabilityReason)
    case notEditable(DictationTargetCapabilityReason)
    case unknown(DictationTargetCapabilityReason)

    var reason: DictationTargetCapabilityReason {
        switch self {
        case .editable(let reason), .notEditable(let reason), .unknown(let reason):
            return reason
        }
    }

    var isDefinitelyNotEditable: Bool {
        if case .notEditable = self { return true }
        return false
    }

    var needsClipboardBackup: Bool {
        if case .unknown = self { return true }
        return false
    }

    var supportsCommandReturn: Bool {
        if case .editable = self { return true }
        return false
    }
}

struct FocusedTextElementCapability: Equatable, Sendable {
    let role: String?
    let selectedTextIsSettable: Bool
    var editableAncestorIsEditable = false
}

enum DictationTargetCapabilityPolicy {
    private static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox"
    ]
    private static let nonTextRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXImage",
        "AXLink",
        "AXList",
        "AXMenuBar",
        "AXMenuItem",
        "AXOutline",
        "AXRadioButton",
        "AXScrollBar",
        "AXSlider",
        "AXStaticText",
        "AXTabGroup",
        "AXTable",
        "AXToolbar",
        "AXWindow"
    ]

    static func assess(
        _ capability: FocusedTextElementCapability,
        bundleIdentifier _: String
    ) -> DictationTargetCapabilityAssessment {
        guard let role = capability.role else {
            return .unknown(.roleUnavailable)
        }
        guard role != "AXSecureTextField" else {
            return .notEditable(.secureTextRole)
        }
        if capability.selectedTextIsSettable {
            return .editable(.selectedTextSettable)
        }
        if textRoles.contains(role) {
            return .editable(.standardTextRole)
        }
        if capability.editableAncestorIsEditable {
            return .editable(.editableAncestor)
        }
        if nonTextRoles.contains(role) {
            return .notEditable(.nonTextRole)
        }
        return .unknown(.unrecognizedRole)
    }
}

@MainActor
final class SystemDictationTargetCapabilityService: DictationTargetCapabilityServing {
    func assessFocusedElement(
        for capture: ApplicationTargetCapture
    ) -> DictationTargetCapabilityAssessment {
        guard AXIsProcessTrusted() else {
            return .unknown(.accessibilityUnavailable)
        }

        let application = AXUIElementCreateApplication(capture.process.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue else {
            return .unknown(.focusedElementUnavailable)
        }

        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        let role = stringAttribute(kAXRoleAttribute as CFString, from: focusedElement)
        let editableAncestor = elementAttribute(
            "AXEditableAncestor" as CFString,
            from: focusedElement
        )
        return DictationTargetCapabilityPolicy.assess(
            FocusedTextElementCapability(
                role: role,
                selectedTextIsSettable: isSettable(
                    kAXSelectedTextAttribute as CFString,
                    on: focusedElement
                ),
                editableAncestorIsEditable: editableAncestor.flatMap {
                    stringAttribute(kAXRoleAttribute as CFString, from: $0)
                }.map { $0 != "AXSecureTextField" } ?? false
            ),
            bundleIdentifier: capture.process.bundleIdentifier
        )
    }

    private func isSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute,
            &settable
        ) == .success && settable.boolValue
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private func elementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}

enum GuardedTextInsertionError: Error, Equatable, Sendable {
    case uncertainPartialInsertion
}

final class TextInsertionService: TextInsertionServing {
    private var lastInsertedText = ""

    func insert(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw CadenceError.accessibilityPermissionMissing
        }

        try await postUnicodeString(text)
        lastInsertedText = text
    }

    func deleteLastInsertion() async throws {
        guard !lastInsertedText.isEmpty else { return }
        try await postModifiedKeystroke(keyCode: 6, modifiers: .maskCommand)
        lastInsertedText = ""
    }

    func pressReturn() async throws {
        guard AXIsProcessTrusted() else {
            throw CadenceError.accessibilityPermissionMissing
        }
        try await postModifiedKeystroke(keyCode: 36, modifiers: [])
    }

    private func postUnicodeString(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw CadenceError.eventSourceUnavailable
        }

        var insertedScalars = 0
        for scalar in text.utf16 {
            do {
                try autoreleasepool {
                guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                    throw CadenceError.eventSourceUnavailable
                }

                var value = scalar
                keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                }
                insertedScalars += 1
            } catch {
                if insertedScalars > 0 {
                    throw GuardedTextInsertionError.uncertainPartialInsertion
                }
                throw error
            }
        }
    }

    private func postModifiedKeystroke(keyCode: CGKeyCode, modifiers: CGEventFlags) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw CadenceError.eventSourceUnavailable
        }

        keyDown.flags = modifiers
        keyUp.flags = modifiers
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
