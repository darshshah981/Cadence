import Foundation

/// Active-review disclosure only. It is not a retained memory record or an
/// input for the provider. Exclusion preserves the old draft's source lineage.
struct ScribeSelectedTextReviewSource: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let includedUTF8Bytes: Int
    let isExcluded: Bool
    var isUnchanged = false

    var status: String { isExcluded ? "Excluded source · Previous draft" : "Selected text · This Mac" }
    var exclusionMessage: String {
        "This draft still reflects the selection. Insertion is off. Record a new message to replace it without reading the selection."
    }
}

enum ComposeGroundedDraftTask: Equatable, Sendable {
    case reply
    case rewriteSelection
}

/// Replies require a certified conversation field. Replacing the exact captured
/// selection can instead use an invocation-only field, which grants no durable
/// identity or memory lookup and cannot identify a distinct reply composer.
struct ComposeGroundedFieldReference: Equatable, Sendable {
    let conversation: ScribeVerifiedConversationIdentity?
    let invocation: ComposeContentCaptureTarget?
    let elementID: ScribeConversationStableID

    init(conversation: ScribeVerifiedConversationIdentity, elementID: ScribeConversationStableID) {
        self.conversation = conversation
        self.invocation = nil
        self.elementID = elementID
    }

    init(invocation: ComposeContentCaptureTarget) {
        self.conversation = nil
        self.invocation = invocation
        self.elementID = ScribeConversationStableID(rawValue: "capture:" + invocation.source.captureID.uuidString)!
    }

    var actionID: UUID? { conversation?.binding.actionID ?? invocation?.action.actionID }
}

/// Sections partition the captured selection, using relative UTF-16 offsets.
/// A trusted caller selects relevance; the compiler does not infer it from text.
struct ComposeGroundedSourceSection: Equatable, Sendable {
    let id: Int
    let range: ComposeSelectedTextRange
    let isRequired: Bool
}

/// Immutable local comparison values, not bearer credentials. Their issuer
/// must verify pinned source/destination authority at each boundary. A verified
/// conversation needs a certified integration; invocation-only selection
/// identity comes from the bounded capture reader and insertion preflight.
struct ComposeGroundedSourceAuthority: Equatable, Sendable {
    let snapshotID: UUID
    let target: ComposeContentCaptureTarget
    let field: ComposeGroundedFieldReference
    let selectedRange: ComposeSelectedTextRange
    let contentSHA256: String
    let capturedAt: Date
    let authorization: ScribeContextAccessAuthorization
}

enum ComposeGroundedInsertionDisposition: Equatable, Sendable {
    case insertAtCaret
    case replaceSelection
}

struct ComposeGroundedDestinationAuthority: Equatable, Sendable {
    let captureID: UUID
    let target: ScribeTargetIdentity
    let process: ApplicationProcessIdentity
    let verificationToken: String
    let recognitionSignature: TargetRecognitionSignature?
    let field: ComposeGroundedFieldReference
    let selectedRange: ComposeSelectedTextRange
    let selectedContentSHA256: String
    let capturedAt: Date
    let disposition: ComposeGroundedInsertionDisposition
}

struct ComposeGroundedSource: Equatable, Sendable {
    let snapshot: ComposeContextSnapshot
    let authority: ComposeGroundedSourceAuthority
    let sections: [ComposeGroundedSourceSection]
}

enum ComposeGroundedSourceProblem: Equatable, Sendable {
    case missing
    case ambiguous
    case partial
    case contradictory
}

enum ComposeGroundedSourceResolution: Equatable, Sendable {
    case selected(ComposeGroundedSource)
    case unavailable(ComposeGroundedSourceProblem)
}

struct ComposeGroundedRequest: Equatable, Sendable {
    let task: ComposeGroundedDraftTask
    let voice: NormalizedScribeTranscript
    let source: ComposeGroundedSourceResolution
    let destination: ComposeGroundedDestinationAuthority?
}

struct ComposeGroundedRequestBudget: Equatable, Sendable {
    var maximumVoiceUTF8Bytes = 4 * 1_024
    var maximumSourceUTF8Bytes = 8 * 1_024
    var maximumPayloadUTF8Bytes = 16 * 1_024
    var maximumOutputUTF8Bytes = 16 * 1_024
    var maximumSourceAge: TimeInterval = 120

    var isValid: Bool {
        (1...8 * 1_024).contains(maximumVoiceUTF8Bytes)
            && (1...32 * 1_024).contains(maximumSourceUTF8Bytes)
            && (1...64 * 1_024).contains(maximumPayloadUTF8Bytes)
            && (1...32 * 1_024).contains(maximumOutputUTF8Bytes)
            && maximumSourceAge.isFinite && (0...600).contains(maximumSourceAge)
            && maximumSourceAge > 0
    }
}

/// Only these sections entered the model input. Omissions remain visible to
/// review; a complete selection does not imply a complete conversation.
struct ComposeGroundedSourceProvenance: Equatable, Sendable {
    let sourceSnapshotID: UUID
    let includedSectionIDs: [Int]
    let omittedSectionIDs: [Int]
    let includedUTF8Bytes: Int

    var isLimited: Bool { !omittedSectionIDs.isEmpty }
}

enum ComposeGroundedSourceRole: Equatable, Sendable {
    case incomingReference
    case textToRewrite
}

/// Mechanical obligations differ by task. Incoming quotations are not all
/// required in a reply. These checks do not certify semantic grounding.
struct ComposeGroundedOutputObligations: Equatable, Sendable {
    let sourceRole: ComposeGroundedSourceRole
    let exactLiterals: [ScribeExactLiteral]
    let recipientRestrictions: [ScribeRecipientRestriction]
    let literalMutationAuthorization: String
    let promptMarkerExemptions: String
    let maximumUTF8Bytes: Int
}

/// Ephemeral only: no Codable, persistence, tool execution, or insertion API.
/// ProviderSafeScribeInput contains the allowlisted text; authority stays local.
struct ComposeGroundedCompilation: Equatable, Sendable {
    let task: ComposeGroundedDraftTask
    let input: ProviderSafeScribeInput
    let sourceAuthority: ComposeGroundedSourceAuthority
    let destinationAuthority: ComposeGroundedDestinationAuthority
    let provenance: ComposeGroundedSourceProvenance
    let outputObligations: ComposeGroundedOutputObligations
    let compiledAt: Date
    let validUntil: Date
}

enum ComposeGroundedCompilationError: Error, Equatable, Sendable {
    case localProviderRequired
    case invalidBudget
    case invalidVoice
    case voiceTooLarge
    case sourceUnavailable(ComposeGroundedSourceProblem)
    case invalidSource
    case sourceTooLarge
    case invalidSections
    case requiredSourceTooLarge
    case invalidAuthority
    case sourceChanged
    case destinationChanged
    case staleAuthority
    case missingDestination
    case replyRequiresDistinctDestination
    case rewriteRequiresOriginalSelection
    case policy(ScribeContextPolicyRejection)
}
