import Darwin
import Foundation
import OSLog

private let composeTextEditWritingDefaultsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeTextEditDefaults"
)

/// A named first app profile. Settings chooses TextEdit explicitly; runtime
/// admits it only for a pinned TextEdit process on this macOS user account.
/// No document text, window title, or conversation identity is read here.
@MainActor
struct ComposeTextEditWritingDefaultsStore {
    private let archive: ComposeScopedWritingPreferenceArchive
    private let localUserID: UInt32

    init(archive: ComposeScopedWritingPreferenceArchive, localUserID: UInt32 = getuid()) {
        self.archive = archive
        self.localUserID = localUserID
    }

    var applicationKey: ComposePreferenceApplicationKey {
        let account = ScribeConversationStableID(rawValue: "macos-uid-\(localUserID)")!
        return ComposePreferenceScopeFactory.applicationKey(
            registration: ScribeTextEditDocumentIdentityAdapter.preferenceRegistration,
            accountID: account
        )
    }

    func load(now: Date = Date()) throws -> ComposeTextEditWritingDefaults {
        Self.choices(in: try archive.load(), for: applicationKey, at: now)
    }

    func save(
        _ choices: ComposeTextEditWritingDefaults,
        replacing expected: ComposeTextEditWritingDefaults,
        now: Date = Date()
    ) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
        }
        let previous = try archive.load()
        guard Self.choices(in: previous, for: applicationKey, at: now) == expected else {
            throw ComposeScopedWritingPreferenceArchiveError.staleEdit
        }
        let scope = ComposeWritingPreferenceScope.application(applicationKey)
        let fields: [ComposeWritingPreferenceField] = [.tone, .length]
        var next = previous.preferences.filter {
            $0.scope != scope || !fields.contains($0.value.field)
        }
        for value in choices.values {
            let existing = previous.preferences.first {
                $0.scope == scope && $0.value.field == value.field
            }
            guard existing.map({ $0.updatedAt <= now }) ?? true else {
                throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
            }
            next.append(.init(
                id: existing?.id ?? UUID(), scope: scope, value: value,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now, expiresAt: nil
            ))
        }
        try archive.save(
            .init(
                isEnabled: choices.values.isEmpty ? previous.isEnabled : true,
                preferences: next
            ),
            replacing: previous
        )
    }

    func reset(
        replacing expected: ComposeTextEditWritingDefaults,
        now: Date = Date()
    ) throws {
        try save(.init(), replacing: expected, now: now)
    }

    func values(
        for target: ApplicationTargetCapture, now: Date = Date()
    ) throws -> [ComposeWritingPreferenceValue] {
        guard target.source == .scribeAccessibility,
              target.process.bundleIdentifier == ScribeTextEditDocumentIdentityAdapter.bundleIdentifier,
              target.process.bundleURL == URL(fileURLWithPath: "/System/Applications/TextEdit.app")
                .standardizedFileURL.resolvingSymlinksInPath() else { return [] }
        let snapshot = try archive.load()
        guard snapshot.isEnabled else { return [] }
        return Self.choices(in: snapshot, for: applicationKey, at: now).values
    }

    private static func choices(
        in snapshot: ComposeWritingPreferenceSnapshot,
        for key: ComposePreferenceApplicationKey,
        at now: Date
    ) -> ComposeTextEditWritingDefaults {
        let scoped = snapshot.preferences.filter {
            $0.scope == .application(key)
                && $0.updatedAt <= now
                && ($0.expiresAt.map { $0 > now } ?? true)
        }
        var choices = ComposeTextEditWritingDefaults()
        for record in scoped {
            switch record.value {
            case .tone(.formal): choices.tone = .formal
            case .tone(.casual): choices.tone = .casual
            case .tone(.polite): choices.tone = .polite
            case .tone(.professional): choices.tone = .professional
            case .tone(.warm): choices.tone = .warm
            case .tone(.upbeat): choices.tone = .upbeat
            case .concise: choices.preferConcise = true
            default: break
            }
        }
        return choices
    }
}
