import Foundation

/// A bounded, local classification of a spoken Compose request. It records
/// only what was recognized; everything else remains part of `message`.
struct ScribeWritingRequest: Equatable, Sendable {
    let originalTranscript: String
    let message: String
    let writingDirections: [ScribeWritingDirection]
    let protectedSpans: [ScribeProtectedSpan]
    let unresolvedReferences: [ScribeUnresolvedReference]
    let recipientFrame: ScribeRecipientFrame?

    /// The narrow recipient-facing rewrite, when the spoken request has an
    /// unambiguous leading "Tell" or "Ask" frame. `message` deliberately
    /// remains the spoken wording so callers that do not opt into focused
    /// rewriting retain their current behavior.
    var preparedMessage: String? { recipientFrame?.preparedMessage }

    init(
        originalTranscript: String,
        message: String,
        writingDirections: [ScribeWritingDirection] = [],
        protectedSpans: [ScribeProtectedSpan] = [],
        unresolvedReferences: [ScribeUnresolvedReference] = [],
        recipientFrame: ScribeRecipientFrame? = nil
    ) {
        self.originalTranscript = originalTranscript
        self.message = message
        self.writingDirections = writingDirections
        self.protectedSpans = protectedSpans
        self.unresolvedReferences = unresolvedReferences
        self.recipientFrame = recipientFrame
    }
}

/// A spoken request addressed to a person or the explicit coding-agent role.
/// This formats text only; it never changes the selected insertion target.
struct ScribeRecipientFrame: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ask
        case tell
    }

    enum Recipient: Equatable, Sendable {
        case named(String)
        case codingAgent
    }

    let kind: Kind
    let recipient: Recipient
    let body: String

    var preparedMessage: String {
        switch recipient {
        case let .named(name):
            let politeBody: String
            if kind == .ask,
               body.range(of: #"^please\b"#, options: [.regularExpression, .caseInsensitive]) == nil {
                politeBody = "please " + body
            } else {
                politeBody = body
            }
            return "\(name), \(politeBody)"
        case .codingAgent:
            return body
        }
    }
}

enum ScribeWritingDirection: Equatable, Sendable {
    case tone(ScribeWritingTone)
    case concise
    case reply
    case bullets(count: Int)
    case avoidGivingReason

    var instruction: String {
        switch self {
        case .tone(.formal):
            return "Use formal wording and complete sentences."
        case .tone(.casual):
            return "Use casual, natural wording."
        case .tone(.polite):
            return "Use polite wording without adding facts, excuses, or promises."
        case .tone(.professional):
            return "Use professional, measured wording."
        case .tone(.warm):
            return "Use warm, natural wording."
        case .tone(.upbeat):
            return "Use upbeat wording without adding facts, certainty, promises, or outcomes."
        case .concise:
            return "Keep the draft concise without dropping facts or recipient restrictions."
        case .reply:
            return "Write a clear, natural reply ready to paste. Return only the reply text without a heading, introduction, or destination label."
        case let .bullets(count):
            return "Present the message as exactly \(count) bullet points."
        case .avoidGivingReason:
            return "Do not add a reason, excuse, or explanation that the speaker did not provide."
        }
    }
}

enum ScribeWritingTone: Equatable, Sendable {
    case formal
    case casual
    case polite
    case professional
    case warm
    case upbeat
}

struct ScribeProtectedSpan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case quotedOrLiteralRequest
        case exactLiteral
        case recipientInstruction
    }

    /// UTF-16 offsets preserve the source location used by Foundation regular
    /// expressions without rewriting the original Unicode text.
    let utf16Range: Range<Int>
    let value: String
    let kind: Kind
}

enum ScribeUnresolvedReference: Equatable, Sendable {
    case sourceRequired(transform: ScribeSourceTransform)
}

enum ScribeSourceTransform: Equatable, Sendable {
    case rewrite
    case reply
}
