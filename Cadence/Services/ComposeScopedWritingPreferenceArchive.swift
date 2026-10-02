import Foundation
import OSLog

private let composeScopedPreferenceArchiveLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeScopedPreferenceArchive"
)

enum ComposeScopedWritingPreferenceArchiveError: Error, Equatable {
    case unreadable
    case invalidPreference
    case staleEdit
}

/// Explicitly saved, closed writing choices only. The archive contains opaque
/// scope keys, never account names, transcripts, source text, or model output.
/// A newer or corrupt archive is preserved until an explicit recovery action.
struct ComposeScopedWritingPreferenceArchive {
    static let maximumBytes = 65_536
    static let emptyRevision = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let defaults: UserDefaults
    let key: String

    func load() throws -> ComposeWritingPreferenceSnapshot {
        guard let object = defaults.object(forKey: key) else {
            return .init(revision: Self.emptyRevision)
        }
        guard let data = object as? Data, data.count <= Self.maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1,
              envelope.revision != Self.emptyRevision,
              envelope.preferences.count <= ComposePreferenceResolver.maximumPreferences else {
            throw ComposeScopedWritingPreferenceArchiveError.unreadable
        }
        do {
            let preferences = try envelope.preferences.map { try $0.preference() }
            try Self.validate(preferences)
            return .init(
                revision: envelope.revision, isEnabled: envelope.isEnabled,
                preferences: preferences
            )
        } catch {
            throw ComposeScopedWritingPreferenceArchiveError.unreadable
        }
    }

    /// The caller must have collected an explicit Save decision and validated
    /// the live adapter scope before constructing a scoped preference. The
    /// revision fence prevents a stale editor from replacing a later save.
    func save(
        _ snapshot: ComposeWritingPreferenceSnapshot,
        replacing expected: ComposeWritingPreferenceSnapshot
    ) throws {
        guard try load() == expected else {
            throw ComposeScopedWritingPreferenceArchiveError.staleEdit
        }
        guard snapshot.revision != expected.revision,
              snapshot.revision != Self.emptyRevision else {
            throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
        }
        try Self.validate(snapshot.preferences)
        let envelope = Envelope(
            schemaVersion: 1, revision: snapshot.revision,
            isEnabled: snapshot.isEnabled,
            preferences: try snapshot.preferences.map { try StoredPreference($0) }
        )
        guard let data = try? JSONEncoder().encode(envelope),
              data.count <= Self.maximumBytes else {
            throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
        }
        defaults.set(data, forKey: key)
    }

    /// Removing an unreadable value requires a separate user recovery choice.
    /// A value repaired by another editor is never removed by an old action.
    func removeUnreadableArchive() throws {
        do { _ = try load() }
        catch ComposeScopedWritingPreferenceArchiveError.unreadable {
            defaults.removeObject(forKey: key)
            return
        }
        throw ComposeScopedWritingPreferenceArchiveError.staleEdit
    }

    private static func validate(_ preferences: [ComposeWritingPreference]) throws {
        guard preferences.count <= ComposePreferenceResolver.maximumPreferences,
              Set(preferences.map(\.id)).count == preferences.count else {
            throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
        }
        var fieldsByScope = Set<String>()
        for preference in preferences {
            guard (try? ComposePreferenceResolver.validate(preference.value)) != nil else {
                throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
            }
            guard preference.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  preference.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  preference.createdAt <= preference.updatedAt,
                  preference.expiresAt.map({
                    $0.timeIntervalSinceReferenceDate.isFinite && $0 > preference.updatedAt
                  }) ?? true else {
                throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
            }
            let scope = try StoredScope(preference.scope)
            let fieldKey = "\(scope.kind.rawValue):\(scope.key ?? ""):\(preference.value.field.rawValue)"
            guard fieldsByScope.insert(fieldKey).inserted else {
                throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
            }
        }
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let revision: UUID
        let isEnabled: Bool
        let preferences: [StoredPreference]
    }

    private struct StoredPreference: Codable {
        let id: UUID
        let scope: StoredScope
        let value: StoredValue
        let createdAt: Date
        let updatedAt: Date
        let expiresAt: Date?

        init(_ preference: ComposeWritingPreference) throws {
            id = preference.id
            scope = try StoredScope(preference.scope)
            value = StoredValue(preference.value)
            createdAt = preference.createdAt
            updatedAt = preference.updatedAt
            expiresAt = preference.expiresAt
        }

        func preference() throws -> ComposeWritingPreference {
            .init(
                id: id, scope: try scope.preferenceScope(),
                value: try value.preferenceValue(),
                createdAt: createdAt, updatedAt: updatedAt, expiresAt: expiresAt
            )
        }
    }

    private struct StoredScope: Codable {
        enum Kind: String, Codable { case global, application, project, conversation }
        let kind: Kind
        let key: String?

        init(_ scope: ComposeWritingPreferenceScope) throws {
            switch scope {
            case .global:
                kind = .global; key = nil
            case let .application(value):
                kind = .application; key = value.opaqueValue
            case let .project(value):
                kind = .project; key = value.opaqueValue
            case let .conversation(value):
                kind = .conversation; key = value.opaqueValue
            case .currentAction:
                throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
            }
            guard (kind == .global && key == nil)
                || (key.map(Self.validOpaqueKey) == true) else {
                throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
            }
        }

        func preferenceScope() throws -> ComposeWritingPreferenceScope {
            switch kind {
            case .global:
                guard key == nil else { break }
                return .global
            case .application:
                if let key, Self.validOpaqueKey(key) {
                    return .application(.init(opaqueValue: key))
                }
            case .project:
                if let key, Self.validOpaqueKey(key) {
                    return .project(.init(opaqueValue: key))
                }
            case .conversation:
                if let key, Self.validOpaqueKey(key) {
                    return .conversation(.init(opaqueValue: key))
                }
            }
            throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
        }

        private static func validOpaqueKey(_ key: String) -> Bool {
            key.utf8.count == 64 && key.utf8.allSatisfy {
                (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
            }
        }
    }

    private struct StoredValue: Codable {
        enum Kind: String, Codable {
            case formal, casual, polite, professional, warm, upbeat
            case concise, prose, reply, bullets, avoidUnstatedReasons
        }
        let kind: Kind
        let bulletCount: Int?

        init(_ value: ComposeWritingPreferenceValue) {
            switch value {
            case .tone(.formal): kind = .formal; bulletCount = nil
            case .tone(.casual): kind = .casual; bulletCount = nil
            case .tone(.polite): kind = .polite; bulletCount = nil
            case .tone(.professional): kind = .professional; bulletCount = nil
            case .tone(.warm): kind = .warm; bulletCount = nil
            case .tone(.upbeat): kind = .upbeat; bulletCount = nil
            case .concise: kind = .concise; bulletCount = nil
            case .formatting(.prose): kind = .prose; bulletCount = nil
            case .formatting(.reply): kind = .reply; bulletCount = nil
            case let .formatting(.bullets(count)):
                kind = .bullets; bulletCount = count
            case .avoidUnstatedReasons: kind = .avoidUnstatedReasons; bulletCount = nil
            }
        }

        func preferenceValue() throws -> ComposeWritingPreferenceValue {
            if kind != .bullets && bulletCount != nil {
                throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
            }
            switch kind {
            case .formal: return .tone(.formal)
            case .casual: return .tone(.casual)
            case .polite: return .tone(.polite)
            case .professional: return .tone(.professional)
            case .warm: return .tone(.warm)
            case .upbeat: return .tone(.upbeat)
            case .concise: return .concise
            case .prose: return .formatting(.prose)
            case .reply: return .formatting(.reply)
            case .bullets:
                guard let bulletCount,
                      (1...ComposePreferenceResolver.maximumBulletCount).contains(bulletCount) else {
                    throw ComposeScopedWritingPreferenceArchiveError.invalidPreference
                }
                return .formatting(.bullets(count: bulletCount))
            case .avoidUnstatedReasons: return .avoidUnstatedReasons
            }
        }
    }
}
