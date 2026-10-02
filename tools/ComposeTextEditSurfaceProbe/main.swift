import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
@testable import Cadence

private let textEditProbeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeTextEditSurfaceProbe"
)

/// A standalone, synthetic-only development probe. It launches a fresh
/// TextEdit process and reads only the document it created for this run.
@main
struct ComposeTextEditSurfaceProbe {
    private static let applicationURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        .standardizedFileURL.resolvingSymlinksInPath()
    private static let initialText = "SYNTHETIC TextEdit document for Cadence insertion verification.\n"
    private static let insertedText = "SYNTHETIC appended."
    private static let replacementText = "SYNTHETIC revised."
    @MainActor private static var readbackDiagnostic = "none"

    private enum Failure: String, Error {
        case blockedDesktop, accessibilityDenied, invalidFixture, wrongApplication
        case noFocusedEditor, cannotSetCaret, identityRejected
        case insertionRejected, selectedCaptureRejected, selectedReplacementRejected
        case insertionReadbackMismatch, replacementReadbackMismatch
    }

    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("status=invalid_arguments")
            exit(2)
        }
        do {
            try await run(documentURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("status=passed identity=true insertion=true exact_readback=true selection=true exact_replacement=true")
        } catch let failure as Failure {
            print("status=failed reason=\(failure.rawValue) readback=\(readbackDiagnostic)")
            exit(1)
        } catch {
            print("status=failed reason=platform")
            exit(1)
        }
    }

    @MainActor
    private static func run(documentURL: URL) async throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        guard session["kCGSessionLoginDoneKey"] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else {
            throw Failure.blockedDesktop
        }
        guard AXIsProcessTrusted() else { throw Failure.accessibilityDenied }
        let document = documentURL.standardizedFileURL.resolvingSymlinksInPath()
        guard document.isFileURL,
              (try? String(contentsOf: document, encoding: .utf8)) == initialText else {
            throw Failure.invalidFixture
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let app = try await NSWorkspace.shared.open(
            [document], withApplicationAt: applicationURL, configuration: configuration
        )
        defer { app.terminate() }
        guard app.bundleIdentifier == ScribeTextEditDocumentIdentityAdapter.bundleIdentifier,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == applicationURL else {
            throw Failure.wrongApplication
        }

        let editor = try await waitForOwnedEditor(app: app, document: document)
        var caret = CFRange(location: initialText.utf16.count, length: 0)
        guard let selectedRange = AXValueCreate(.cfRange, &caret),
              AXUIElementSetAttributeValue(
                  editor, kAXSelectedTextRangeAttribute as CFString, selectedRange
              ) == .success else { throw Failure.cannotSetCaret }

        let process = try RuntimeApplicationProcessAuthority().capture(
            processIdentifier: app.processIdentifier,
            expectedBundleIdentifier: ScribeTextEditDocumentIdentityAdapter.bundleIdentifier
        ).identity
        let adapter = ScribeTextEditDocumentIdentityAdapter()
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        guard let binding = adapter.captureBinding(actionID: UUID(), process: process),
              case .verified = resolver.resolve(adapterID: adapter.registration.adapterID, for: binding) else {
            throw Failure.identityRejected
        }

        let service = ScribeContextService()
        try await service.prepareTarget()
        let capture = try service.capture()
        defer { service.clear(capture) }
        guard capture.target.processIdentifier == app.processIdentifier,
              try service.verifyTarget(for: capture),
              try await service.insert(insertedText, for: capture) else {
            throw Failure.insertionRejected
        }

        // A successful event post is only an attempt. TextEdit's own AX value
        // must reach the exact synthetic result and remain so after settling.
        try await waitForExactText(
            initialText + insertedText, in: editor, failure: .insertionReadbackMismatch
        )

        var selected = CFRange(location: initialText.utf16.count, length: insertedText.utf16.count)
        guard let selectedRange = AXValueCreate(.cfRange, &selected),
              AXUIElementSetAttributeValue(
                  editor, kAXSelectedTextRangeAttribute as CFString, selectedRange
              ) == .success else { throw Failure.cannotSetCaret }
        let selectedService = ScribeContextService()
        try await selectedService.prepareTarget()
        let selectedCapture = try selectedService.capture()
        defer { selectedService.clear(selectedCapture) }
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true),
            permissions: { .init(accessibility: true) }
        )
        let actionID = UUID()
        defer { controller.clear(actionID: actionID) }
        controller.beginCapture(
            actionID: actionID, capture: selectedCapture, destination: .legacyLocal
        )
        guard let source = await controller.selectedText(for: actionID),
              source.selectedText == insertedText,
              await controller.revalidateSelection(source) == .current else {
            throw Failure.selectedCaptureRejected
        }
        guard try await selectedService.insert(
            replacementText, for: selectedCapture,
            selectedTextPreflight: {
                await controller.revalidateSelection(source) == .current
            }
        ) else { throw Failure.selectedReplacementRejected }
        try await waitForExactText(
            initialText + replacementText, in: editor, failure: .replacementReadbackMismatch
        )
    }

    @MainActor
    private static func waitForExactText(
        _ expected: String, in editor: AXUIElement, failure: Failure
    ) async throws {
        for _ in 0..<80 {
            if text(kAXValueAttribute as CFString, from: editor) == expected {
                try await Task.sleep(for: .milliseconds(150))
                guard text(kAXValueAttribute as CFString, from: editor) == expected else {
                    readbackDiagnostic = "changedAfterSettle"
                    throw failure
                }
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let observed = text(kAXValueAttribute as CFString, from: editor)
        if let observed {
            if observed == initialText {
                readbackDiagnostic = "unchanged"
            } else if expected.hasPrefix(observed) {
                readbackDiagnostic = "partialPrefix"
            } else if observed.hasPrefix(expected) {
                readbackDiagnostic = "extraSuffix"
            } else {
                readbackDiagnostic = "differentText"
            }
        } else {
            readbackDiagnostic = "missingAXValue"
        }
        throw failure
    }

    @MainActor
    private static func waitForOwnedEditor(
        app: NSRunningApplication, document: URL
    ) async throws -> AXUIElement {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<100 {
            _ = app.activate()
            try await Task.sleep(for: .milliseconds(25))
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
               let editor = element(kAXFocusedUIElementAttribute as CFString, from: application),
               text(kAXRoleAttribute as CFString, from: editor) == "AXTextArea",
               let window = element(kAXWindowAttribute as CFString, from: editor),
               let focusedWindow = element(kAXFocusedWindowAttribute as CFString, from: application),
               CFEqual(window, focusedWindow) {
                let observedDocument = text(kAXDocumentAttribute as CFString, from: editor)
                    ?? text(kAXDocumentAttribute as CFString, from: window)
                if observedDocument.flatMap(URL.init(string:))?
                    .standardizedFileURL.resolvingSymlinksInPath() == document {
                    return editor
                }
            }
        }
        throw Failure.noFocusedEditor
    }

    private static func element(_ name: CFString, from parent: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, name, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func text(_ name: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? String
    }
}
