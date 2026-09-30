import Foundation
import Testing
@testable import Cadence

struct ComposePreferenceResolverTests {
    @Test
    func precedenceResolvesEachFieldWithoutMutatingSavedChoices() throws {
        let fixture = try PreferenceFixture()
        let context = fixture.context
        let saved = [
            fixture.preference(.global, .tone(.casual)),
            fixture.preference(.application(context.application!.key), .tone(.professional)),
            fixture.preference(.project(context.project!.key), .tone(.formal)),
            fixture.preference(.project(context.project!.key), .concise),
            fixture.preference(.conversation(context.conversation!.memoryKey), .tone(.polite)),
            fixture.preference(.currentAction(context.binding.actionID), .tone(.warm)),
            fixture.preference(.global, .formatting(.prose))
        ]
        let snapshot = ComposeWritingPreferenceSnapshot(isEnabled: true, preferences: saved)
        let resolved = try ComposePreferenceResolver.resolve(
            snapshot: snapshot, context: context, currentAction: [.tone(.professional)],
            currentVoice: [.tone(.formal), .bullets(count: 2)], now: fixture.now
        )
        #expect(resolved.preferences.map(\.value) == [.tone(.formal), .concise, .formatting(.bullets(count: 2))])
        #expect(resolved.preferences[0].provenance == .currentVoice(index: 0))
        #expect(resolved.preferences[1].provenance == .saved(id: saved[3].id, scope: saved[3].scope))
        #expect(resolved.conflicts.map(\.field) == [.tone, .formatting])
        #expect(snapshot.preferences == saved)
        #expect(resolved.compiledInstructions.utf8.count <= ComposePreferenceResolver.maximumCompiledUTF8Bytes)
    }

    @Test
    func eachScopeOverridesOnlyItsBroaderDefaults() throws {
        let fixture = try PreferenceFixture()
        let context = fixture.context
        let scopes: [ComposeWritingPreferenceScope] = [
            .global, .application(context.application!.key), .project(context.project!.key),
            .conversation(context.conversation!.memoryKey), .currentAction(context.binding.actionID)
        ]
        for count in 1...scopes.count {
            let saved = scopes.prefix(count).enumerated().map { index, scope in
                fixture.preference(scope, .formatting(.bullets(count: index + 1)))
            }
            let result = try ComposePreferenceResolver.resolve(snapshot: .init(isEnabled: true, preferences: saved), context: context, now: fixture.now)
            #expect(result.preferences.first?.value == .formatting(.bullets(count: count)))
        }
    }

    @Test
    func currentVoiceCorrectionsAndEqualRankConflictsHaveStableOrder() throws {
        let fixture = try PreferenceFixture()
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let formal = fixture.preference(.global, .tone(.formal), id: earlierID)
        let casual = fixture.preference(.global, .tone(.casual), id: laterID)
        let revision = UUID()
        let first = try ComposePreferenceResolver.resolve(snapshot: .init(revision: revision, isEnabled: true, preferences: [casual, formal]), context: fixture.context, now: fixture.now)
        let second = try ComposePreferenceResolver.resolve(snapshot: .init(revision: revision, isEnabled: true, preferences: [formal, casual]), context: fixture.context, now: fixture.now)
        #expect(first == second)
        #expect(first.preferences.first?.value == .tone(.formal))
        let corrected = try ComposePreferenceResolver.resolve(snapshot: .init(), context: fixture.context, currentVoice: [.tone(.formal), .tone(.warm)], now: fixture.now)
        #expect(corrected.preferences.first?.value == .tone(.warm))
    }

    @Test
    func disabledPreferencesDoNotOverrideExplicitCurrentVoiceOrAction() throws {
        let fixture = try PreferenceFixture()
        let malformedSaved = fixture.preference(.global, .formatting(.bullets(count: 0)))
        let result = try ComposePreferenceResolver.resolve(
            snapshot: .init(preferences: [malformedSaved, malformedSaved]), context: fixture.context,
            currentAction: [.concise], currentVoice: [.tone(.casual)], now: fixture.now
        )
        #expect(result.preferences.map(\.value) == [.tone(.casual), .concise])
        #expect(try ComposePreferenceResolver.resolve(snapshot: .init(), context: fixture.context, now: fixture.now).compiledInstructions.isEmpty)
    }

    @Test
    func expirationAndFreshnessIncludeSnapshotScopeAndCurrentInstructionChanges() throws {
        let fixture = try PreferenceFixture()
        let expiration = fixture.now.addingTimeInterval(10)
        let record = fixture.preference(.global, .concise, expiresAt: expiration)
        let snapshot = ComposeWritingPreferenceSnapshot(isEnabled: true, preferences: [record])
        let result = try ComposePreferenceResolver.resolve(snapshot: snapshot, context: fixture.context, currentVoice: [.tone(.warm)], now: fixture.now)
        #expect(result.validUntil == expiration)
        #expect(ComposePreferenceResolver.isCurrent(result, snapshot: snapshot, context: fixture.context, currentVoice: [.tone(.warm)], now: fixture.now))
        #expect(!ComposePreferenceResolver.isCurrent(result, snapshot: snapshot, context: fixture.context, currentVoice: [.tone(.formal)], now: fixture.now))
        #expect(!ComposePreferenceResolver.isCurrent(result, snapshot: snapshot, context: fixture.context, currentVoice: [.tone(.warm)], now: expiration))
        #expect(!ComposePreferenceResolver.isCurrent(result, snapshot: .init(isEnabled: true, preferences: [record]), context: fixture.context, currentVoice: [.tone(.warm)], now: fixture.now))
        #expect(try ComposePreferenceResolver.resolve(snapshot: snapshot, context: fixture.context, now: expiration).preferences.isEmpty)
    }

    @Test
    func futureSaveInvalidatesFallbackAtItsActivationTime() throws {
        let fixture = try PreferenceFixture()
        let activation = fixture.now.addingTimeInterval(10)
        let record = ComposeWritingPreference(id: UUID(), scope: .global, value: .concise, createdAt: activation, updatedAt: activation, expiresAt: nil)
        let snapshot = ComposeWritingPreferenceSnapshot(isEnabled: true, preferences: [record])
        let before = try ComposePreferenceResolver.resolve(snapshot: snapshot, context: fixture.context, now: fixture.now)
        #expect(before.preferences.isEmpty)
        #expect(before.validUntil == activation)
        #expect(!ComposePreferenceResolver.isCurrent(before, snapshot: snapshot, context: fixture.context, now: activation))
        #expect(try ComposePreferenceResolver.resolve(snapshot: snapshot, context: fixture.context, now: activation).preferences.map(\.value) == [.concise])
    }

    @Test
    func scopedDefaultsDoNotFollowChangedActionBindings() throws {
        let fixture = try PreferenceFixture()
        let saved = [
            fixture.preference(.global, .tone(.casual)),
            fixture.preference(.application(fixture.context.application!.key), .tone(.formal)),
            fixture.preference(.project(fixture.context.project!.key), .concise),
            fixture.preference(.conversation(fixture.context.conversation!.memoryKey), .formatting(.reply)),
            fixture.preference(.currentAction(fixture.context.binding.actionID), .avoidUnstatedReasons)
        ]
        let changed = ComposeWritingPreferenceContext(
            binding: PreferenceFixture.binding(), application: fixture.context.application,
            project: fixture.context.project, conversation: fixture.context.conversation
        )
        let result = try ComposePreferenceResolver.resolve(snapshot: .init(isEnabled: true, preferences: saved), context: changed, now: fixture.now)
        #expect(result.preferences.map(\.value) == [.tone(.casual)])
    }

    @Test
    func accountAndProjectKeysAreIsolatedAndNeverCompiled() throws {
        let fixture = try PreferenceFixture()
        let accountB = try PreferenceFixture.scopeContext(binding: fixture.context.binding, account: "account-b")
        let projectB = try PreferenceFixture.scopeContext(binding: fixture.context.binding, project: "project-b")
        let caseVariant = try PreferenceFixture.scopeContext(binding: fixture.context.binding, project: "Project-a")
        #expect(accountB.application?.key != fixture.context.application?.key)
        #expect(accountB.project?.key != fixture.context.project?.key)
        #expect(projectB.application?.key == fixture.context.application?.key)
        #expect(projectB.project?.key != fixture.context.project?.key)
        #expect(caseVariant.project?.key != fixture.context.project?.key)
        let saved = [fixture.preference(.application(fixture.context.application!.key), .tone(.warm)), fixture.preference(.project(fixture.context.project!.key), .concise)]
        #expect(try ComposePreferenceResolver.resolve(snapshot: .init(isEnabled: true, preferences: saved), context: accountB, now: fixture.now).preferences.isEmpty)
        let result = try ComposePreferenceResolver.resolve(snapshot: .init(isEnabled: true, preferences: saved), context: projectB, now: fixture.now)
        #expect(result.preferences.map(\.value) == [.tone(.warm)])
        for identity in ["account-a", "project-a", fixture.context.application!.key.opaqueValue, fixture.context.binding.actionID.uuidString] {
            #expect(!result.compiledInstructions.contains(identity))
        }
    }

    @Test
    func missingOrPrivateEvidenceCannotAcquireScopeAndUnknownProjectDoesNotBroaden() throws {
        let binding = PreferenceFixture.binding()
        #expect(throws: ComposeWritingPreferenceError.invalidIdentity) {
            try PreferenceFixture.scopeContext(binding: binding, account: nil)
        }
        #expect(throws: ComposeWritingPreferenceError.invalidIdentity) {
            try PreferenceFixture.scopeContext(binding: binding, privacy: .privateBrowsing)
        }
        #expect(try PreferenceFixture.scopeContext(binding: binding, project: nil).project == nil)
        #expect(try PreferenceFixture.scopeContext(binding: binding, workspaceUnknown: true).project == nil)
    }

    @MainActor @Test
    func conversationKeyMustMatchFreshAccountEvidenceEvenWithoutNavigationBump() throws {
        let binding = PreferenceFixture.binding()
        let input = PreferenceFixture.factoryInput(binding: binding)
        let adapter = PreferenceIdentityAdapter(registration: input.registration, suppliedEvidence: input.evidence)
        let resolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        guard case let .verified(verified) = resolver.resolve(adapterID: input.registration.adapterID, for: binding) else {
            Issue.record("Expected a synthetic verified conversation")
            return
        }
        let valid = try ComposePreferenceScopeFactory.context(evidence: input.evidence, registration: input.registration, currentBinding: binding, conversation: verified)
        #expect(valid.conversation == verified)
        let changed = PreferenceFixture.factoryInput(binding: binding, account: "account-b")
        #expect(throws: ComposeWritingPreferenceError.invalidIdentity) {
            try ComposePreferenceScopeFactory.context(evidence: changed.evidence, registration: changed.registration, currentBinding: binding, conversation: verified)
        }
    }

    @Test
    func invalidChoicesAndUnboundedInputFailBeforeCompiling() throws {
        let fixture = try PreferenceFixture()
        #expect(throws: ComposeWritingPreferenceError.invalidValue) {
            try ComposePreferenceResolver.resolve(snapshot: .init(), context: fixture.context, currentVoice: [.bullets(count: 0)], now: fixture.now)
        }
        #expect(throws: ComposeWritingPreferenceError.tooManyPreferences) {
            try ComposePreferenceResolver.resolve(snapshot: .init(), context: fixture.context, currentVoice: Array(repeating: .concise, count: 33), now: fixture.now)
        }
    }
}

@MainActor
struct ComposeWritingPreferenceStoreTests {
    @Test
    func explicitOptInSaveCancelAndRestartHaveTruthfulInMemorySemantics() throws {
        let fixture = try PreferenceFixture()
        let store = ComposeWritingPreferenceStore()
        #expect(!store.snapshot.isEnabled && store.snapshot.preferences.isEmpty)
        #expect(throws: ComposeWritingPreferenceError.disabled) {
            try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        }
        store.setEnabled(true)
        let token = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        store.cancelEdit(token)
        #expect(throws: ComposeWritingPreferenceError.unknownEdit) {
            try store.saveUserPreference(.init(scope: .global, value: .concise, expiresAt: nil), using: token, context: fixture.context, now: fixture.now)
        }
        #expect(store.snapshot.preferences.isEmpty)
        let save = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        try store.saveUserPreference(.init(scope: .global, value: .concise, expiresAt: nil), using: save, context: fixture.context, now: fixture.now)
        #expect(store.snapshot.preferences.count == 1)
        #expect(ComposeWritingPreferenceStore().snapshot.preferences.isEmpty)
    }

    @Test
    func saveReplacesOnlyChosenFieldAndResetExposesBroaderDefault() throws {
        let fixture = try PreferenceFixture()
        let store = ComposeWritingPreferenceStore()
        store.setEnabled(true)
        let global = try save(.tone(.casual), scope: .global, store: store, fixture: fixture)
        let scope = ComposeWritingPreferenceScope.conversation(fixture.context.conversation!.memoryKey)
        let first = try save(.tone(.formal), scope: scope, store: store, fixture: fixture)
        let second = try save(.tone(.warm), scope: scope, store: store, fixture: fixture)
        #expect(first.id == second.id)
        #expect(store.snapshot.preferences.count == 2)
        #expect(try ComposePreferenceResolver.resolve(snapshot: store.snapshot, context: fixture.context, now: fixture.now).preferences.first?.value == .tone(.warm))
        store.reset(scope: scope)
        #expect(store.snapshot.preferences == [global])
        #expect(try ComposePreferenceResolver.resolve(snapshot: store.snapshot, context: fixture.context, now: fixture.now).preferences.first?.value == .tone(.casual))
    }

    @Test
    func deletionAndExpiryFencePendingSavesAndCachedResolutions() throws {
        let fixture = try PreferenceFixture()
        let store = ComposeWritingPreferenceStore()
        store.setEnabled(true)
        let record = try save(.concise, scope: .global, store: store, fixture: fixture)
        let result = try ComposePreferenceResolver.resolve(snapshot: store.snapshot, context: fixture.context, now: fixture.now)
        let stale = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        store.deletePreference(id: record.id)
        #expect(!ComposePreferenceResolver.isCurrent(result, snapshot: store.snapshot, context: fixture.context, now: fixture.now))
        #expect(throws: ComposeWritingPreferenceError.staleEdit) {
            try store.saveUserPreference(.init(scope: .global, value: .concise, expiresAt: nil), using: stale, context: fixture.context, now: fixture.now)
        }
        let expiring = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        try store.saveUserPreference(.init(scope: .global, value: .concise, expiresAt: fixture.now.addingTimeInterval(1)), using: expiring, context: fixture.context, now: fixture.now)
        let pending = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        #expect(throws: ComposeWritingPreferenceError.staleEdit) {
            try store.saveUserPreference(.init(scope: .global, value: .concise, expiresAt: nil), using: pending, context: fixture.context, now: fixture.now.addingTimeInterval(1))
        }
        #expect(store.snapshot.preferences.isEmpty)
    }

    @Test
    func changedScopeExpiredEditAndDisableCannotCommit() throws {
        let fixture = try PreferenceFixture()
        let store = ComposeWritingPreferenceStore()
        store.setEnabled(true)
        let token = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        let changed = ComposeWritingPreferenceContext(binding: PreferenceFixture.binding())
        #expect(throws: ComposeWritingPreferenceError.scopeChanged) {
            try store.saveUserPreference(.init(scope: .global, value: .concise, expiresAt: nil), using: token, context: changed, now: fixture.now)
        }
        #expect(throws: ComposeWritingPreferenceError.unknownEdit) {
            try store.saveUserPreference(.init(scope: .global, value: .concise, expiresAt: nil), using: token, context: fixture.context, now: token.expiresAt)
        }
        let next = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        store.setEnabled(false)
        #expect(throws: ComposeWritingPreferenceError.disabled) {
            try store.saveUserPreference(.init(scope: .global, value: .concise, expiresAt: nil), using: next, context: fixture.context, now: fixture.now)
        }
        #expect(store.snapshot.preferences.isEmpty)
    }

    @Test
    func cancelledReplacementAndConcurrentSaveCannotRewriteAcceptedPreference() throws {
        let fixture = try PreferenceFixture()
        let store = ComposeWritingPreferenceStore()
        store.setEnabled(true)
        let accepted = try save(.tone(.formal), scope: .global, store: store, fixture: fixture)
        let before = store.snapshot
        let cancelled = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        store.cancelEdit(cancelled)
        #expect(store.snapshot == before)
        let first = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        let late = try store.beginUserEdit(scope: .global, context: fixture.context, now: fixture.now)
        let replacement = try store.saveUserPreference(.init(scope: .global, value: .tone(.warm), expiresAt: nil), using: first, context: fixture.context, now: fixture.now)
        #expect(replacement.id == accepted.id)
        #expect(throws: ComposeWritingPreferenceError.staleEdit) {
            try store.saveUserPreference(.init(scope: .global, value: .tone(.casual), expiresAt: nil), using: late, context: fixture.context, now: fixture.now)
        }
        #expect(store.snapshot.preferences == [replacement])
    }

    @Test
    func saveRejectsAccountChangeEvenWhenActionBindingWasNotUpdated() throws {
        let fixture = try PreferenceFixture()
        let store = ComposeWritingPreferenceStore()
        store.setEnabled(true)
        let scope = ComposeWritingPreferenceScope.currentAction(fixture.context.binding.actionID)
        let token = try store.beginUserEdit(scope: scope, context: fixture.context, now: fixture.now)
        let changed = try PreferenceFixture.scopeContext(binding: fixture.context.binding, account: "account-b")
        #expect(throws: ComposeWritingPreferenceError.scopeChanged) {
            try store.saveUserPreference(.init(scope: scope, value: .concise, expiresAt: nil), using: token, context: changed, now: fixture.now)
        }
        #expect(store.snapshot.preferences.isEmpty)
    }

    private func save(_ value: ComposeWritingPreferenceValue, scope: ComposeWritingPreferenceScope, store: ComposeWritingPreferenceStore, fixture: PreferenceFixture) throws -> ComposeWritingPreference {
        let token = try store.beginUserEdit(scope: scope, context: fixture.context, now: fixture.now)
        return try store.saveUserPreference(.init(scope: scope, value: value, expiresAt: nil), using: token, context: fixture.context, now: fixture.now)
    }
}

private struct PreferenceFixture {
    let now = Date(timeIntervalSince1970: 1_000)
    let context: ComposeWritingPreferenceContext

    init() throws {
        let base = try Self.scopeContext(binding: Self.binding())
        context = .init(binding: base.binding, application: base.application, project: base.project,
                        conversation: .init(memoryKey: .init(opaqueValue: "synthetic-conversation-key"), adapterID: base.application!.adapterID, binding: base.binding))
    }

    func preference(_ scope: ComposeWritingPreferenceScope, _ value: ComposeWritingPreferenceValue, id: UUID = UUID(), expiresAt: Date? = nil) -> ComposeWritingPreference {
        .init(id: id, scope: scope, value: value, createdAt: now, updatedAt: now, expiresAt: expiresAt)
    }

    static func binding() -> ScribeConversationActionBinding {
        .init(actionID: UUID(), process: .init(processIdentifier: 42, bundleIdentifier: "com.example.browser", bundleURL: URL(fileURLWithPath: "/Applications/SyntheticBrowser.app"), incarnation: UUID()), windowIncarnation: UUID(), tabIncarnation: UUID(), navigationRevision: UUID())
    }

    static func scopeContext(binding: ScribeConversationActionBinding, account: String? = "account-a", project: String? = "project-a", workspaceUnknown: Bool = false, privacy: ScribeConversationPrivacyState = .regular) throws -> ComposeWritingPreferenceContext {
        let input = factoryInput(binding: binding, account: account, project: project, workspaceUnknown: workspaceUnknown, privacy: privacy)
        return try ComposePreferenceScopeFactory.context(evidence: input.evidence, registration: input.registration, currentBinding: binding)
    }

    static func factoryInput(binding: ScribeConversationActionBinding, account: String? = "account-a", project: String? = "project-a", workspaceUnknown: Bool = false, privacy: ScribeConversationPrivacyState = .regular) -> (registration: ScribeConversationAdapterRegistration, evidence: ScribeConversationIdentityEvidence) {
        let adapter = ScribeConversationStableID(rawValue: "synthetic-adapter")!
        let application = ScribeConversationStableID(rawValue: "synthetic-application")!
        let registration = ScribeConversationAdapterRegistration(adapterID: adapter, schemaVersion: 1, source: .browserIntegration, hostBundleIdentifier: "com.example.browser", applicationID: application)
        let evidence = ScribeConversationIdentityEvidence(
            adapterID: adapter, schemaVersion: 1, source: .browserIntegration, binding: binding,
            confidence: .verifiedStableIdentifiers, privacyState: privacy, applicationID: application,
            accountID: account.flatMap { ScribeConversationStableID(rawValue: $0) },
            workspaceID: workspaceUnknown ? .unknown : .identified(ScribeConversationStableID(rawValue: "workspace-a")!),
            projectID: project.map { .identified(ScribeConversationStableID(rawValue: $0)!) } ?? .notApplicable,
            conversationID: ScribeConversationStableID(rawValue: "conversation-a")
        )
        return (registration, evidence)
    }
}

@MainActor
private final class PreferenceIdentityAdapter: ScribeConversationIdentityAdapter {
    let registration: ScribeConversationAdapterRegistration
    let suppliedEvidence: ScribeConversationIdentityEvidence
    init(registration: ScribeConversationAdapterRegistration, suppliedEvidence: ScribeConversationIdentityEvidence) {
        self.registration = registration
        self.suppliedEvidence = suppliedEvidence
    }
    func evidence(for binding: ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence? { suppliedEvidence }
}
