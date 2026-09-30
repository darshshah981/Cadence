import Foundation
import OSLog

private let composePreferenceStoreLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposePreferenceStore"
)

/// Explicit-edit, in-memory foundation only. There is no draft-observation,
/// transcript-ingestion, inferred-profile, or persistence entry point. Callers
/// invoke Save only for a user-authored choice in an explicit editing surface.
@MainActor
final class ComposeWritingPreferenceStore {
    static let maximumPendingEdits = 32
    static let maximumEditLifetime: TimeInterval = 15 * 60

    private(set) var snapshot: ComposeWritingPreferenceSnapshot
    private let prunesExpiredRecords: Bool
    private var pending: [UUID: ComposeWritingPreferenceEditToken] = [:]

    init(snapshot: ComposeWritingPreferenceSnapshot = .init(), prunesExpiredRecords: Bool = true) {
        self.snapshot = snapshot
        self.prunesExpiredRecords = prunesExpiredRecords
    }

    func setEnabled(_ isEnabled: Bool) {
        guard snapshot.isEnabled != isEnabled else { return }
        replaceSnapshot(isEnabled: isEnabled, preferences: snapshot.preferences)
    }

    func beginUserEdit(
        scope: ComposeWritingPreferenceScope,
        context: ComposeWritingPreferenceContext,
        now: Date
    ) throws -> ComposeWritingPreferenceEditToken {
        try validateTime(now)
        expirePreferences(at: now)
        guard snapshot.isEnabled else { throw ComposeWritingPreferenceError.disabled }
        guard ComposePreferenceResolver.scopeMatches(scope, context: context) else {
            throw ComposeWritingPreferenceError.scopeChanged
        }
        pending = pending.filter { $0.value.expiresAt > now }
        guard pending.count < Self.maximumPendingEdits else { throw ComposeWritingPreferenceError.tooManyPreferences }
        let token = ComposeWritingPreferenceEditToken(
            id: UUID(), snapshotRevision: snapshot.revision, scope: scope, binding: context.binding, context: context,
            createdAt: now, expiresAt: now.addingTimeInterval(Self.maximumEditLifetime)
        )
        pending[token.id] = token
        return token
    }

    @discardableResult
    func saveUserPreference(
        _ draft: ComposeWritingPreferenceDraft,
        using token: ComposeWritingPreferenceEditToken,
        context: ComposeWritingPreferenceContext,
        now: Date,
        persisting: ((ComposeWritingPreferenceSnapshot, ComposeWritingPreferenceSnapshot) throws -> Void)? = nil
    ) throws -> ComposeWritingPreference {
        try validateTime(now)
        expirePreferences(at: now)
        guard snapshot.isEnabled else { throw ComposeWritingPreferenceError.disabled }
        guard token.snapshotRevision == snapshot.revision else { throw ComposeWritingPreferenceError.staleEdit }
        guard pending[token.id] == token else { throw ComposeWritingPreferenceError.unknownEdit }
        guard now >= token.createdAt, now < token.expiresAt else { throw ComposeWritingPreferenceError.staleEdit }
        guard token.binding == context.binding, token.context == context, draft.scope == token.scope,
              ComposePreferenceResolver.scopeMatches(draft.scope, context: context) else {
            throw ComposeWritingPreferenceError.scopeChanged
        }
        try ComposePreferenceResolver.validate(draft.value)
        if let expiration = draft.expiresAt {
            guard expiration.timeIntervalSinceReferenceDate.isFinite, expiration > now else {
                throw ComposeWritingPreferenceError.invalidTimeWindow
            }
        }
        let previous = snapshot.preferences.first { $0.scope == draft.scope && $0.value.field == draft.value.field }
        guard previous.map({ $0.updatedAt <= now }) ?? true else {
            throw ComposeWritingPreferenceError.invalidTimeWindow
        }
        var preferences = snapshot.preferences.filter { !($0.scope == draft.scope && $0.value.field == draft.value.field) }
        guard preferences.count < ComposePreferenceResolver.maximumPreferences else {
            throw ComposeWritingPreferenceError.tooManyPreferences
        }
        let preference = ComposeWritingPreference(
            id: previous?.id ?? UUID(), scope: draft.scope, value: draft.value,
            createdAt: previous?.createdAt ?? now, updatedAt: now, expiresAt: draft.expiresAt
        )
        preferences.append(preference)
        let next = ComposeWritingPreferenceSnapshot(
            isEnabled: snapshot.isEnabled, preferences: preferences
        )
        try persisting?(next, snapshot)
        snapshot = next
        pending.removeAll()
        return preference
    }

    func cancelEdit(_ token: ComposeWritingPreferenceEditToken) {
        guard pending[token.id] == token else { return }
        pending.removeValue(forKey: token.id)
    }

    func deletePreference(id: UUID) {
        replaceSnapshot(isEnabled: snapshot.isEnabled, preferences: snapshot.preferences.filter { $0.id != id })
    }

    /// Reset removes this scope's overrides; broader saved choices may become
    /// effective again. It does not rewrite preferences in other scopes.
    func reset(scope: ComposeWritingPreferenceScope) {
        replaceSnapshot(isEnabled: snapshot.isEnabled, preferences: snapshot.preferences.filter { $0.scope != scope })
    }

    func resetAll() {
        replaceSnapshot(isEnabled: snapshot.isEnabled, preferences: [])
    }

    func expirePreferences(at now: Date) {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return }
        if prunesExpiredRecords {
            let retained = snapshot.preferences.filter { $0.expiresAt.map({ $0 > now }) ?? true }
            if retained.count != snapshot.preferences.count {
                replaceSnapshot(isEnabled: snapshot.isEnabled, preferences: retained)
            }
        }
        pending = pending.filter { $0.value.expiresAt > now }
    }

    private func replaceSnapshot(isEnabled: Bool, preferences: [ComposeWritingPreference]) {
        snapshot = .init(isEnabled: isEnabled, preferences: preferences)
        // Every material change fences pending saves and cached resolutions.
        pending.removeAll()
    }

    private func validateTime(_ now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw ComposeWritingPreferenceError.invalidTimeWindow }
    }
}
