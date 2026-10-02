import Foundation

/// Capture permission does not imply permission to retain or transmit the result.
enum ScribeContextCaptureCategory: String, CaseIterable, Hashable, Sendable {
    case selectedText
    case surroundingText
    case screenshot
    case sessionMemory
    case persistentMemory
    case priorDraft
}

enum ScribeContextDataCategory: String, CaseIterable, Hashable, Sendable {
    case selectedText
    case surroundingText
    case screenshot
    case screenText
    case sessionMemory
    case persistentMemory
    case priorDraft

    var captureCategory: ScribeContextCaptureCategory {
        switch self {
        case .selectedText: return .selectedText
        case .surroundingText: return .surroundingText
        case .screenshot, .screenText: return .screenshot
        case .sessionMemory: return .sessionMemory
        case .persistentMemory: return .persistentMemory
        case .priorDraft: return .priorDraft
        }
    }
}

/// An opaque surface ID must come from a supported identity resolver, never a
/// window title or a similarity guess. These values remain local metadata.
enum ScribeContextAccessScope: Equatable, Sendable {
    case application(bundleIdentifier: String)
    case surface(bundleIdentifier: String, opaqueSurfaceID: String)
}

enum ScribeContextSurfaceEligibility: Equatable, Sendable {
    case eligible
    case secure
    case privateSurface
    case unsupported
}

/// The capture ID protects an invocation from PID reuse or a recaptured editor.
/// It does not replace the insertion service's live target verification.
struct ScribeContextActionBinding: Equatable, Sendable {
    let actionID: UUID
    let captureID: UUID
    let target: ScribeTargetIdentity
    let opaqueSurfaceID: String?
    let eligibility: ScribeContextSurfaceEligibility
}

struct ScribeContextGrantWindow: Equatable, Sendable {
    let acceptedAt: Date
    let expiresAt: Date
}

struct ScribeContextCaptureGrant: Equatable, Sendable {
    let id: UUID
    let scope: ScribeContextAccessScope
    let categories: Set<ScribeContextCaptureCategory>
    let window: ScribeContextGrantWindow
}

enum ScribeContextRetentionDestination: Equatable, Sendable {
    case sessionMemory
    case persistentMemory
}

struct ScribeContextRetentionGrant: Equatable, Sendable {
    let id: UUID
    let scope: ScribeContextAccessScope
    let categories: Set<ScribeContextDataCategory>
    let destination: ScribeContextRetentionDestination
    let maximumRetentionInterval: TimeInterval
    let window: ScribeContextGrantWindow
}

/// Exact recipient and provider-action identity supplement the existing
/// provider consent authority. This value cannot establish provider consent.
struct ScribeContextProviderBinding: Equatable, Sendable {
    let actionIdentity: ScribeProviderActionIdentity
    let recipientOrigin: String
    let providerDisclosureRevision: Int
}

/// A separate affirmative context receipt is required. The existing version-2
/// transcript-only provider receipt cannot be substituted for this type.
/// Trusted settings/consent code must issue these values; policy evaluation
/// alone does not establish that a person granted permission.
struct ScribeContextTransmissionGrant: Equatable, Sendable {
    static let currentContextDisclosureRevision = 1

    let id: UUID
    let scope: ScribeContextAccessScope
    let provider: ScribeContextProviderBinding
    let categories: Set<ScribeContextDataCategory>
    let contextDisclosureRevision: Int
    let window: ScribeContextGrantWindow
}

struct ScribeContextPlatformPermissions: Equatable, Sendable {
    var accessibility: Bool = false
    var screenRecording: Bool = false
}

/// In-memory policy input only: no serialization, permission prompts, content,
/// persistence, or network operations. An owner must replace `revision` after
/// every material change so outstanding authorizations fail closed.
struct ScribeContextPolicySnapshot: Equatable, Sendable {
    var revision = UUID()
    var isEnabled = false
    var captureGrants: [ScribeContextCaptureGrant] = []
    var retentionGrants: [ScribeContextRetentionGrant] = []
    var transmissionGrants: [ScribeContextTransmissionGrant] = []
    var excludedScopes: [ScribeContextAccessScope] = []
    var excludedCategories: Set<ScribeContextDataCategory> = []
    var revokedGrantIDs: Set<UUID> = []
}

enum ScribeContextOperation: Equatable, Sendable {
    /// Authorizes only bounded in-flight capture. Keeping the result beyond
    /// that action requires a separate retention authorization.
    case capture(ScribeContextCaptureCategory)
    case retain(
        categories: Set<ScribeContextDataCategory>,
        destination: ScribeContextRetentionDestination,
        until: Date
    )
    /// The compiler must supply every payload category, including provenance
    /// categories of excerpts embedded in a draft or memory record. Calling a
    /// screen-derived excerpt `priorDraft` must not erase its screen category.
    case transmit(
        categories: Set<ScribeContextDataCategory>,
        provider: ScribeContextProviderBinding
    )
}

struct ScribeContextPolicyRequest: Equatable, Sendable {
    let action: ScribeContextActionBinding
    let operation: ScribeContextOperation
}

/// A decision, not a bearer credential. Consumers must revalidate with a fresh
/// policy, live action, and current OS permissions at each asynchronous boundary.
struct ScribeContextAccessAuthorization: Equatable, Sendable {
    let request: ScribeContextPolicyRequest
    let policyRevision: UUID
    let grantIDs: Set<UUID>
}

/// Closed, content-free failures are suitable for coarse diagnostics. Do not
/// log a request, grant, target, scope, provider binding, or authorization.
enum ScribeContextPolicyRejection: Error, Equatable, Sendable {
    case disabled
    case ineligibleSurface
    case unknownApplication
    case excludedScope
    case excludedCategory
    case missingPlatformPermission
    case missingCaptureGrant
    case missingRetentionGrant
    case missingTransmissionGrant
    case invalidRequest
    case actionOrOperationChanged
    case policyChanged
}
