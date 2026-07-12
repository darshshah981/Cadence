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
            return "Accessibility access is needed to verify where Cadence should write."
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
            return "Return to the original app before inserting."
        case .captureCleared:
            return "This Scribe request has ended. Start a new request to continue."
        }
    }
}

struct ScribeAccessibilityReadSnapshot: Equatable, Sendable {
    let target: ScribeTargetIdentity
    let verificationToken: String
    let recognitionSignature: TargetRecognitionSignature?

    init(
        target: ScribeTargetIdentity,
        verificationToken: String,
        recognitionSignature: TargetRecognitionSignature? = nil
    ) {
        self.target = target
        self.verificationToken = verificationToken
        self.recognitionSignature = recognitionSignature
    }
}

@MainActor
protocol ScribeAccessibilityReading: AnyObject {
    var isTrusted: Bool { get }
    func pinFocusedTarget() throws
    func readPinnedSnapshot() throws -> ScribeAccessibilityReadSnapshot
    func readCurrentFocusSnapshot() throws -> ScribeAccessibilityReadSnapshot
    func replacePinnedSelection(with text: String) throws -> Bool
    func clearPinnedTarget()
}

extension ScribeAccessibilityReading {
    func readCurrentFocusSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        try readPinnedSnapshot()
    }
}

@MainActor
protocol ScribeContextServing: AnyObject {
    func prepareTarget() throws
    func capture() throws -> ScribeContextSnapshot
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

    func capture() throws -> ScribeContextSnapshot {
        guard reader.isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }

        // Scribe is dictation-only.  In particular, never ask AX for selected
        // text: selection can contain unrelated private content and is not an
        // input to the model or insertion operation.
        let raw = try reader.readPinnedSnapshot()

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
            scope: .none,
            selectedText: "",
            verificationToken: raw.verificationToken,
            // Dictation-only target capture must not retain selection/caret
            // identity even if an accessibility source happens to expose it.
            selectionIdentity: nil,
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

        let current = try reader.readCurrentFocusSnapshot()
        guard current.target == capture.target,
              current.verificationToken == capture.verificationToken,
              current.recognitionSignature == capture.recognitionSignature else {
            throw ScribeContextError.targetChanged
        }
        if !processAuthority.verify(capture.applicationTarget.process) {
            throw ScribeContextError.targetChanged
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

    func readPinnedSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        guard isTrusted else { throw ScribeContextError.accessibilityDenied }
        guard let focusedElement = pinnedElement, let window = pinnedWindow else {
            throw ScribeContextError.noFocusedTarget
        }
        return try snapshot(
            focusedElement: focusedElement,
            window: window,
        )
    }

    func readCurrentFocusSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        guard isTrusted else { throw ScribeContextError.accessibilityDenied }
        let (focusedElement, window) = try currentFocusedElementAndWindow()
        return try snapshot(
            focusedElement: focusedElement,
            window: window,
        )
    }

    private func snapshot(
        focusedElement: AXUIElement,
        window: AXUIElement
    ) throws -> ScribeAccessibilityReadSnapshot {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success,
              processIdentifier > 0 else {
            throw ScribeContextError.noFocusedTarget
        }

        let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: focusedElement)
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: focusedElement)

        return ScribeAccessibilityReadSnapshot(
            target: ScribeTargetIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            ),
            verificationToken: "\(processIdentifier):\(CFHash(window)):\(CFHash(focusedElement))",
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
