import Foundation

/// Legacy source compatibility only. Scribe has one direct-dictation flow and
/// never uses an intent or selected text at runtime.
@available(*, deprecated, message: "Compose is direct dictation only")
enum ScribeIntent: String, CaseIterable, Codable, Identifiable, Sendable {
    case compose
    case respond
    case edit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compose:
            return "Write from scratch"
        case .respond:
            return "Respond to selection"
        case .edit:
            return "Edit selection"
        }
    }

    var shortDescription: String {
        switch self {
        case .compose:
            return "Describe what you want Cadence to write."
        case .respond:
            return "Use the selected text as context for a response."
        case .edit:
            return "Tell Cadence how to revise the selected text."
        }
    }

    var requiresSelectedText: Bool {
        self != .compose
    }

    var contextScope: ScribeContextScope {
        requiresSelectedText ? .selectedText : .none
    }
}

enum ScribeContextScope: String, Codable, Equatable, Sendable {
    case none
    case selectedText
}

enum ScribeIntentPickerResult: Equatable, Sendable {
    case selected(ScribeIntent)
    case cancelled

    var intent: ScribeIntent? {
        guard case let .selected(intent) = self else { return nil }
        return intent
    }
}

enum ScribePrivacyMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case privateMode
    case approvedProvider

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .privateMode:
            return "Private mode"
        case .approvedProvider:
            return "Compose enabled"
        }
    }
}

struct ScribeProviderCapabilities: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    static let semanticGeneration = ScribeProviderCapabilities(rawValue: 1 << 0)
    static let selectedTextContext = ScribeProviderCapabilities(rawValue: 1 << 1)
    static let cancellation = ScribeProviderCapabilities(rawValue: 1 << 2)

    static let mock: ScribeProviderCapabilities = [
        .semanticGeneration,
        .cancellation
    ]
}

enum ScribeReadinessBlocker: String, Equatable, Sendable {
    case permissions
    case privateMode
    case providerUnavailable
}

struct ScribeReadiness: Equatable, Sendable {
    let privacyMode: ScribePrivacyMode
    let providerCapabilities: ScribeProviderCapabilities
    let permissionsGranted: Bool

    var canGenerate: Bool {
        blockingReason == nil
    }

    var canUseLiteralFallback: Bool { permissionsGranted }

    var blockingReason: ScribeReadinessBlocker? {
        guard permissionsGranted else { return .permissions }
        guard privacyMode == .approvedProvider else { return .privateMode }
        guard providerCapabilities.contains(.semanticGeneration) else {
            return .providerUnavailable
        }
        return nil
    }
}

struct ScribeTargetIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?

    init(processIdentifier: Int32, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

struct ScribeContextSnapshot: Equatable, Sendable {
    let id: UUID
    let target: ScribeTargetIdentity
    let scope: ScribeContextScope
    let selectedText: String
    let verificationToken: String
    let selectionIdentity: ScribeSelectionIdentity?
    let recognitionSignature: TargetRecognitionSignature?
    let applicationTarget: ApplicationTargetCapture

    init(
        id: UUID = UUID(),
        target: ScribeTargetIdentity,
        scope: ScribeContextScope = .selectedText,
        selectedText: String,
        verificationToken: String = UUID().uuidString,
        selectionIdentity: ScribeSelectionIdentity? = nil,
        recognitionSignature: TargetRecognitionSignature? = nil,
        applicationTarget: ApplicationTargetCapture
    ) {
        self.id = id
        self.target = target
        self.scope = scope
        self.selectedText = selectedText
        self.verificationToken = verificationToken
        self.selectionIdentity = selectionIdentity
        self.recognitionSignature = recognitionSignature
        self.applicationTarget = applicationTarget
    }

    var disclosure: String {
        scope == .selectedText ? "Using selected text" : "No selected text used"
    }
}

struct ScribeSelectionIdentity: Equatable, Sendable {
    let location: Int
    let length: Int
}

struct ScribeRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let intent: ScribeIntent
    let spokenTranscript: String
    let context: ScribeRequestContext?
    let style: ScribeStyleInstructions?
    let resolvedEnvironment: ResolvedWritingEnvironment?
    let resolvedGuidance: ResolvedScribeGuidance?
    let exactLiterals: [ScribeExactLiteral]

    init(
        id: UUID = UUID(),
        intent: ScribeIntent,
        spokenTranscript: String,
        context: ScribeRequestContext? = nil,
        style: ScribeStyleInstructions? = nil,
        resolvedEnvironment: ResolvedWritingEnvironment? = nil,
        resolvedGuidance: ResolvedScribeGuidance? = nil,
        exactLiterals: [ScribeExactLiteral] = []
    ) {
        self.id = id
        self.intent = intent
        self.spokenTranscript = spokenTranscript
        self.context = context
        self.style = style
        self.resolvedEnvironment = resolvedEnvironment
        self.resolvedGuidance = resolvedGuidance
        self.exactLiterals = exactLiterals
    }

    /// The only constructor for newly-created Scribe work. The legacy intent
    /// field remains solely so previously persisted values can decode.
    static func directDictation(
        id: UUID = UUID(),
        processedDictation: String,
        resolvedEnvironment: ResolvedWritingEnvironment? = nil,
        exactLiterals: [ScribeExactLiteral] = []
    ) -> Self {
        Self(
            id: id,
            intent: .compose,
            spokenTranscript: processedDictation,
            resolvedEnvironment: resolvedEnvironment,
            exactLiterals: exactLiterals
        )
    }
}

struct ScribeStyleInstructions: Equatable, Sendable {
    let tone: WritingTone
    let length: WritingLength
    let punctuation: WritingPunctuation
    let formatting: WritingFormatting
    let preservesCodeLiterals: Bool

    init(profile: WritingStyleProfile) {
        self.tone = profile.tone
        self.length = profile.length
        self.punctuation = profile.punctuation
        self.formatting = profile.formatting
        self.preservesCodeLiterals = profile.preservesCodeLiterals
    }
}

struct ScribeRequestContext: Equatable, Sendable {
    let artifact: ScribeContextArtifact
    let authorization: ScribeContextAuthorization

    var selectedText: String {
        switch artifact {
        case let .explicitSelection(selection):
            return selection.text
        }
    }
}

struct ScribeResult: Equatable, Sendable {
    let requestID: UUID
    let text: String
    let binding: ScribeProviderResultBinding?

    init(requestID: UUID, text: String, binding: ScribeProviderResultBinding? = nil) {
        self.requestID = requestID
        self.text = text
        self.binding = binding
    }
}

enum ScribeOutputPolicy {
    static let maximumUTF8Bytes = 64 * 1_024

    static func normalizedOutput(_ text: String) throws -> String {
        let normalized = text.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ScribeProviderError.emptyResult
        }
        guard normalized.utf8.count <= maximumUTF8Bytes else {
            throw ScribeProviderError.resultTooLarge
        }
        let containsUnsupportedControl = normalized.unicodeScalars.contains { scalar in
            scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }
        guard !containsUnsupportedControl else {
            throw ScribeProviderError.invalidResult
        }
        return normalized
    }
}

enum ScribeSessionState: Equatable, Sendable {
    case idle
    case listening(requestID: UUID)
    case transcribing(requestID: UUID)
    case generating(requestID: UUID)
    case generatingSlow(requestID: UUID)
    case reviewing(ScribeResult)
    case insertionRecovery(ScribeResult)
    case inserting(requestID: UUID)
    case succeeded(requestID: UUID)
    case cancelled(requestID: UUID?)
    case failed(requestID: UUID?, error: ScribeProviderError)

    var requestID: UUID? {
        switch self {
        case .idle:
            return nil
        case let .listening(requestID),
             let .transcribing(requestID),
             let .generating(requestID),
             let .generatingSlow(requestID),
             let .inserting(requestID),
             let .succeeded(requestID):
            return requestID
        case let .reviewing(result), let .insertionRecovery(result):
            return result.requestID
        case let .cancelled(requestID), let .failed(requestID, _):
            return requestID
        }
    }
}
