import Foundation

/// Local, in-memory revision history for an already-reviewed Compose draft.
/// This type neither captures context nor sends text to a provider. A caller
/// must separately obtain consent and dispatch authority before completing a
/// revision with generated text.
@MainActor
final class ScribeDraftRevisionStore {
    private let maximumVersionsPerSession: Int
    private var sessions: [UUID: ScribeDraftRevisionSession] = [:]
    private var pending: [UUID: ScribeDraftRevisionToken] = [:]

    init(maximumVersionsPerSession: Int = 8) {
        precondition(maximumVersionsPerSession >= 2)
        self.maximumVersionsPerSession = maximumVersionsPerSession
    }

    func start(
        origin: ScribeDraftRevisionOrigin,
        originalSpokenRequest: String,
        initialDraft: String
    ) -> ScribeDraftRevisionSession {
        let version = ScribeDraftVersion(
            id: UUID(), ordinal: 0, text: initialDraft,
            source: .originalGeneration, revisionInstruction: nil
        )
        let session = ScribeDraftRevisionSession(
            id: UUID(), origin: origin, originalSpokenRequest: originalSpokenRequest,
            versions: [version], currentVersionIndex: 0
        )
        sessions[session.id] = session
        return session
    }

    func session(id: UUID, origin: ScribeDraftRevisionOrigin) throws -> ScribeDraftRevisionSession {
        let session = try session(id: id)
        guard session.origin == origin else { throw ScribeDraftRevisionError.originMismatch }
        return session
    }

    func beginRevision(
        sessionID: UUID,
        origin: ScribeDraftRevisionOrigin,
        baseVersionID: UUID,
        revisionUtterance: String
    ) throws -> ScribeDraftRevisionToken {
        let session = try self.session(id: sessionID, origin: origin)
        guard session.currentVersion.id == baseVersionID else {
            throw ScribeDraftRevisionError.wrongBaseVersion
        }
        guard !revisionUtterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScribeDraftRevisionError.emptyInstruction
        }
        let token = ScribeDraftRevisionToken(
            id: UUID(), sessionID: sessionID, baseVersionID: baseVersionID, origin: origin,
            instruction: .init(id: UUID(), utterance: revisionUtterance)
        )
        pending[token.id] = token
        return token
    }

    func completeRevision(
        _ token: ScribeDraftRevisionToken,
        refinedDraft: String
    ) throws -> ScribeDraftRevisionSession {
        guard pending.removeValue(forKey: token.id) == token else {
            throw ScribeDraftRevisionError.unknownRevision
        }
        let session = try self.session(id: token.sessionID)
        guard session.origin == token.origin else { throw ScribeDraftRevisionError.originMismatch }
        guard session.currentVersion.id == token.baseVersionID else {
            throw ScribeDraftRevisionError.staleCompletion
        }

        var versions = Array(session.versions.prefix(session.currentVersionIndex + 1))
        versions.append(.init(
            id: UUID(), ordinal: versions.last!.ordinal + 1, text: refinedDraft,
            source: .voiceRefinement, revisionInstruction: token.instruction
        ))
        if versions.count > maximumVersionsPerSession {
            versions.removeFirst(versions.count - maximumVersionsPerSession)
        }
        let updated = ScribeDraftRevisionSession(
            id: session.id, origin: session.origin, originalSpokenRequest: session.originalSpokenRequest,
            versions: versions, currentVersionIndex: versions.count - 1
        )
        sessions[updated.id] = updated
        return updated
    }

    /// Cancellation and failed generation discard only the pending token. The
    /// current accepted draft remains unchanged for review and recovery.
    func discardRevision(_ token: ScribeDraftRevisionToken) throws -> ScribeDraftRevisionSession {
        guard pending.removeValue(forKey: token.id) == token else {
            throw ScribeDraftRevisionError.unknownRevision
        }
        let session = try self.session(id: token.sessionID)
        guard session.origin == token.origin else { throw ScribeDraftRevisionError.originMismatch }
        return session
    }

    func cancelRevision(_ token: ScribeDraftRevisionToken) throws -> ScribeDraftRevisionSession {
        try discardRevision(token)
    }

    func failRevision(_ token: ScribeDraftRevisionToken) throws -> ScribeDraftRevisionSession {
        try discardRevision(token)
    }

    func undo(sessionID: UUID, origin: ScribeDraftRevisionOrigin) throws -> ScribeDraftRevisionSession {
        let session = try self.session(id: sessionID, origin: origin)
        guard session.currentVersionIndex > 0 else { return session }
        let updated = ScribeDraftRevisionSession(
            id: session.id, origin: session.origin, originalSpokenRequest: session.originalSpokenRequest,
            versions: session.versions, currentVersionIndex: session.currentVersionIndex - 1
        )
        sessions[updated.id] = updated
        return updated
    }

    private func session(id: UUID) throws -> ScribeDraftRevisionSession {
        guard let session = sessions[id] else { throw ScribeDraftRevisionError.unknownSession }
        return session
    }
}
