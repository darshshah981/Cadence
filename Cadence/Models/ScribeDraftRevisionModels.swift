import Foundation

/// Immutable lineage for a reviewable Compose draft. This binds a local draft
/// session to the action, captured target, and provider configuration that
/// produced it; it does not authorize any additional provider egress.
struct ScribeDraftRevisionOrigin: Equatable, Sendable {
    let actionID: UUID
    let captureID: UUID
    let target: ScribeTargetIdentity
    let providerActionIdentity: ScribeProviderActionIdentity?
}

enum ScribeDraftRevisionSource: Equatable, Sendable {
    case originalGeneration
    case voiceRefinement
}

/// A revision utterance is deliberately distinct from the original spoken
/// writing request. It is local session metadata until a later explicit
/// refinement-dispatch policy authorizes its use.
struct ScribeDraftRevisionInstruction: Equatable, Sendable {
    let id: UUID
    let utterance: String
}

struct ScribeDraftVersion: Equatable, Identifiable, Sendable {
    let id: UUID
    let ordinal: Int
    let text: String
    let source: ScribeDraftRevisionSource
    let revisionInstruction: ScribeDraftRevisionInstruction?
}

struct ScribeDraftRevisionToken: Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let baseVersionID: UUID
    let origin: ScribeDraftRevisionOrigin
    let instruction: ScribeDraftRevisionInstruction
}

struct ScribeDraftRevisionSession: Equatable, Identifiable, Sendable {
    let id: UUID
    let origin: ScribeDraftRevisionOrigin
    let originalSpokenRequest: String
    let versions: [ScribeDraftVersion]
    let currentVersionIndex: Int

    var currentVersion: ScribeDraftVersion { versions[currentVersionIndex] }
}

enum ScribeDraftRevisionError: Error, Equatable, Sendable {
    case unknownSession
    case originMismatch
    case wrongBaseVersion
    case unknownRevision
    case staleCompletion
    case emptyInstruction
}
