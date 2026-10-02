import Foundation
import Testing
@testable import Cadence

@MainActor
struct ComposeScopedWritingPreferenceArchiveTests {
    @Test
    func explicitEditCommitsToArchiveAndSurvivesRestart() throws {
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archive = ComposeScopedWritingPreferenceArchive(defaults: defaults, key: "scoped-writing")
        let controller = try ComposeScopedWritingPreferenceController(archive: archive)
        let context = try context(account: "account-a", project: "project-a")
        let scope = ComposeWritingPreferenceScope.application(try #require(context.application?.key))
        let now = Date(timeIntervalSince1970: 2_000)

        try controller.setEnabled(true, replacing: controller.snapshot)
        let cancelled = try controller.beginUserEdit(scope: scope, context: context, now: now)
        controller.cancelEdit(cancelled)
        #expect(controller.snapshot.preferences.isEmpty)
        let token = try controller.beginUserEdit(scope: scope, context: context, now: now)
        let saved = try controller.saveUserPreference(
            .init(scope: scope, value: .concise, expiresAt: nil),
            using: token, context: context, now: now
        )
        let restarted = try ComposeScopedWritingPreferenceController(archive: archive)
        #expect(restarted.snapshot.preferences == [saved])
        #expect(try ComposePreferenceResolver.resolve(
            snapshot: restarted.snapshot, context: context, now: now
        ).preferences.map(\.value) == [.concise])
        try restarted.deletePreference(id: saved.id, replacing: restarted.snapshot)
        #expect(try archive.load().preferences.isEmpty)
    }

    @Test
    func staleWriteLeavesActiveAndArchivedSnapshotsUnchanged() throws {
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archive = ComposeScopedWritingPreferenceArchive(defaults: defaults, key: "scoped-writing")
        let first = try ComposeScopedWritingPreferenceController(archive: archive)
        try first.setEnabled(true, replacing: first.snapshot)
        let second = try ComposeScopedWritingPreferenceController(archive: archive)
        let context = try context(account: "account-a", project: "project-a")
        let scope = ComposeWritingPreferenceScope.application(try #require(context.application?.key))
        let now = Date(timeIntervalSince1970: 2_000)
        let staleToken = try second.beginUserEdit(scope: scope, context: context, now: now)
        let currentToken = try first.beginUserEdit(scope: scope, context: context, now: now)
        let saved = try first.saveUserPreference(
            .init(scope: scope, value: .tone(.formal), expiresAt: now.addingTimeInterval(1)),
            using: currentToken, context: context, now: now
        )
        let before = second.snapshot
        #expect(throws: ComposeScopedWritingPreferenceArchiveError.staleEdit) {
            try second.saveUserPreference(
                .init(scope: scope, value: .tone(.warm), expiresAt: nil),
                using: staleToken, context: context, now: now
            )
        }
        #expect(second.snapshot == before)
        #expect(try archive.load().preferences == [saved])

        try second.reload()
        let afterExpiry = now.addingTimeInterval(2)
        let nextToken = try second.beginUserEdit(scope: scope, context: context, now: afterExpiry)
        _ = try second.saveUserPreference(
            .init(scope: scope, value: .concise, expiresAt: nil),
            using: nextToken, context: context, now: afterExpiry
        )
        #expect(try archive.load().preferences.count == 2)
        #expect(try ComposePreferenceResolver.resolve(
            snapshot: second.snapshot, context: context, now: afterExpiry
        ).preferences.map(\.value) == [.concise])
    }

    @Test
    func explicitSaveRoundTripsScopedChoicesWithoutCrossAccountUse() throws {
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archive = ComposeScopedWritingPreferenceArchive(defaults: defaults, key: "scoped-writing")
        let empty = try archive.load()
        let first = try context(account: "account-a", project: "project-a")
        let otherAccount = try context(account: "account-b", project: "project-a")
        let otherProject = try context(account: "account-a", project: "project-b")
        let now = Date(timeIntervalSince1970: 2_000)
        let appKey = try #require(first.application?.key)
        let projectKey = try #require(first.project?.key)
        let saved: [ComposeWritingPreference] = [
            .init(id: UUID(), scope: .global, value: .tone(.casual),
                  createdAt: now, updatedAt: now, expiresAt: nil),
            .init(id: UUID(), scope: .application(appKey), value: .concise,
                  createdAt: now, updatedAt: now, expiresAt: nil),
            .init(id: UUID(), scope: .project(projectKey), value: .tone(.formal),
                  createdAt: now, updatedAt: now, expiresAt: nil)
        ]
        let snapshot = ComposeWritingPreferenceSnapshot(
            isEnabled: true, preferences: saved
        )
        try archive.save(snapshot, replacing: empty)
        let reopened = try archive.load()
        #expect(reopened == snapshot)
        #expect(try ComposePreferenceResolver.resolve(
            snapshot: reopened, context: first, now: now
        ).preferences.map(\.value) == [.tone(.formal), .concise])
        #expect(try ComposePreferenceResolver.resolve(
            snapshot: reopened, context: otherAccount, now: now
        ).preferences.map(\.value) == [.tone(.casual)])
        #expect(try ComposePreferenceResolver.resolve(
            snapshot: reopened, context: otherProject, now: now
        ).preferences.map(\.value) == [.tone(.casual), .concise])

        let next = ComposeWritingPreferenceSnapshot(
            isEnabled: true, preferences: saved.filter { $0.scope != .project(projectKey) }
        )
        try archive.save(next, replacing: reopened)
        #expect(throws: ComposeScopedWritingPreferenceArchiveError.staleEdit) {
            try archive.save(snapshot, replacing: empty)
        }
        #expect(try archive.load() == next)

        let controller = try ComposeScopedWritingPreferenceController(archive: archive)
        try controller.reset(scope: .application(appKey), replacing: controller.snapshot)
        #expect(try archive.load().preferences.map(\.value) == [.tone(.casual)])
    }

    @Test
    func transientAndMalformedScopesCannotEnterTheArchive() throws {
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let archive = ComposeScopedWritingPreferenceArchive(defaults: defaults, key: "scoped-writing")
        let empty = try archive.load()
        let now = Date(timeIntervalSince1970: 2_000)
        let transient = ComposeWritingPreferenceSnapshot(isEnabled: true, preferences: [
            .init(id: UUID(), scope: .currentAction(UUID()), value: .concise,
                  createdAt: now, updatedAt: now, expiresAt: nil)
        ])
        #expect(throws: ComposeScopedWritingPreferenceArchiveError.invalidPreference) {
            try archive.save(transient, replacing: empty)
        }
        let untrustedKey = ComposeWritingPreferenceSnapshot(isEnabled: true, preferences: [
            .init(id: UUID(), scope: .application(.init(opaqueValue: "account@example.com")),
                  value: .tone(.warm), createdAt: now, updatedAt: now, expiresAt: nil)
        ])
        #expect(throws: ComposeScopedWritingPreferenceArchiveError.invalidPreference) {
            try archive.save(untrustedKey, replacing: empty)
        }
        #expect(try archive.load() == empty)
    }

    @Test
    func newerAndCorruptPayloadsArePreservedUntilExplicitRecovery() throws {
        let (defaults, suiteName) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "scoped-writing"
        let archive = ComposeScopedWritingPreferenceArchive(defaults: defaults, key: key)
        let future = Data("{\"schemaVersion\":2,\"revision\":\"\(UUID().uuidString)\",\"isEnabled\":true,\"preferences\":[]}".utf8)
        defaults.set(future, forKey: key)
        #expect(throws: ComposeScopedWritingPreferenceArchiveError.unreadable) {
            try archive.load()
        }
        #expect(throws: ComposeScopedWritingPreferenceArchiveError.unreadable) {
            try archive.save(.init(), replacing: .init(revision: ComposeScopedWritingPreferenceArchive.emptyRevision))
        }
        #expect(defaults.data(forKey: key) == future)
        try archive.removeUnreadableArchive()
        #expect(try archive.load().preferences.isEmpty)
        #expect(throws: ComposeScopedWritingPreferenceArchiveError.staleEdit) {
            try archive.removeUnreadableArchive()
        }
    }

    private func temporaryDefaults() throws -> (UserDefaults, String) {
        let name = "cadence-scoped-writing-archive-tests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func context(account: String, project: String) throws -> ComposeWritingPreferenceContext {
        let adapter = try #require(ScribeConversationStableID(rawValue: "archive-adapter"))
        let application = try #require(ScribeConversationStableID(rawValue: "archive-app"))
        let binding = ScribeConversationActionBinding(
            actionID: UUID(), process: .init(
                processIdentifier: 42, bundleIdentifier: "com.example.browser",
                bundleURL: URL(fileURLWithPath: "/Applications/SyntheticBrowser.app"),
                incarnation: UUID()
            ),
            windowIncarnation: UUID(), tabIncarnation: UUID(), navigationRevision: UUID()
        )
        let registration = ScribeConversationAdapterRegistration(
            adapterID: adapter, schemaVersion: 1, source: .browserIntegration,
            hostBundleIdentifier: "com.example.browser", applicationID: application
        )
        let evidence = ScribeConversationIdentityEvidence(
            adapterID: adapter, schemaVersion: 1, source: .browserIntegration,
            binding: binding, confidence: .verifiedStableIdentifiers,
            privacyState: .regular, applicationID: application,
            accountID: ScribeConversationStableID(rawValue: account),
            workspaceID: .identified(ScribeConversationStableID(rawValue: "workspace-a")!),
            projectID: .identified(ScribeConversationStableID(rawValue: project)!),
            conversationID: ScribeConversationStableID(rawValue: "thread-a")
        )
        return try ComposePreferenceScopeFactory.context(
            evidence: evidence, registration: registration, currentBinding: binding
        )
    }
}
