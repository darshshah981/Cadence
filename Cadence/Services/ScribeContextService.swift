import AppKit
import ApplicationServices
import Foundation

enum ScribeContextError: String, Error, Equatable, Sendable {
    case accessibilityDenied
    case noFocusedTarget
    case noSelection
    case secureField
    case contextTooLarge
    case unsupportedSelection
    case invalidContent
    case targetChanged
    case captureCleared

    var userMessage: String {
        switch self {
        case .accessibilityDenied:
            return "Accessibility access is needed to use selected text."
        case .noFocusedTarget:
            return "Cadence could not identify the app where you want to write."
        case .noSelection:
            return "Select text first, then try Respond or Edit again."
        case .secureField:
            return "Cadence does not read text from secure fields."
        case .contextTooLarge:
            return "The selection is too large. Select less than 32 KB of text."
        case .unsupportedSelection:
            return "This app does not expose selected text to Cadence."
        case .invalidContent:
            return "The selection contains content Cadence cannot safely use."
        case .targetChanged:
            return "Return to the original app and selection before inserting."
        case .captureCleared:
            return "This Scribe request has ended. Start a new request to continue."
        }
    }
}

struct ScribeAccessibilityReadSnapshot: Equatable, Sendable {
    let target: ScribeTargetIdentity
    let verificationToken: String
    let selectedText: String?
    let isSecureField: Bool
}

@MainActor
protocol ScribeAccessibilityReading: AnyObject {
    var isTrusted: Bool { get }
    func readFocusedSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot
}

@MainActor
protocol ScribeContextServing: AnyObject {
    func capture(for intent: ScribeIntent) throws -> ScribeContextSnapshot
    func verifyTarget(for capture: ScribeContextSnapshot) throws -> Bool
    func clear(_ capture: ScribeContextSnapshot)
}

@MainActor
final class ScribeContextService: ScribeContextServing {
    static let maximumContextUTF8Bytes = 32 * 1_024

    private let reader: ScribeAccessibilityReading
    private var activeCaptures: [UUID: String] = [:]

    convenience init() {
        self.init(reader: SystemScribeAccessibilityReader())
    }

    init(reader: ScribeAccessibilityReading) {
        self.reader = reader
    }

    func capture(for intent: ScribeIntent) throws -> ScribeContextSnapshot {
        guard reader.isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }

        let raw = try reader.readFocusedSnapshot(includeSelection: intent.requiresSelectedText)
        let selectedText: String
        if intent.requiresSelectedText {
            guard !raw.isSecureField else {
                throw ScribeContextError.secureField
            }
            guard let rawSelection = raw.selectedText else {
                throw ScribeContextError.unsupportedSelection
            }
            selectedText = try Self.normalizedContext(rawSelection)
        } else {
            selectedText = ""
        }

        let capture = ScribeContextSnapshot(
            target: raw.target,
            scope: intent.contextScope,
            selectedText: selectedText,
            verificationToken: raw.verificationToken
        )
        activeCaptures[capture.id] = raw.verificationToken
        return capture
    }

    func verifyTarget(for capture: ScribeContextSnapshot) throws -> Bool {
        guard activeCaptures[capture.id] == capture.verificationToken else {
            throw ScribeContextError.captureCleared
        }
        guard reader.isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }

        let current = try reader.readFocusedSnapshot(includeSelection: false)
        guard current.target == capture.target,
              current.verificationToken == capture.verificationToken else {
            throw ScribeContextError.targetChanged
        }
        return true
    }

    func clear(_ capture: ScribeContextSnapshot) {
        activeCaptures.removeValue(forKey: capture.id)
    }

    static func normalizedContext(_ text: String) throws -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ScribeContextError.noSelection
        }
        guard normalized.utf8.count <= maximumContextUTF8Bytes else {
            throw ScribeContextError.contextTooLarge
        }
        let containsUnsupportedControl = normalized.unicodeScalars.contains { scalar in
            scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }
        guard !containsUnsupportedControl else {
            throw ScribeContextError.invalidContent
        }
        return normalized
    }
}

@MainActor
final class SystemScribeAccessibilityReader: ScribeAccessibilityReading {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func readFocusedSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot {
        guard isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }

        let system = AXUIElementCreateSystemWide()
        let focusedElement = try copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: system)
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success,
              processIdentifier > 0 else {
            throw ScribeContextError.noFocusedTarget
        }

        let window = (try? copyElementAttribute(kAXWindowAttribute as CFString, from: focusedElement))
            ?? focusedElement
        let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: focusedElement)
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)
        let isSecureField = role == (kAXSecureTextFieldSubrole as String)
            || subrole == (kAXSecureTextFieldSubrole as String)

        let selectedText: String?
        if includeSelection {
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                focusedElement,
                kAXSelectedTextAttribute as CFString,
                &value
            )
            switch status {
            case .success:
                selectedText = value as? String
            case .noValue:
                selectedText = ""
            case .attributeUnsupported:
                throw ScribeContextError.unsupportedSelection
            default:
                throw ScribeContextError.noFocusedTarget
            }
        } else {
            selectedText = nil
        }

        return ScribeAccessibilityReadSnapshot(
            target: ScribeTargetIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            ),
            verificationToken: "\(processIdentifier):\(CFHash(window)):\(CFHash(focusedElement))",
            selectedText: selectedText,
            isSecureField: isSecureField
        )
    }

    private func copyElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> AXUIElement {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            throw ScribeContextError.noFocusedTarget
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
