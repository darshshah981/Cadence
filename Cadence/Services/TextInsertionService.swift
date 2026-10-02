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
    case webTextCursorHint
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
    var hasTextCursorHint = false
    var subrole: String? = nil
    var hasSecureEditableAncestor = false
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
        guard capability.role != "AXSecureTextField",
              capability.subrole != "AXSecureTextField",
              !capability.hasSecureEditableAncestor else {
            return .notEditable(.secureTextRole)
        }
        guard let role = capability.role else {
            return .unknown(.roleUnavailable)
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
        // Some web composers expose a containing button instead of the actual
        // editor. A text-cursor hint makes that role inconclusive, not confirmed
        // editable: attempt typing with clipboard backup, but never press Return.
        if role == "AXButton", capability.hasTextCursorHint {
            return .unknown(.webTextCursorHint)
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
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)
        let editableAncestor = elementAttribute(
            "AXEditableAncestor" as CFString,
            from: focusedElement
        )
        let secureAncestor = editableAncestor.map {
            stringAttribute(kAXRoleAttribute as CFString, from: $0) == "AXSecureTextField"
                || stringAttribute(kAXSubroleAttribute as CFString, from: $0) == "AXSecureTextField"
        } ?? false
        return DictationTargetCapabilityPolicy.assess(
            FocusedTextElementCapability(
                role: role,
                selectedTextIsSettable: isSettable(
                    kAXSelectedTextAttribute as CFString,
                    on: focusedElement
                ),
                editableAncestorIsEditable: editableAncestor.flatMap {
                    stringAttribute(kAXRoleAttribute as CFString, from: $0)
                }.map { $0 != "AXSecureTextField" } ?? false,
                hasTextCursorHint: role == "AXButton" && hasTextCursorHint(focusedElement),
                subrole: subrole,
                hasSecureEditableAncestor: secureAncestor
            ),
            bundleIdentifier: capture.process.bundleIdentifier
        )
    }

    private func hasTextCursorHint(_ element: AXUIElement) -> Bool {
        // Read only non-content accessibility metadata. Do not inspect editor
        // values, selected text, surrounding content, or an app-specific label.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, "AXDOMClassList" as CFString, &value
        ) == .success, let classes = value as? [String] else { return false }
        return classes.contains("cursor-text")
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

protocol UnicodeScalarEventPosting {
    func post(_ scalar: Unicode.Scalar) throws
}

struct SystemUnicodeScalarEventPoster: UnicodeScalarEventPosting {
    private let source: CGEventSource

    init() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw CadenceError.eventSourceUnavailable
        }
        self.source = source
    }

    func events(for scalar: Unicode.Scalar) throws -> [CGEvent] {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw CadenceError.eventSourceUnavailable
        }
        // A non-BMP scalar is a UTF-16 surrogate pair. Sending the halves as
        // separate key events lets editors observe invalid intermediate text.
        let units = Array(String(scalar).utf16)
        units.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        return [keyDown, keyUp]
    }

    func post(_ scalar: Unicode.Scalar) throws {
        try autoreleasepool {
            for event in try events(for: scalar) {
                event.post(tap: .cghidEventTap)
            }
        }
    }
}

final class TextInsertionService: TextInsertionServing {
    private var lastInsertedText = ""
    private let isAccessibilityTrusted: () -> Bool
    private let unicodePosterFactory: () throws -> any UnicodeScalarEventPosting

    init(
        isAccessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        unicodePosterFactory: @escaping () throws -> any UnicodeScalarEventPosting = {
            try SystemUnicodeScalarEventPoster()
        }
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.unicodePosterFactory = unicodePosterFactory
    }

    func insert(_ text: String) async throws {
        try Task.checkCancellation()
        guard isAccessibilityTrusted() else {
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
        guard isAccessibilityTrusted() else {
            throw CadenceError.accessibilityPermissionMissing
        }
        try await postModifiedKeystroke(keyCode: 36, modifiers: [])
    }

    private func postUnicodeString(_ text: String) async throws {
        let poster = try unicodePosterFactory()

        var insertedScalars = 0
        for scalar in text.unicodeScalars {
            do {
                try Task.checkCancellation()
                try poster.post(scalar)
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
