import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation
import OSLog

private let scribeTextEditIdentityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribeTextEditIdentity"
)

/// The document identifier is a digest of a saved regular file's canonical
/// path, device, inode, and creation time. No path or document content leaves
/// this adapter. It is still metadata, not an encrypted secret.
struct ScribeTextEditDocumentObservation: Equatable, Sendable {
    let process: ApplicationProcessIdentity
    let windowIncarnation: UUID
    let navigationRevision: UUID
    let documentID: ScribeConversationStableID
}

/// A saved-document identity can originate only from TextEdit's focused editor,
/// never from search, navigation, or an unrelated window in the same process.
struct ScribeTextEditSurfaceSignature: Equatable, Sendable {
    let focusedRole: String?
    let editorBelongsToProcess: Bool
    let windowBelongsToProcess: Bool
    let editorWindowIsFocused: Bool

    var permitsDocumentIdentity: Bool {
        focusedRole == "AXTextArea"
            && editorBelongsToProcess
            && windowBelongsToProcess
            && editorWindowIsFocused
    }
}

/// A TextEdit window can continue displaying the old document after another
/// process replaces its file at the same path. Once its observed file identity
/// changes, the window cannot be rebound to that replacement's memory scope.
@MainActor
final class ScribeTextEditWindowIdentityFence {
    let documentID: ScribeConversationStableID
    let navigationRevision = UUID()
    private(set) var invalidated = false

    init(documentID: ScribeConversationStableID) {
        self.documentID = documentID
    }

    func accepts(_ currentDocument: ScribeConversationStableID?) -> Bool {
        guard !invalidated, let currentDocument else { return false }
        guard currentDocument == documentID else {
            invalidated = true
            return false
        }
        return true
    }
}

@MainActor
protocol ScribeTextEditDocumentIdentityReading {
    func capture(process: ApplicationProcessIdentity) -> ScribeTextEditDocumentObservation?
    func refresh(for binding: ScribeConversationActionBinding) -> ScribeTextEditDocumentObservation?
}

/// A first native document integration. The app does not register it by
/// default; a caller must explicitly capture a binding before resolution.
/// Neither a title nor an unsaved document can establish a memory scope.
@MainActor
final class ScribeTextEditDocumentIdentityAdapter: ScribeConversationBindingCapturing {
    static let bundleIdentifier = ComposeTextEditApplicationIdentity.bundleIdentifier
    static let bundleURL = ComposeTextEditApplicationIdentity.bundleURL
    static let adapterID = ScribeConversationStableID(rawValue: "textedit-saved-document-v1")!

    static let preferenceRegistration = ScribeConversationAdapterRegistration(
        adapterID: adapterID,
        schemaVersion: 1,
        source: .nativeIntegration,
        hostBundleIdentifier: bundleIdentifier,
        applicationID: ScribeConversationStableID(rawValue: bundleIdentifier)!
    )
    let registration = preferenceRegistration

    private let reader: any ScribeTextEditDocumentIdentityReading
    private let localUserID: UInt32

    init(
        reader: (any ScribeTextEditDocumentIdentityReading)? = nil,
        localUserID: UInt32 = getuid()
    ) {
        self.reader = reader ?? SystemScribeTextEditDocumentIdentityReader()
        self.localUserID = localUserID
    }

    func captureBinding(actionID: UUID, process: ApplicationProcessIdentity) -> ScribeConversationActionBinding? {
        guard process.bundleIdentifier == Self.bundleIdentifier,
              process.bundleURL == Self.bundleURL,
              let observation = reader.capture(process: process),
              observation.process == process else { return nil }
        return ScribeConversationActionBinding(
            actionID: actionID, process: process,
            windowIncarnation: observation.windowIncarnation,
            tabIncarnation: nil,
            navigationRevision: observation.navigationRevision
        )
    }

    func evidence(for binding: ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence? {
        guard binding.process.bundleIdentifier == Self.bundleIdentifier,
              binding.process.bundleURL == Self.bundleURL,
              binding.tabIncarnation == nil,
              let window = binding.windowIncarnation,
              let observation = reader.refresh(for: binding),
              observation.process == binding.process,
              observation.windowIncarnation == window,
              observation.navigationRevision == binding.navigationRevision,
              let account = ScribeConversationStableID(rawValue: "macos-uid-\(localUserID)") else {
            return nil
        }
        return .init(
            adapterID: registration.adapterID,
            schemaVersion: registration.schemaVersion,
            source: .nativeIntegration,
            binding: binding,
            confidence: .verifiedStableIdentifiers,
            privacyState: .regular,
            applicationID: registration.applicationID,
            accountID: account,
            workspaceID: .notApplicable,
            projectID: .notApplicable,
            conversationID: observation.documentID
        )
    }
}

/// Reads only Accessibility identity metadata. This source is instantiated
/// only when the adapter is explicitly used; it performs no background scan.
/// A pinned AX window is re-read on every identity check, so a navigation or
/// replacement file cannot reuse an earlier action's authority.
@MainActor
final class SystemScribeTextEditDocumentIdentityReader: ScribeTextEditDocumentIdentityReading {
    private struct WindowState {
        let process: ApplicationProcessIdentity
        let window: AXUIElement
        var editor: AXUIElement
        let incarnation: UUID
        let identityFence: ScribeTextEditWindowIdentityFence
    }

    private var windows: [WindowState] = []
    private let maximumWindows = 16
    private let messageTimeout: Float = 0.025

    func capture(process: ApplicationProcessIdentity) -> ScribeTextEditDocumentObservation? {
        guard process.bundleIdentifier == ScribeTextEditDocumentIdentityAdapter.bundleIdentifier,
              validProcess(process, requiresActive: true), AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(process.processIdentifier)
        guard let editor = element(kAXFocusedUIElementAttribute as CFString, from: application),
              let window = element(kAXWindowAttribute as CFString, from: editor),
              let focusedWindow = element(kAXFocusedWindowAttribute as CFString, from: application),
              ScribeTextEditSurfaceSignature(
                  focusedRole: string(kAXRoleAttribute as CFString, from: editor),
                  editorBelongsToProcess: belongsToProcess(editor, process),
                  windowBelongsToProcess: belongsToProcess(window, process),
                  editorWindowIsFocused: CFEqual(window, focusedWindow)
              ).permitsDocumentIdentity else { return nil }

        windows.removeAll { !validProcess($0.process, requiresActive: false) }
        if let index = windows.firstIndex(where: { $0.process == process && CFEqual($0.window, window) }) {
            guard windows[index].identityFence.accepts(documentID(window: window, editor: editor)) else {
                return nil
            }
            windows[index].editor = editor
            return observation(windows[index])
        }
        guard let documentID = documentID(window: window, editor: editor) else { return nil }
        let state = WindowState(process: process, window: window, editor: editor,
                                incarnation: UUID(), identityFence: .init(documentID: documentID))
        windows.append(state)
        if windows.count > maximumWindows { windows.removeFirst(windows.count - maximumWindows) }
        return observation(state)
    }

    func refresh(for binding: ScribeConversationActionBinding) -> ScribeTextEditDocumentObservation? {
        guard let incarnation = binding.windowIncarnation,
              binding.tabIncarnation == nil,
              let state = windows.first(where: { $0.incarnation == incarnation && $0.process == binding.process }),
              validProcess(state.process, requiresActive: false), AXIsProcessTrusted(),
              windowIsStillOpen(state.window, in: state.process),
              belongsToProcess(state.window, state.process),
              belongsToProcess(state.editor, state.process),
              let editorWindow = element(kAXWindowAttribute as CFString, from: state.editor),
              CFEqual(editorWindow, state.window),
              state.identityFence.accepts(documentID(window: state.window, editor: state.editor)) else { return nil }
        return observation(state)
    }

    private func observation(_ state: WindowState) -> ScribeTextEditDocumentObservation {
        .init(process: state.process, windowIncarnation: state.incarnation,
              navigationRevision: state.identityFence.navigationRevision,
              documentID: state.identityFence.documentID)
    }

    private func validProcess(_ process: ApplicationProcessIdentity, requiresActive: Bool) -> Bool {
        guard let launchDate = process.launchDate,
              process.bundleURL == ScribeTextEditDocumentIdentityAdapter.bundleURL,
              let app = NSRunningApplication(processIdentifier: process.processIdentifier),
              !app.isTerminated,
              !requiresActive || app.isActive,
              app.bundleIdentifier == process.bundleIdentifier,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == process.bundleURL,
              app.launchDate == launchDate else { return false }
        return true
    }

    private func belongsToProcess(_ element: AXUIElement, _ process: ApplicationProcessIdentity) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == process.processIdentifier
    }

    private func windowIsStillOpen(_ window: AXUIElement, in process: ApplicationProcessIdentity) -> Bool {
        let application = AXUIElementCreateApplication(process.processIdentifier)
        guard let openWindows = attribute(kAXWindowsAttribute as CFString, from: application) as? [AXUIElement],
              openWindows.count <= 128 else { return false }
        return openWindows.contains { CFEqual($0, window) }
    }

    private func element(_ name: CFString, from parent: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, from: parent), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func string(_ name: CFString, from element: AXUIElement) -> String? {
        attribute(name, from: element) as? String
    }

    private func attribute(_ name: CFString, from element: AXUIElement) -> CFTypeRef? {
        guard AXUIElementSetMessagingTimeout(element, messageTimeout) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func documentID(window: AXUIElement, editor: AXUIElement) -> ScribeConversationStableID? {
        let windowDocument = string(kAXDocumentAttribute as CFString, from: window)
        let editorDocument = string(kAXDocumentAttribute as CFString, from: editor)
        guard let document = windowDocument ?? editorDocument else { return nil }
        let stable = Self.stableDocumentID(documentURLString: document)
        if let windowDocument, let editorDocument {
            guard Self.stableDocumentID(documentURLString: windowDocument)
                    == Self.stableDocumentID(documentURLString: editorDocument) else { return nil }
        }
        return stable
    }

    static func stableDocumentID(documentURLString: String) -> ScribeConversationStableID? {
        guard documentURLString.utf8.count <= 4_096,
              let url = URL(string: documentURLString), url.isFileURL,
              url.query == nil, url.fragment == nil,
              url.host == nil || url.host == "localhost" else { return nil }
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !file.hasDirectoryPath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date else { return nil }
        let components = [
            "textedit-file-v1", file.path, device.stringValue, inode.stringValue,
            String(created.timeIntervalSinceReferenceDate.bitPattern)
        ]
        var bytes = Data()
        for component in components {
            let value = Data(component.utf8)
            bytes.append(contentsOf: "\(value.count):".utf8)
            bytes.append(value)
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ScribeConversationStableID(rawValue: digest)
    }
}
