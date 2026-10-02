import AppKit
import ApplicationServices
import Foundation

/// Narrow native-field adapter. It is not registered or invoked automatically.
/// No value, title, clipboard, child collection, or document text is read.
struct SystemComposeSelectedTextReader: ComposeSelectedTextReading {
    func readSelectedText(
        from target: ComposeContentCaptureTarget,
        budget: ComposeContentCaptureBudget
    ) async throws -> ComposeSelectedTextRead {
        let work = Task.detached(priority: .utility) {
            try Self.performRead(from: target, budget: budget)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func performRead(
        from target: ComposeContentCaptureTarget,
        budget: ComposeContentCaptureBudget
    ) throws -> ComposeSelectedTextRead {
        guard budget.isValid else { throw ComposeContentCaptureFailure.invalidBudget }
        guard target.action.eligibility == .eligible else {
            throw ComposeContentCaptureFailure.unsupportedSurface
        }
        guard AXIsProcessTrusted() else {
            throw ComposeContentCaptureFailure.policy(.missingPlatformPermission)
        }
        let limiter = AttributeBudget(budget)
        let before = try inspectTarget(target, limiter: limiter)
        let rangeBefore = try selectedRange(from: before.element, limiter: limiter)
        guard rangeBefore.isValid else { throw ComposeContentCaptureFailure.invalidSelection }
        guard rangeBefore.length > 0 else { throw ComposeContentCaptureFailure.noSelection }
        // UTF-8 requires at least as many bytes as UTF-16 code units. Reject an
        // obviously oversized selection before asking AX for its text value.
        guard rangeBefore.length <= budget.maximumUTF8Bytes else {
            throw ComposeContentCaptureFailure.contextTooLarge
        }
        guard let text = try attribute(
            kAXSelectedTextAttribute as CFString, from: before.element, limiter: limiter
        ) as? String else { throw ComposeContentCaptureFailure.unsupportedAttribute }
        guard text.utf8.count <= budget.maximumUTF8Bytes else {
            throw ComposeContentCaptureFailure.contextTooLarge
        }
        let after = try inspectTarget(target, limiter: limiter)
        let rangeAfter = try selectedRange(from: after.element, limiter: limiter)
        try limiter.check()
        return ComposeSelectedTextRead(
            identityBefore: before.identity, identityAfter: after.identity,
            rangeBefore: rangeBefore, rangeAfter: rangeAfter, text: text
        )
    }

    private struct InspectedTarget {
        let identity: ComposeContentSourceIdentity
        let element: AXUIElement
    }

    private static func inspectTarget(
        _ target: ComposeContentCaptureTarget, limiter: AttributeBudget
    ) throws -> InspectedTarget {
        try limiter.check()
        let process = target.source.process
        guard let expectedLaunchDate = process.launchDate,
              let app = NSRunningApplication(processIdentifier: process.processIdentifier),
              !app.isTerminated, app.isActive,
              app.bundleIdentifier == process.bundleIdentifier,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == process.bundleURL,
              app.launchDate == expectedLaunchDate else {
            throw ComposeContentCaptureFailure.targetChanged
        }
        // A timeout on a system-wide AX object changes the process-wide AX
        // default. Use a fresh application reference and verify activation so
        // this adapter cannot alter the existing insertion service's timing.
        let application = AXUIElementCreateApplication(process.processIdentifier)
        let element = try elementAttribute(kAXFocusedUIElementAttribute as CFString, from: application, limiter: limiter)
        let window = try elementAttribute(kAXWindowAttribute as CFString, from: element, limiter: limiter)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == process.processIdentifier,
              target.action.captureID == target.source.captureID,
              target.action.target == target.source.target,
              target.source.target.bundleIdentifier == process.bundleIdentifier,
              target.source.target.processIdentifier == pid else {
            throw ComposeContentCaptureFailure.targetChanged
        }
        let token = "\(pid):\(CFHash(window)):\(CFHash(element))"
        guard token == target.source.verificationToken else {
            throw ComposeContentCaptureFailure.targetChanged
        }
        let signature = try inspectMetadata(from: element, limiter: limiter)
        guard signature == target.source.recognitionSignature else {
            throw ComposeContentCaptureFailure.targetChanged
        }
        return InspectedTarget(identity: target.source, element: element)
    }

    private static func inspectMetadata(
        from element: AXUIElement, limiter: AttributeBudget
    ) throws -> TargetRecognitionSignature {
        let role = try stringAttribute(kAXRoleAttribute as CFString, from: element, limiter: limiter)
        let subrole = try stringAttribute(kAXSubroleAttribute as CFString, from: element, limiter: limiter, optional: true)
        try rejectSecure(role: role, subrole: subrole)
        guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "") else {
            throw ComposeContentCaptureFailure.unsupportedSurface
        }
        if let editableValue = try attribute("AXEditableAncestor" as CFString, from: element, limiter: limiter, optional: true) {
            guard CFGetTypeID(editableValue) == AXUIElementGetTypeID() else {
                throw ComposeContentCaptureFailure.unsupportedSurface
            }
            let editable = unsafeDowncast(editableValue, to: AXUIElement.self)
            try rejectSecure(
                role: stringAttribute(kAXRoleAttribute as CFString, from: editable, limiter: limiter),
                subrole: stringAttribute(kAXSubroleAttribute as CFString, from: editable, limiter: limiter, optional: true)
            )
        }

        var identifiers: [String] = []
        var visited: [AXUIElement] = []
        var current = element
        for index in 0..<limiter.budget.maximumMetadataNodes {
            guard !visited.contains(where: { CFEqual($0, current) }) else {
                throw ComposeContentCaptureFailure.metadataBudgetExceeded
            }
            visited.append(current)
            let ancestorRole = try stringAttribute(kAXRoleAttribute as CFString, from: current, limiter: limiter)
            let ancestorSubrole = try stringAttribute(kAXSubroleAttribute as CFString, from: current, limiter: limiter, optional: true)
            try rejectSecure(role: ancestorRole, subrole: ancestorSubrole)
            if index < 6,
               let identifier = try stringAttribute(kAXIdentifierAttribute as CFString, from: current, limiter: limiter, optional: true),
               !identifier.isEmpty {
                identifiers.append(identifier)
            }
            if ancestorRole == "AXApplication" {
                return TargetRecognitionSignature(role: role, subrole: subrole, identifierAncestry: identifiers)
            }
            guard let parent = try attribute(kAXParentAttribute as CFString, from: current, limiter: limiter, optional: true) else {
                // A window is a valid terminal ancestry boundary on apps that
                // omit its application parent. Unknown early termination fails.
                guard ancestorRole == "AXWindow" else {
                    throw ComposeContentCaptureFailure.unsupportedSurface
                }
                return TargetRecognitionSignature(role: role, subrole: subrole, identifierAncestry: identifiers)
            }
            guard CFGetTypeID(parent) == AXUIElementGetTypeID() else {
                throw ComposeContentCaptureFailure.unsupportedSurface
            }
            current = unsafeDowncast(parent, to: AXUIElement.self)
        }
        throw ComposeContentCaptureFailure.metadataBudgetExceeded
    }

    private static func rejectSecure(role: String?, subrole: String?) throws {
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else {
            throw ComposeContentCaptureFailure.secureField
        }
    }

    private static func selectedRange(
        from element: AXUIElement, limiter: AttributeBudget
    ) throws -> ComposeSelectedTextRange {
        guard let value = try attribute(kAXSelectedTextRangeAttribute as CFString, from: element, limiter: limiter),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            throw ComposeContentCaptureFailure.unsupportedAttribute
        }
        let rangeValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(rangeValue) == .cfRange,
              AXValueGetValue(rangeValue, .cfRange, &range) else {
            throw ComposeContentCaptureFailure.invalidSelection
        }
        return ComposeSelectedTextRange(location: range.location, length: range.length)
    }

    private static func elementAttribute(
        _ name: CFString, from element: AXUIElement, limiter: AttributeBudget
    ) throws -> AXUIElement {
        guard let value = try attribute(name, from: element, limiter: limiter),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw ComposeContentCaptureFailure.unsupportedSurface
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(
        _ name: CFString, from element: AXUIElement, limiter: AttributeBudget, optional: Bool = false
    ) throws -> String? {
        guard let value = try attribute(name, from: element, limiter: limiter, optional: optional) else { return nil }
        guard let string = value as? String else { throw ComposeContentCaptureFailure.unsupportedSurface }
        return string
    }

    private static func attribute(
        _ name: CFString, from element: AXUIElement, limiter: AttributeBudget, optional: Bool = false
    ) throws -> CFTypeRef? {
        try limiter.check()
        let timeout = try limiter.messageTimeoutSeconds()
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else {
            throw ComposeContentCaptureFailure.readFailed
        }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        try limiter.check()
        if optional && (status == .attributeUnsupported || status == .noValue) { return nil }
        switch status {
        case .success: return value
        case .attributeUnsupported, .notImplemented: throw ComposeContentCaptureFailure.unsupportedAttribute
        case .noValue: throw ComposeContentCaptureFailure.noSelection
        case .invalidUIElement: throw ComposeContentCaptureFailure.targetChanged
        case .cannotComplete: throw ComposeContentCaptureFailure.timedOut
        case .apiDisabled: throw ComposeContentCaptureFailure.policy(.missingPlatformPermission)
        default: throw ComposeContentCaptureFailure.readFailed
        }
    }

    private final class AttributeBudget {
        let budget: ComposeContentCaptureBudget
        private let start = DispatchTime.now().uptimeNanoseconds

        init(_ budget: ComposeContentCaptureBudget) { self.budget = budget }

        func check() throws {
            try Task.checkCancellation()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= start, now - start < UInt64(budget.timeoutMilliseconds) * 1_000_000 else {
                throw ComposeContentCaptureFailure.timedOut
            }
        }

        func messageTimeoutSeconds() throws -> Float {
            try check()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let maximum = UInt64(budget.timeoutMilliseconds) * 1_000_000
            guard elapsed < maximum else { throw ComposeContentCaptureFailure.timedOut }
            let remaining = maximum - elapsed
            return Float(min(remaining, UInt64(budget.attributeTimeoutMilliseconds) * 1_000_000)) / 1_000_000_000
        }
    }
}
