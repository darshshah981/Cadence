import Foundation

/// An adapter's opaque identifier, never a display title, URL, or captured text.
/// IDs use printable ASCII so equality and hashing preserve exact case and bytes.
struct ScribeConversationStableID: Equatable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 512,
              rawValue.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        self.rawValue = rawValue
    }
}

/// An absent container must be explicitly known to be inapplicable. Unknown
/// workspace/project identity must not silently become an account-wide scope.
enum ScribeConversationContainerID: Equatable, Hashable, Sendable {
    case identified(ScribeConversationStableID)
    case notApplicable
    case unknown
}

enum ScribeConversationIdentitySource: String, Equatable, Sendable {
    case nativeIntegration
    case browserIntegration
}

/// Trusted composition code registers an integration, not page content or an
/// untrusted caller. Registration alone is not certification of a platform.
struct ScribeConversationAdapterRegistration: Equatable, Sendable {
    let adapterID: ScribeConversationStableID
    let schemaVersion: UInt32
    let source: ScribeConversationIdentitySource
    let hostBundleIdentifier: String
    let applicationID: ScribeConversationStableID
}

/// Supplied by the existing target authority and the registered surface adapter.
/// Window/tab UUIDs identify incarnations, not reusable OS numbers or titles.
/// Navigation revision changes whenever the account, project, or thread changes.
struct ScribeConversationActionBinding: Equatable, Hashable, Sendable {
    let actionID: UUID
    let process: ApplicationProcessIdentity
    let windowIncarnation: UUID?
    let tabIncarnation: UUID?
    let navigationRevision: UUID
}

enum ScribeConversationIdentityConfidence: Equatable, Sendable {
    case verifiedStableIdentifiers
    case partial
    case ambiguous
}

enum ScribeConversationPrivacyState: Equatable, Sendable {
    case regular
    case privateBrowsing
    case unknown
}

/// Ephemeral input supplied directly by a registered adapter. There is no title,
/// URL, transcript, or content field from which this layer can infer identity.
/// Confidence is an adapter assertion, not proof independent of that adapter.
struct ScribeConversationIdentityEvidence: Equatable, Sendable {
    let adapterID: ScribeConversationStableID
    let schemaVersion: UInt32
    let source: ScribeConversationIdentitySource
    let binding: ScribeConversationActionBinding
    let confidence: ScribeConversationIdentityConfidence
    let privacyState: ScribeConversationPrivacyState
    let applicationID: ScribeConversationStableID?
    let accountID: ScribeConversationStableID?
    let workspaceID: ScribeConversationContainerID
    let projectID: ScribeConversationContainerID
    let conversationID: ScribeConversationStableID?
}

/// Separate key types prevent a temporary fallback from becoming a durable
/// lookup key. Hashing hides raw identifiers in keys; it is not encryption.
struct ScribeConversationMemoryKey: Equatable, Hashable, Sendable {
    let opaqueValue: String
}

struct ScribeConversationTransientKey: Equatable, Hashable, Sendable {
    let opaqueValue: String
}

struct ScribeVerifiedConversationIdentity: Equatable, Sendable {
    let memoryKey: ScribeConversationMemoryKey
    let adapterID: ScribeConversationStableID
    let binding: ScribeConversationActionBinding
}

struct ScribeTransientConversationIdentity: Equatable, Sendable {
    let key: ScribeConversationTransientKey
    let binding: ScribeConversationActionBinding
}

enum ScribeConversationIdentityReason: Equatable, Sendable {
    case noRegisteredAdapter
    case registrationChanged
    case sourceMismatch
    case hostApplicationMismatch
    case applicationMismatch
    case actionBindingMismatch
    case missingSurfaceIdentity
    case missingEvidence
    case insufficientConfidence
    case privateSession
    case unknownPrivacyState
    case missingStableIdentifiers
}

enum ScribeConversationIdentityResolution: Equatable, Sendable {
    case verified(ScribeVerifiedConversationIdentity)
    case ambiguous(ScribeTransientConversationIdentity, reason: ScribeConversationIdentityReason)
    case unsupported(ScribeTransientConversationIdentity, reason: ScribeConversationIdentityReason)

    /// Eligibility to address a scope, not authorization to read/write memory.
    /// Consent, freshness, retention, and pending-write checks remain separate.
    var durableMemoryKey: ScribeConversationMemoryKey? {
        guard case let .verified(identity) = self else { return nil }
        return identity.memoryKey
    }
}

enum ScribeConversationAdapterRegistrationError: Error, Equatable, Sendable {
    case duplicateAdapter
    case invalidRegistration
}
