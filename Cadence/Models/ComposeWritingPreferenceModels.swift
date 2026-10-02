import Foundation

/// A closed set of user-authored writing choices. Source text, prior drafts,
/// inferred traits, and arbitrary prompt strings cannot become a preference.
enum ComposeWritingPreferenceField: Int, CaseIterable, Equatable, Sendable {
    case tone
    case length
    case formatting
    case explanation
}

enum ComposeWritingPreferenceFormat: Equatable, Sendable {
    case prose
    case reply
    case bullets(count: Int)
}

enum ComposeWritingPreferenceValue: Equatable, Sendable {
    case tone(ScribeWritingTone)
    case concise
    case formatting(ComposeWritingPreferenceFormat)
    case avoidUnstatedReasons

    var field: ComposeWritingPreferenceField {
        switch self {
        case .tone: return .tone
        case .concise: return .length
        case .formatting: return .formatting
        case .avoidUnstatedReasons: return .explanation
        }
    }
}

struct ComposePreferenceApplicationKey: Equatable, Hashable, Sendable { let opaqueValue: String }
struct ComposePreferenceProjectKey: Equatable, Hashable, Sendable { let opaqueValue: String }

/// Eligibility to address preferences, not permission to read content, retain
/// personal information, or transmit anything to a provider. These identities
/// must be rebuilt from fresh trusted adapter evidence before each use.
struct ComposePreferenceApplicationIdentity: Equatable, Sendable {
    let key: ComposePreferenceApplicationKey
    let adapterID: ScribeConversationStableID
    let binding: ScribeConversationActionBinding
}

struct ComposePreferenceProjectIdentity: Equatable, Sendable {
    let key: ComposePreferenceProjectKey
    let applicationKey: ComposePreferenceApplicationKey
    let binding: ScribeConversationActionBinding
}

enum ComposeWritingPreferenceScope: Equatable, Sendable {
    case global
    /// Account-bound application identity, never a browser bundle alone.
    case application(ComposePreferenceApplicationKey)
    case project(ComposePreferenceProjectKey)
    case conversation(ScribeConversationMemoryKey)
    case currentAction(UUID)
}

struct ComposeWritingPreferenceContext: Equatable, Sendable {
    let binding: ScribeConversationActionBinding
    let application: ComposePreferenceApplicationIdentity?
    let project: ComposePreferenceProjectIdentity?
    let conversation: ScribeVerifiedConversationIdentity?

    init(
        binding: ScribeConversationActionBinding,
        application: ComposePreferenceApplicationIdentity? = nil,
        project: ComposePreferenceProjectIdentity? = nil,
        conversation: ScribeVerifiedConversationIdentity? = nil
    ) {
        self.binding = binding
        self.application = application
        self.project = project
        self.conversation = conversation
    }
}

struct ComposeWritingPreference: Equatable, Identifiable, Sendable {
    let id: UUID
    let scope: ComposeWritingPreferenceScope
    let value: ComposeWritingPreferenceValue
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?
}

/// In-memory only. A new store starts disabled and empty. There is deliberately
/// no Codable conformance, UserDefaults key, disk IO, or automatic suggestion.
struct ComposeWritingPreferenceSnapshot: Equatable, Sendable {
    let revision: UUID
    let isEnabled: Bool
    let preferences: [ComposeWritingPreference]

    init(revision: UUID = UUID(), isEnabled: Bool = false, preferences: [ComposeWritingPreference] = []) {
        self.revision = revision
        self.isEnabled = isEnabled
        self.preferences = preferences
    }
}

enum ComposeWritingPreferenceProvenance: Equatable, Sendable {
    case saved(id: UUID, scope: ComposeWritingPreferenceScope)
    case currentAction(index: Int)
    case currentVoice(index: Int)
}

struct ComposeResolvedWritingPreference: Equatable, Sendable {
    let value: ComposeWritingPreferenceValue
    let provenance: ComposeWritingPreferenceProvenance
}

struct ComposeWritingPreferenceConflict: Equatable, Sendable {
    let field: ComposeWritingPreferenceField
    let selected: ComposeWritingPreferenceProvenance
    let overridden: [ComposeWritingPreferenceProvenance]
}

struct ComposeWritingPreferenceResolution: Equatable, Sendable {
    let snapshotRevision: UUID
    let context: ComposeWritingPreferenceContext
    let currentAction: [ComposeWritingPreferenceValue]
    let currentVoice: [ScribeWritingDirection]
    let resolvedAt: Date
    /// Earliest expiration among eligible records. Re-resolve at this time,
    /// including when a currently overridden record expires.
    let validUntil: Date?
    let preferences: [ComposeResolvedWritingPreference]
    let conflicts: [ComposeWritingPreferenceConflict]
    let compiledInstructions: String
}

struct ComposeWritingPreferenceDraft: Equatable, Sendable {
    let scope: ComposeWritingPreferenceScope
    let value: ComposeWritingPreferenceValue
    let expiresAt: Date?
}

struct ComposeWritingPreferenceEditToken: Equatable, Identifiable, Sendable {
    let id: UUID
    let snapshotRevision: UUID
    let scope: ComposeWritingPreferenceScope
    let binding: ScribeConversationActionBinding
    let context: ComposeWritingPreferenceContext
    let createdAt: Date
    let expiresAt: Date
}

enum ComposeWritingPreferenceError: Error, Equatable, Sendable {
    case disabled
    case invalidValue
    case invalidIdentity
    case invalidTimeWindow
    case tooManyPreferences
    case duplicateIdentity
    case unknownEdit
    case staleEdit
    case scopeChanged
}
