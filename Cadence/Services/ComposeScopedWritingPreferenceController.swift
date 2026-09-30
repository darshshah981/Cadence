import Foundation
import OSLog

private let composeScopedPreferenceControllerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeScopedPreferences"
)

/// Keeps the active edit snapshot and the versioned archive in one explicit
/// transaction. The caller supplies a freshly verified scope and invokes Save
/// only for a user choice; this owner never observes drafts or infers style.
@MainActor
final class ComposeScopedWritingPreferenceController {
    private let archive: ComposeScopedWritingPreferenceArchive
    private var editor: ComposeWritingPreferenceStore

    init(archive: ComposeScopedWritingPreferenceArchive) throws {
        self.archive = archive
        editor = ComposeWritingPreferenceStore(
            snapshot: try archive.load(), prunesExpiredRecords: false
        )
    }

    var snapshot: ComposeWritingPreferenceSnapshot { editor.snapshot }

    func reload() throws {
        editor = ComposeWritingPreferenceStore(
            snapshot: try archive.load(), prunesExpiredRecords: false
        )
    }

    func setEnabled(
        _ isEnabled: Bool, replacing expected: ComposeWritingPreferenceSnapshot
    ) throws {
        guard snapshot == expected else {
            throw ComposeScopedWritingPreferenceArchiveError.staleEdit
        }
        guard snapshot.isEnabled != isEnabled else { return }
        try replace(
            with: .init(isEnabled: isEnabled, preferences: snapshot.preferences),
            replacing: expected
        )
    }

    func beginUserEdit(
        scope: ComposeWritingPreferenceScope,
        context: ComposeWritingPreferenceContext,
        now: Date
    ) throws -> ComposeWritingPreferenceEditToken {
        try editor.beginUserEdit(scope: scope, context: context, now: now)
    }

    @discardableResult
    func saveUserPreference(
        _ draft: ComposeWritingPreferenceDraft,
        using token: ComposeWritingPreferenceEditToken,
        context: ComposeWritingPreferenceContext,
        now: Date
    ) throws -> ComposeWritingPreference {
        try editor.saveUserPreference(
            draft, using: token, context: context, now: now,
            persisting: { [archive] next, previous in
                try archive.save(next, replacing: previous)
            }
        )
    }

    func cancelEdit(_ token: ComposeWritingPreferenceEditToken) {
        editor.cancelEdit(token)
    }

    func deletePreference(
        id: UUID, replacing expected: ComposeWritingPreferenceSnapshot
    ) throws {
        guard snapshot == expected,
              snapshot.preferences.contains(where: { $0.id == id }) else {
            throw ComposeScopedWritingPreferenceArchiveError.staleEdit
        }
        try replace(
            with: .init(
                isEnabled: snapshot.isEnabled,
                preferences: snapshot.preferences.filter { $0.id != id }
            ),
            replacing: expected
        )
    }

    func reset(
        scope: ComposeWritingPreferenceScope,
        replacing expected: ComposeWritingPreferenceSnapshot
    ) throws {
        guard snapshot == expected else {
            throw ComposeScopedWritingPreferenceArchiveError.staleEdit
        }
        guard snapshot.preferences.contains(where: { $0.scope == scope }) else { return }
        try replace(
            with: .init(
                isEnabled: snapshot.isEnabled,
                preferences: snapshot.preferences.filter { $0.scope != scope }
            ),
            replacing: expected
        )
    }

    private func replace(
        with next: ComposeWritingPreferenceSnapshot,
        replacing previous: ComposeWritingPreferenceSnapshot
    ) throws {
        try archive.save(next, replacing: previous)
        editor = ComposeWritingPreferenceStore(
            snapshot: next, prunesExpiredRecords: false
        )
    }
}
