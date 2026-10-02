import Foundation
import CoreGraphics

/// The window identity is supplied by a certified adapter before capture. A
/// title, screen coordinates, or bundle ID alone is never enough to select a
/// screenshot target.
struct ComposeScreenWindowIdentity: Equatable, Sendable {
    let windowID: UInt32
    let processIdentifier: Int32
    let bundleIdentifier: String
    /// Captured by a trusted invocation identity authority. Native capture
    /// denies nil and unverifiable launch identities. This identifies the app
    /// incarnation, not an OS-guaranteed window incarnation.
    var processIdentity: ApplicationProcessIdentity? = nil
    /// Focused-window bounds supplied by the invocation authority. A native
    /// capture must match these bounds before reading any pixels.
    var expectedFrame: CGRect? = nil
}

/// An invocation-local, exact window capture target. It intentionally has no
/// fallback to an app-wide or display-wide selection.
struct ComposeScreenContextTarget: Equatable, Sendable {
    let action: ScribeContextActionBinding
    let window: ComposeScreenWindowIdentity

    var isValid: Bool {
        window.windowID != 0
            && window.processIdentifier == action.target.processIdentifier
            && !window.bundleIdentifier.isEmpty
            && window.bundleIdentifier == action.target.bundleIdentifier
            && window.expectedFrame.map { frame in
                frame.origin.x.isFinite && frame.origin.y.isFinite
                    && frame.width.isFinite && frame.height.isFinite
                    && frame.width > 0 && frame.height > 0
            } == true
    }
}

struct ComposeScreenCaptureBudget: Equatable, Sendable {
    var timeoutMilliseconds = 500
    var maximumPixels = 4_000_000
    var maximumRecognizedLines = 80
    var maximumUTF8Bytes = 8 * 1_024
    var minimumConfidence: Float = 0.70

    var isValid: Bool {
        (1...2_000).contains(timeoutMilliseconds)
            && (1...16_000_000).contains(maximumPixels)
            && (1...200).contains(maximumRecognizedLines)
            && (1...32 * 1_024).contains(maximumUTF8Bytes)
            && minimumConfidence.isFinite && (0...1).contains(minimumConfidence)
    }
}

struct ComposeOCRLine: Equatable, Sendable {
    let text: String
    let confidence: Float
    /// Normalized image coordinates, ordered by the OCR adapter rather than
    /// treated as an identity or click target.
    let boundingBox: CGRect
}

struct ComposeOCRResult: Equatable, Sendable {
    let lines: [ComposeOCRLine]
    let isClipped: Bool
    let hasAmbiguousColumns: Bool

    init(lines: [ComposeOCRLine], isClipped: Bool, hasAmbiguousColumns: Bool = false) {
        self.lines = lines
        self.isClipped = isClipped
        self.hasAmbiguousColumns = hasAmbiguousColumns
    }
}

struct ComposeScreenContextSnapshot: Equatable, Sendable {
    let id: UUID
    let target: ComposeScreenContextTarget
    let screenText: String
    let lines: [ComposeOCRLine]
    let capturedAt: Date
    let authorization: ScribeContextAccessAuthorization
    let limitations: Set<ComposeScreenContextLimitation>
}

enum ComposeScreenContextLimitation: String, Hashable, Sendable {
    case lowConfidence
    case clipped
    case ambiguousColumns
    case lineLimit
    case byteLimit
}

enum ComposeScreenCaptureFailure: Error, Equatable, Sendable {
    case policy(ScribeContextPolicyRejection)
    case invalidTarget
    case invalidBudget
    case unsupported
    case permissionDenied
    case targetChanged
    case imageTooLarge
    case contextTooLarge
    case noRecognizedText
    case timedOut
    case cancelled
    case captureFailed
    case recognitionFailed
}

enum ComposeScreenCaptureOutcome: Equatable, Sendable {
    case captured(ComposeScreenContextSnapshot)
    case unavailable(ComposeScreenCaptureFailure)
}

enum ComposeScreenPlatformFailure: Error, Equatable, Sendable {
    case unsupported
    case permissionDenied
    case targetUnavailable
    case timedOut
    case captureFailed
    case recognitionFailed
}
