import Foundation

enum ComposeTextEditApplicationIdentity {
    static let bundleIdentifier = "com.apple.TextEdit"
    static let bundleURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        .standardizedFileURL.resolvingSymlinksInPath()
}

/// Only affirmative settings metadata is stored. Selected text and generated
/// drafts are never part of these preferences.
struct ComposeSelectedTextContextPreferences: Equatable, Sendable {
    static let currentDisclosureRevision = 1
    var isEnabled = false
    var textEditAllowed = false
    var disclosureRevision = currentDisclosureRevision

    var permitsTextEditCapture: Bool {
        isEnabled && textEditAllowed && disclosureRevision == Self.currentDisclosureRevision
    }
}

enum ComposeSelectedTextEligibilityPolicy {
    /// Provisional native TextEdit support. A bundle preference alone never
    /// enables an unknown app, browser surface, or unknown focused element.
    static func permits(_ capture: ScribeContextSnapshot) -> Bool {
        guard capture.target.bundleIdentifier == ComposeTextEditApplicationIdentity.bundleIdentifier,
              capture.applicationTarget.process.bundleIdentifier == ComposeTextEditApplicationIdentity.bundleIdentifier,
              capture.applicationTarget.process.bundleURL == ComposeTextEditApplicationIdentity.bundleURL,
              let signature = capture.recognitionSignature,
              ["AXTextArea", "AXTextField"].contains(signature.role ?? ""),
              signature.subrole != "AXSecureTextField" else { return false }
        return true
    }
}
