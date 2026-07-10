import Foundation

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
            return "Scribe enabled"
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
        .selectedTextContext,
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
    let target: ScribeTargetIdentity
    let selectedText: String

    var disclosure: String {
        selectedText.isEmpty ? "No selected text" : "Using selected text"
    }
}

struct ScribeRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let intent: ScribeIntent
    let spokenTranscript: String
    let context: ScribeContextSnapshot?

    init(
        id: UUID = UUID(),
        intent: ScribeIntent,
        spokenTranscript: String,
        context: ScribeContextSnapshot? = nil
    ) {
        self.id = id
        self.intent = intent
        self.spokenTranscript = spokenTranscript
        self.context = context
    }
}

struct ScribeResult: Equatable, Sendable {
    let requestID: UUID
    let text: String
}

enum ScribeSessionState: Equatable, Sendable {
    case idle
    case choosingIntent
    case listening(requestID: UUID, intent: ScribeIntent)
    case transcribing(requestID: UUID)
    case generating(requestID: UUID)
    case reviewing(ScribeResult)
    case inserting(requestID: UUID)
    case succeeded(requestID: UUID)
    case cancelled(requestID: UUID?)
    case failed(requestID: UUID?, error: ScribeProviderError)

    var requestID: UUID? {
        switch self {
        case .idle, .choosingIntent:
            return nil
        case let .listening(requestID, _),
             let .transcribing(requestID),
             let .generating(requestID),
             let .inserting(requestID),
             let .succeeded(requestID):
            return requestID
        case let .reviewing(result):
            return result.requestID
        case let .cancelled(requestID), let .failed(requestID, _):
            return requestID
        }
    }
}
