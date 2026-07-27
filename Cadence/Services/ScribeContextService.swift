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
            return "This Compose request has ended. Start a new request to continue."
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
    func restorePinnedTargetFocus(processIdentifier: pid_t) throws
    func clearPinnedTarget()
}

extension ScribeAccessibilityReading {
    func readCurrentFocusSnapshot() throws -> ScribeAccessibilityReadSnapshot {
        try readPinnedSnapshot()
    }

    func restorePinnedTargetFocus(processIdentifier _: pid_t) throws {}
}

@MainActor
protocol ScribeContextServing: AnyObject {
    func prepareTarget() async throws
    func capture() throws -> ScribeContextSnapshot
    func verifyTarget(for capture: ScribeContextSnapshot) throws -> Bool
    func insert(_ text: String, for capture: ScribeContextSnapshot) async throws -> Bool
    func clear(_ capture: ScribeContextSnapshot)
    func discardPreparedTarget()
}

@MainActor
final class ScribeContextService: ScribeContextServing {
    nonisolated static let maximumContextUTF8Bytes = 32 * 1_024
    nonisolated static let defaultInsertionFocusSettleDelay: Duration = .milliseconds(500)

    private let reader: ScribeAccessibilityReading
    private let processAuthority: any RuntimeApplicationProcessAuthorizing
    private let targetAuthority: (any ApplicationTargetAuthorizing)?
    private let transientControlProcessIdentifier: pid_t
    private let insertionFocusSettleDelay: Duration
    private let textInsertion: TextInsertionServing
    private enum CaptureMode {
        case accessibilityElement
        case application
    }

    private struct ActiveCapture {
        let verificationToken: String
        let runtimeIdentity: ApplicationProcessIdentity
        let mode: CaptureMode
    }

    private var preparedApplicationTarget: ApplicationTargetCapture?
    private var activeCaptures: [UUID: ActiveCapture] = [:]

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
        targetAuthority: (any ApplicationTargetAuthorizing)? = nil,
        transientControlProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        insertionFocusSettleDelay: Duration = ScribeContextService.defaultInsertionFocusSettleDelay,
        textInsertion: TextInsertionServing = TextInsertionService()
    ) {
        self.reader = reader
        self.processAuthority = processAuthority
        self.targetAuthority = targetAuthority
        self.transientControlProcessIdentifier = transientControlProcessIdentifier
        self.insertionFocusSettleDelay = insertionFocusSettleDelay
        self.textInsertion = textInsertion
    }

    func prepareTarget() async throws {
        guard reader.isTrusted else { throw ScribeContextError.accessibilityDenied }
        preparedApplicationTarget = nil
        if let targetAuthority {
            do {
                preparedApplicationTarget = try await targetAuthority.capture(
                    source: .scribeAccessibility
                )
            } catch ApplicationTargetAuthorityError.noExternalTarget {
                throw ScribeContextError.noFocusedTarget
            } catch ApplicationTargetAuthorityError.targetChanged {
                throw ScribeContextError.targetChanged
            }
            // Exact AX focus is preferred for restoration, but Scribe does not
            // read selected text. A known frontmost application is therefore
            // sufficient to begin when an editor does not publish a focused
            // accessibility element.
            do {
                try reader.pinFocusedTarget()
            } catch ScribeContextError.noFocusedTarget {
                reader.clearPinnedTarget()
            }
        } else {
            try reader.pinFocusedTarget()
        }
    }

    func capture() throws -> ScribeContextSnapshot {
        guard reader.isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }

        // Scribe is dictation-only.  In particular, never ask AX for selected
        // text: selection can contain unrelated private content and is not an
        // input to the model or insertion operation.
        let pinned = try? reader.readPinnedSnapshot()
        let prepared = preparedApplicationTarget
        let raw = pinned.flatMap { snapshot -> ScribeAccessibilityReadSnapshot? in
            guard let prepared else { return snapshot }
            guard snapshot.target.processIdentifier == prepared.process.processIdentifier,
                  snapshot.target.bundleIdentifier == nil
                    || snapshot.target.bundleIdentifier == prepared.process.bundleIdentifier
            else { return nil }
            return snapshot
        }
        guard raw != nil || prepared != nil else {
            throw ScribeContextError.noFocusedTarget
        }

        let captureID = UUID()
        let expectedProcessIdentifier = raw?.target.processIdentifier
            ?? prepared!.process.processIdentifier
        let expectedBundleIdentifier = raw?.target.bundleIdentifier
            ?? prepared?.process.bundleIdentifier
        let resolved = try processAuthority.capture(
            processIdentifier: expectedProcessIdentifier,
            expectedBundleIdentifier: expectedBundleIdentifier
        )
        let monitorTarget = prepared.map {
            ApplicationTargetCapture(
                id: captureID,
                process: $0.process,
                identityRevision: $0.identityRevision,
                captureRevision: $0.captureRevision,
                source: .scribeAccessibility,
                displayName: $0.displayName
            )
        } ?? targetAuthority?.enrichCapture(
            id: captureID,
            processIdentifier: expectedProcessIdentifier,
            bundleIdentifier: expectedBundleIdentifier
        )
        let exactMonitorTarget = monitorTarget.flatMap {
            $0.process.processIdentifier == resolved.identity.processIdentifier
                && $0.process.bundleIdentifier == resolved.identity.bundleIdentifier
                && $0.process.bundleURL == resolved.identity.bundleURL
                && $0.process.launchDate == resolved.identity.launchDate
                ? $0 : nil
        }
        let applicationTarget = exactMonitorTarget ?? ApplicationTargetCapture(
            id: captureID, process: resolved.identity,
            identityRevision: 0, captureRevision: 0,
            source: .scribeAccessibility, displayName: resolved.displayName
        )
        let target = raw?.target ?? ScribeTargetIdentity(
            processIdentifier: expectedProcessIdentifier,
            bundleIdentifier: expectedBundleIdentifier
        )
        let verificationToken = raw?.verificationToken
            ?? "application:\(captureID.uuidString)"
        let capture = ScribeContextSnapshot(
            id: captureID,
            target: target,
            scope: .none,
            selectedText: "",
            verificationToken: verificationToken,
            // Dictation-only target capture must not retain selection/caret
            // identity even if an accessibility source happens to expose it.
            selectionIdentity: nil,
            recognitionSignature: raw?.recognitionSignature,
            applicationTarget: applicationTarget
        )
        activeCaptures[capture.id] = ActiveCapture(
            verificationToken: verificationToken,
            runtimeIdentity: resolved.identity,
            mode: raw == nil ? .application : .accessibilityElement
        )
        preparedApplicationTarget = nil
        return capture
    }

    func verifyTarget(for capture: ScribeContextSnapshot) throws -> Bool {
        try verifyTarget(for: capture, allowingTransientControlFocus: false)
    }

    private func verifyTarget(
        for capture: ScribeContextSnapshot,
        allowingTransientControlFocus: Bool
    ) throws -> Bool {
        guard let activeCapture = activeCaptures[capture.id],
              activeCapture.verificationToken == capture.verificationToken else {
            throw ScribeContextError.captureCleared
        }
        guard reader.isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }

        guard processAuthority.verify(activeCapture.runtimeIdentity) else {
            throw ScribeContextError.targetChanged
        }
        if activeCapture.mode == .application {
            return true
        }

        let current = try reader.readCurrentFocusSnapshot()
        let originalTargetIsFocused = current.target == capture.target
            && current.verificationToken == capture.verificationToken
            && current.recognitionSignature == capture.recognitionSignature
        let transientCadenceControlIsFocused = allowingTransientControlFocus
            && current.target.processIdentifier == transientControlProcessIdentifier
        guard originalTargetIsFocused || transientCadenceControlIsFocused else {
            throw ScribeContextError.targetChanged
        }
        return true
    }

    func insert(_ text: String, for capture: ScribeContextSnapshot) async throws -> Bool {
        guard let activeCapture = try verifyInsertionAuthority(for: capture) else {
            return false
        }
        if activeCapture.mode == .application {
            guard let targetAuthority,
                  targetAuthority.activate(capture.applicationTarget) else {
                throw ScribeContextError.targetChanged
            }
            try await Task.sleep(for: insertionFocusSettleDelay)
            guard processAuthority.verify(activeCapture.runtimeIdentity) else {
                throw ScribeContextError.targetChanged
            }
            do {
                try await targetAuthority.verify(capture.applicationTarget)
            } catch {
                throw ScribeContextError.targetChanged
            }
            try await textInsertion.insert(text)
            return true
        }
        try reader.restorePinnedTargetFocus(
            processIdentifier: capture.applicationTarget.process.processIdentifier
        )
        try await Task.sleep(for: insertionFocusSettleDelay)
        guard processAuthority.verify(activeCapture.runtimeIdentity) else {
            throw ScribeContextError.targetChanged
        }
        // Activating an app can legitimately rebuild its focused AX wrapper,
        // changing the system-wide verification token even though the pinned
        // element remains valid. Reassert the exact pinned element instead of
        // rejecting on that transient wrapper identity.
        try reader.restorePinnedTargetFocus(
            processIdentifier: capture.applicationTarget.process.processIdentifier
        )
        let restoredFocus = try reader.readCurrentFocusSnapshot()
        guard restoredFocus.target.processIdentifier
                == capture.target.processIdentifier,
              processAuthority.verify(activeCapture.runtimeIdentity) else {
            throw ScribeContextError.targetChanged
        }

        // Some editors report a successful AXSelectedText write while silently
        // ignoring it. Use the same Unicode event path as normal dictation once
        // the exact captured process has been restored and revalidated.
        try await textInsertion.insert(text)
        return true
    }

    private func verifyInsertionAuthority(
        for capture: ScribeContextSnapshot
    ) throws -> ActiveCapture? {
        guard let activeCapture = activeCaptures[capture.id],
              activeCapture.verificationToken == capture.verificationToken else {
            throw ScribeContextError.captureCleared
        }
        guard reader.isTrusted else {
            throw ScribeContextError.accessibilityDenied
        }

        guard processAuthority.verify(activeCapture.runtimeIdentity) else {
            throw ScribeContextError.targetChanged
        }
        if activeCapture.mode == .application {
            return activeCapture
        }

        let current = try reader.readCurrentFocusSnapshot()
        let capturedProcessIsFocused = current.target.processIdentifier
            == capture.target.processIdentifier
        let cadenceReviewIsFocused = current.target.processIdentifier
            == transientControlProcessIdentifier
        guard capturedProcessIsFocused || cadenceReviewIsFocused,
              processAuthority.verify(activeCapture.runtimeIdentity) else {
            throw ScribeContextError.targetChanged
        }
        return activeCapture
    }

    func clear(_ capture: ScribeContextSnapshot) {
        if let activeCapture = activeCaptures.removeValue(forKey: capture.id) {
            processAuthority.release(activeCapture.runtimeIdentity)
        }
        if activeCaptures.isEmpty { reader.clearPinnedTarget() }
    }

    func discardPreparedTarget() {
        preparedApplicationTarget = nil
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
        let focusedElement: AXUIElement
        do {
            let system = AXUIElementCreateSystemWide()
            focusedElement = try copyElementAttribute(
                kAXFocusedUIElementAttribute as CFString,
                from: system
            )
        } catch {
            // Some WebKit/Electron editors briefly omit the system-wide
            // focused-element attribute even while their application remains
            // frontmost. Query that exact application as a fallback instead of
            // incorrectly reporting that Cadence cannot identify the target.
            guard let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else {
                throw ScribeContextError.noFocusedTarget
            }
            focusedElement = try copyElementAttribute(
                kAXFocusedUIElementAttribute as CFString,
                from: AXUIElementCreateApplication(frontmost.processIdentifier)
            )
        }
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

    func restorePinnedTargetFocus(processIdentifier: pid_t) throws {
        guard isTrusted else { throw ScribeContextError.accessibilityDenied }
        guard let pinnedElement, let pinnedWindow else {
            throw ScribeContextError.noFocusedTarget
        }

        var pinnedProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(pinnedElement, &pinnedProcessIdentifier) == .success,
              pinnedProcessIdentifier == processIdentifier,
              let application = NSRunningApplication(
                processIdentifier: processIdentifier
              ) else {
            throw ScribeContextError.targetChanged
        }

        application.activate(options: [])
        _ = AXUIElementPerformAction(
            pinnedWindow,
            kAXRaiseAction as CFString
        )
        _ = AXUIElementSetAttributeValue(
            pinnedWindow,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            pinnedWindow,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        let focusStatus = AXUIElementSetAttributeValue(
            pinnedElement,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        // Web and Electron editors frequently rebuild their AX wrapper while
        // Scribe is running. Activation/raise can still restore the correct
        // process even when the stale element refuses this advisory focus
        // write; the caller re-reads and verifies the actual focused PID
        // before emitting any Unicode events.
        _ = focusStatus
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
