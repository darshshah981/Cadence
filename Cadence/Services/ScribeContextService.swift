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
    let selectionIdentity: ScribeSelectionIdentity?
    let recognitionSignature: TargetRecognitionSignature?

    init(
        target: ScribeTargetIdentity,
        verificationToken: String,
        selectedText: String?,
        isSecureField: Bool,
        selectionIdentity: ScribeSelectionIdentity? = nil,
        recognitionSignature: TargetRecognitionSignature? = nil
    ) {
        self.target = target
        self.verificationToken = verificationToken
        self.selectedText = selectedText
        self.isSecureField = isSecureField
        self.selectionIdentity = selectionIdentity
        self.recognitionSignature = recognitionSignature
    }
}

@MainActor
protocol ScribeAccessibilityReading: AnyObject {
    var isTrusted: Bool { get }
    func pinFocusedTarget() throws
    func readPinnedSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot
    func readCurrentFocusSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot
    func replacePinnedSelection(with text: String) throws -> Bool
    func clearPinnedTarget()
}

extension ScribeAccessibilityReading {
    func readCurrentFocusSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot {
        try readPinnedSnapshot(includeSelection: includeSelection)
    }
}

@MainActor
protocol ScribeContextServing: AnyObject {
    func prepareTarget() throws
    func capture(for intent: ScribeIntent) throws -> ScribeContextSnapshot
    func verifyTarget(for capture: ScribeContextSnapshot) throws -> Bool
    func insert(_ text: String, for capture: ScribeContextSnapshot) throws -> Bool
    func clear(_ capture: ScribeContextSnapshot)
    func discardPreparedTarget()
}

@MainActor
final class ScribeContextService: ScribeContextServing {
    nonisolated static let maximumContextUTF8Bytes = 32 * 1_024

    private let reader: ScribeAccessibilityReading
    private let processAuthority: any RuntimeApplicationProcessAuthorizing
    private let targetAuthority: (any ApplicationTargetAuthorizing)?
    private var activeCaptures: [UUID: String] = [:]

    convenience init() {
        self.init(
            reader: SystemScribeAccessibilityReader(),
            processAuthority: RuntimeApplicationProcessAuthority(),
            targetAuthority: nil
        )
    }

    convenience init(targetAuthority: any ApplicationTargetAuthorizing) {
        self.init(
            reader: SystemScribeAccessibilityReader(),
            processAuthority: RuntimeApplicationProcessAuthority(),
            targetAuthority: targetAuthority
        )
    }

    init(
        reader: ScribeAccessibilityReading,
        processAuthority: any RuntimeApplicationProcessAuthorizing,
        targetAuthority: (any ApplicationTargetAuthorizing)? = nil
    ) {
        self.reader = reader
        self.processAuthority = processAuthority
        self.targetAuthority = targetAuthority
    }

    func prepareTarget() throws {
        guard reader.isTrusted else { throw ScribeContextError.accessibilityDenied }
        try reader.pinFocusedTarget()
    }

    func capture(for intent: ScribeIntent) throws -> ScribeContextSnapshot {
        guard reader.isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }

        let raw = try reader.readPinnedSnapshot(includeSelection: intent.requiresSelectedText)
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

        let captureID = UUID()
        let resolved = try processAuthority.capture(
            processIdentifier: raw.target.processIdentifier,
            expectedBundleIdentifier: raw.target.bundleIdentifier
        )
        let monitorTarget = targetAuthority?.enrichCapture(
            id: captureID,
            processIdentifier: raw.target.processIdentifier,
            bundleIdentifier: raw.target.bundleIdentifier
        )
        let exactMonitorTarget = monitorTarget.flatMap {
            $0.process.processIdentifier == resolved.identity.processIdentifier
                && $0.process.bundleIdentifier == resolved.identity.bundleIdentifier
                && $0.process.bundleURL == resolved.identity.bundleURL
                && $0.process.launchDate == resolved.identity.launchDate
                ? $0 : nil
        }
        let applicationTarget = ApplicationTargetCapture(
            id: captureID,
            process: resolved.identity,
            identityRevision: exactMonitorTarget?.identityRevision ?? 0,
            captureRevision: exactMonitorTarget?.captureRevision ?? 0,
            source: .scribeAccessibility,
            displayName: exactMonitorTarget?.displayName ?? resolved.displayName
        )
        let capture = ScribeContextSnapshot(
            id: captureID,
            target: raw.target,
            scope: intent.contextScope,
            selectedText: selectedText,
            verificationToken: raw.verificationToken,
            selectionIdentity: raw.selectionIdentity,
            recognitionSignature: raw.recognitionSignature,
            applicationTarget: applicationTarget
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

        let current = try reader.readCurrentFocusSnapshot(includeSelection: capture.scope == .selectedText)
        guard current.target == capture.target,
              current.verificationToken == capture.verificationToken,
              current.selectionIdentity == capture.selectionIdentity,
              current.recognitionSignature == capture.recognitionSignature else {
            throw ScribeContextError.targetChanged
        }
        if !processAuthority.verify(capture.applicationTarget.process) {
            throw ScribeContextError.targetChanged
        }
        if capture.scope == .selectedText {
            let currentSelection = current.selectedText.flatMap { try? Self.normalizedContext($0) }
            guard !current.isSecureField,
                  currentSelection == capture.selectedText else {
                throw ScribeContextError.targetChanged
            }
        }
        return true
    }

    func insert(_ text: String, for capture: ScribeContextSnapshot) throws -> Bool {
        guard try verifyTarget(for: capture) else { return false }
        return try reader.replacePinnedSelection(with: text)
    }

    func clear(_ capture: ScribeContextSnapshot) {
        if activeCaptures.removeValue(forKey: capture.id) != nil {
            processAuthority.release(capture.applicationTarget.process)
        }
        if activeCaptures.isEmpty { reader.clearPinnedTarget() }
    }

    func discardPreparedTarget() {
        activeCaptures.removeAll()
        reader.clearPinnedTarget()
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
    private var pinnedElement: AXUIElement?
    private var pinnedWindow: AXUIElement?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func pinFocusedTarget() throws {
        guard isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }
        let system = AXUIElementCreateSystemWide()
        let focusedElement = try copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: system)
        pinnedElement = focusedElement
        pinnedWindow = (try? copyElementAttribute(kAXWindowAttribute as CFString, from: focusedElement))
            ?? focusedElement
    }

    func readPinnedSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot {
        guard isTrusted else { throw ScribeContextError.accessibilityDenied }
        guard let focusedElement = pinnedElement, let window = pinnedWindow else {
            throw ScribeContextError.noFocusedTarget
        }
        return try snapshot(
            focusedElement: focusedElement,
            window: window,
            includeSelection: includeSelection
        )
    }

    func readCurrentFocusSnapshot(includeSelection: Bool) throws -> ScribeAccessibilityReadSnapshot {
        guard isTrusted else { throw ScribeContextError.accessibilityDenied }
        let (focusedElement, window) = try currentFocusedElementAndWindow()
        return try snapshot(
            focusedElement: focusedElement,
            window: window,
            includeSelection: includeSelection
        )
    }

    private func snapshot(
        focusedElement: AXUIElement,
        window: AXUIElement,
        includeSelection: Bool
    ) throws -> ScribeAccessibilityReadSnapshot {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success,
              processIdentifier > 0 else {
            throw ScribeContextError.noFocusedTarget
        }

        let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: focusedElement)
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)
        let isSecureField = role == (kAXSecureTextFieldSubrole as String)
            || subrole == (kAXSecureTextFieldSubrole as String)

        let selectedText: String?
        let selectionIdentity: ScribeSelectionIdentity?
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
            selectionIdentity = copySelectedTextRange(from: focusedElement)
        } else {
            selectedText = nil
            selectionIdentity = copySelectedTextRange(from: focusedElement)
        }

        return ScribeAccessibilityReadSnapshot(
            target: ScribeTargetIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            ),
            verificationToken: "\(processIdentifier):\(CFHash(window)):\(CFHash(focusedElement))",
            selectedText: selectedText,
            isSecureField: isSecureField,
            selectionIdentity: selectionIdentity,
            recognitionSignature: TargetRecognitionSignature(
                role: role,
                subrole: subrole,
                identifierAncestry: copyIdentifierAncestry(from: focusedElement)
            )
        )
    }

    func replacePinnedSelection(with text: String) throws -> Bool {
        guard isTrusted else { throw ScribeContextError.accessibilityDenied }
        guard let pinnedElement else { throw ScribeContextError.noFocusedTarget }
        let status = AXUIElementSetAttributeValue(
            pinnedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        switch status {
        case .success:
            return true
        case .attributeUnsupported, .notImplemented:
            return false
        default:
            throw ScribeContextError.targetChanged
        }
    }

    func clearPinnedTarget() {
        pinnedElement = nil
        pinnedWindow = nil
    }

    private func copySelectedTextRange(from element: AXUIElement) -> ScribeSelectionIdentity? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let rangeValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return ScribeSelectionIdentity(location: range.location, length: range.length)
    }

    private func currentFocusedElementAndWindow() throws -> (AXUIElement, AXUIElement) {
        let system = AXUIElementCreateSystemWide()
        let focusedElement = try copyElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: system
        )
        let window = (try? copyElementAttribute(kAXWindowAttribute as CFString, from: focusedElement))
            ?? focusedElement
        return (focusedElement, window)
    }

    private func copyIdentifierAncestry(from element: AXUIElement) -> [String] {
        var identifiers: [String] = []
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let candidate = current else { break }
            if let identifier = copyStringAttribute(kAXIdentifierAttribute as CFString, from: candidate),
               !identifier.isEmpty {
                identifiers.append(identifier)
            }
            current = try? copyElementAttribute(kAXParentAttribute as CFString, from: candidate)
        }
        return identifiers
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
