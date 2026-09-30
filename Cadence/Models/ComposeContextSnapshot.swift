import Foundation

/// UTF-16 offsets match Accessibility's CFRange contract. They are not Swift
/// character offsets and must never be used to slice a String directly.
struct ComposeSelectedTextRange: Equatable, Sendable {
    let location: Int
    let length: Int

    var isValid: Bool {
        location >= 0 && length >= 0 && !location.addingReportingOverflow(length).overflow
    }
}

struct ComposeContentSourceIdentity: Equatable, Sendable {
    let captureID: UUID
    let target: ScribeTargetIdentity
    let process: ApplicationProcessIdentity
    let verificationToken: String
    let recognitionSignature: TargetRecognitionSignature?
}

/// The insertion target remains owned by ScribeContextService. This value
/// identifies the one invocation from which content may be read; it cannot
/// activate an app, change focus, or select an insertion destination.
struct ComposeContentCaptureTarget: Equatable, Sendable {
    let action: ScribeContextActionBinding
    let source: ComposeContentSourceIdentity

    init(action: ScribeContextActionBinding, source: ComposeContentSourceIdentity) {
        self.action = action
        self.source = source
    }

    init(action: ScribeContextActionBinding, context: ScribeContextSnapshot) {
        self.action = action
        self.source = ComposeContentSourceIdentity(
            captureID: context.id,
            target: context.target,
            process: context.applicationTarget.process,
            verificationToken: context.verificationToken,
            recognitionSignature: context.recognitionSignature
        )
    }
}

struct ComposeContentCaptureBudget: Equatable, Sendable {
    var maximumUTF8Bytes = 8 * 1_024
    var timeoutMilliseconds = 200
    var attributeTimeoutMilliseconds = 20
    var maximumMetadataNodes = 8

    var isValid: Bool {
        (1...32 * 1_024).contains(maximumUTF8Bytes)
            && (1...1_000).contains(timeoutMilliseconds)
            && (1...50).contains(attributeTimeoutMilliseconds)
            && attributeTimeoutMilliseconds <= timeoutMilliseconds
            && (1...16).contains(maximumMetadataNodes)
    }
}

/// The reader must validate live process, focus, window, and secure metadata
/// before reading content, then repeat identity and selected-range checks.
struct ComposeSelectedTextRead: Equatable, Sendable {
    let identityBefore: ComposeContentSourceIdentity
    let identityAfter: ComposeContentSourceIdentity
    let rangeBefore: ComposeSelectedTextRange
    let rangeAfter: ComposeSelectedTextRange
    let text: String
}

enum ComposeContextCompleteness: Equatable, Sendable {
    /// Exact selected range only. This never claims the surrounding document
    /// or conversation is complete, and no silently truncated result is used.
    case completeSelectedRange
}

/// Ephemeral local content. There is intentionally no Codable conformance,
/// storage operation, provider conversion, or diagnostic serialization.
struct ComposeContextSnapshot: Equatable, Sendable {
    let id: UUID
    let target: ComposeContentCaptureTarget
    let selectedRange: ComposeSelectedTextRange
    let selectedText: String
    let capturedAt: Date
    let completeness: ComposeContextCompleteness
    let authorization: ScribeContextAccessAuthorization
}

enum ComposeContentCaptureFailure: Error, Equatable, Sendable {
    case policy(ScribeContextPolicyRejection)
    case invalidBudget
    case noSelection
    case unsupportedAttribute
    case unsupportedSurface
    case secureField
    case targetChanged
    case selectionChanged
    case contextTooLarge
    case invalidSelection
    case invalidContent
    case metadataBudgetExceeded
    case timedOut
    case cancelled
    case readFailed
}

enum ComposeContentCaptureOutcome: Equatable, Sendable {
    case captured(ComposeContextSnapshot)
    case unavailable(ComposeContentCaptureFailure)
}

enum ComposeSelectionRevalidationOutcome: Equatable, Sendable {
    case current
    case unavailable(ComposeContentCaptureFailure)
}
