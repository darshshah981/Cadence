import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeSessionMemoryStoreTests {
    @Test
    func defaultPolicyIsDisabledAndNewStoresDoNotImportExistingMemory() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let disabled = ScribeSessionMemoryStore(
            identityResolver: fixture.resolver, actionIsCurrent: { _ in true }, clock: { fixture.now }
        )
        #expect(throws: ScribeContextPolicyRejection.disabled) {
            try disabled.beginWrite(fixture.write("Refund delayed"), for: access)
        }
        #expect(throws: ScribeContextPolicyRejection.disabled) {
            try disabled.beginRetrieval(.init(topics: ["refund"]), for: access)
        }
        _ = try fixture.commit("Refund delayed", for: access)
        let fresh = ScribeSessionMemoryStore(identityResolver: fixture.resolver,
                                             actionIsCurrent: { _ in true },
                                             policy: { fixture.policy }, clock: { fixture.now })
        let pending = try fresh.beginRetrieval(.init(topics: ["refund"]), for: access)
        #expect(try fresh.completeRetrieval(pending, for: access).facts.isEmpty)
    }

    @Test
    func refundFactsAndObservedClaimsStaySeparateFromChosenDraftsAndDelivery() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let user = try fixture.commit("My refund is delayed.", for: access)
        let observed = try fixture.commit("The visible reply says approval is pending.",
                                         provenance: .observedSource(snapshotID: UUID(), category: .selectedText), for: access)
        let draft = try fixture.commit("The refund was approved and paid.",
                                      provenance: .chosenDraft(draftID: UUID(), selection: .copied, derivedFrom: [.selectedText]), for: access)
        let factsOnly = try fixture.retrieve(for: access)
        #expect(Set(factsOnly.facts.map(\.id)) == [user.id, observed.id])
        #expect(factsOnly.chosenDrafts.isEmpty)
        let all = try fixture.retrieve(.init(topics: ["refund"], includesChosenDrafts: true), for: access)
        #expect(all.chosenDrafts.map(\.id) == [draft.id])
        #expect(draft.kind == .chosenDraft)
        #expect(user.kind == .explicitUserFact)
        #expect(observed.kind == .observedSourceFact)
        #expect(all.dataCategories == [.sessionMemory, .selectedText, .priorDraft])
        #expect(user.origin.actionID == access.contextAction.actionID)
        #expect(user.origin.captureID == access.contextAction.captureID)
    }

    @Test
    func accountThreadWorkspaceAndProjectSwitchesCannotReadAnotherScope() throws {
        let fixture = MemoryFixture()
        let firstA = try fixture.access()
        let a = try fixture.commit("Account A refund", for: firstA)
        let variants = [
            ("account-a", "workspace-a", "project-a", "thread-b"),
            ("account-b", "workspace-a", "project-a", "thread-a"),
            ("account-a", "workspace-b", "project-a", "thread-a"),
            ("account-a", "workspace-a", "project-b", "thread-a")
        ]
        for (account, workspace, project, thread) in variants {
            let other = try fixture.access(account: account, workspace: workspace, project: project, thread: thread)
            #expect(try fixture.retrieve(for: other).facts.isEmpty)
            _ = try fixture.commit("Other scope fact", for: other)
        }
        let returnedA = try fixture.access()
        #expect(returnedA.conversation.memoryKey == firstA.conversation.memoryKey)
        #expect(try fixture.retrieve(for: returnedA).facts.map(\.id) == [a.id])
    }

    @Test
    func observedAndDraftProvenanceCannotLaunderSourcePermissions() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        fixture.policy.captureGrants = [.init(id: UUID(), scope: fixture.scope, categories: [.sessionMemory], window: fixture.window)]
        let selected = fixture.write("Observed text", provenance: .observedSource(snapshotID: UUID(), category: .selectedText))
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try fixture.store.beginWrite(selected, for: access)
        }
        let draft = fixture.write("Draft from screen", provenance: .chosenDraft(draftID: UUID(), selection: .inserted, derivedFrom: [.screenText]))
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try fixture.store.beginWrite(draft, for: access)
        }
        let mislabeled = fixture.write("Old memory", provenance: .observedSource(snapshotID: UUID(), category: .persistentMemory))
        #expect(throws: ScribeSessionMemoryError.invalidRecord) {
            try fixture.store.beginWrite(mislabeled, for: access)
        }
    }

    @Test
    func failedCancelledAndReplayedWritesCannotCreateFacts() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        for outcome in [ScribeSessionMemoryActionOutcome.failed, .cancelled] {
            let token = try fixture.store.beginWrite(fixture.write("Must not become a fact"), for: access)
            #expect(try fixture.store.completeWrite(token, outcome: outcome, for: access) == nil)
            #expect(throws: ScribeSessionMemoryError.unknownOperation) {
                try fixture.store.completeWrite(token, outcome: .completed, for: access)
            }
        }
        #expect(try fixture.retrieve(for: access).facts.isEmpty)
        let accepted = try fixture.store.beginWrite(fixture.write("Explicit fact"), for: access)
        _ = try fixture.store.completeWrite(accepted, outcome: .completed, for: access)
        #expect(throws: ScribeSessionMemoryError.unknownOperation) {
            try fixture.store.completeWrite(accepted, outcome: .completed, for: access)
        }
        #expect(try fixture.retrieve(for: access).facts.count == 1)
    }

    @Test
    func actionAndCaptureReplayCannotCompleteAnotherActionsPendingWork() throws {
        let fixture = MemoryFixture()
        let first = try fixture.access()
        let write = try fixture.store.beginWrite(fixture.write("Pending fact"), for: first)
        let read = try fixture.store.beginRetrieval(.init(topics: ["refund"]), for: first)
        let second = try fixture.access()
        #expect(throws: ScribeSessionMemoryError.actionBindingMismatch) {
            try fixture.store.completeWrite(write, outcome: .completed, for: second)
        }
        #expect(throws: ScribeSessionMemoryError.actionBindingMismatch) {
            try fixture.store.completeRetrieval(read, for: second)
        }
        let another = try fixture.store.beginWrite(fixture.write("Captured fact"), for: second)
        let changedCapture = ScribeSessionMemoryAccess(
            conversation: second.conversation, currentBinding: second.currentBinding,
            contextAction: .init(actionID: second.contextAction.actionID, captureID: UUID(), target: second.contextAction.target,
                                 opaqueSurfaceID: second.contextAction.opaqueSurfaceID, eligibility: .eligible)
        )
        #expect(throws: ScribeSessionMemoryError.actionBindingMismatch) {
            try fixture.store.completeWrite(another, outcome: .completed, for: changedCapture)
        }
    }

    @Test
    func staleProcessTabAndForgedPolicyScopeCannotSupplyMemoryAuthority() throws {
        let fixture = MemoryFixture()
        let original = try fixture.access()
        let wrongScope = ScribeSessionMemoryAccess(
            conversation: original.conversation, currentBinding: original.currentBinding,
            contextAction: .init(actionID: original.contextAction.actionID, captureID: original.contextAction.captureID,
                                 target: original.contextAction.target, opaqueSurfaceID: "some-other-thread", eligibility: .eligible)
        )
        #expect(throws: ScribeSessionMemoryError.actionBindingMismatch) {
            try fixture.store.beginWrite(fixture.write("Fact"), for: wrongScope)
        }
        let pending = try fixture.store.beginWrite(fixture.write("Stale process fact"), for: original)
        fixture.adapter.currentBinding = .init(
            actionID: original.currentBinding.actionID,
            process: .init(processIdentifier: original.currentBinding.process.processIdentifier,
                           bundleIdentifier: MemoryFixture.bundleID,
                           bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"), incarnation: UUID()),
            windowIncarnation: original.currentBinding.windowIncarnation, tabIncarnation: UUID(),
            navigationRevision: original.currentBinding.navigationRevision
        )
        #expect(throws: ScribeSessionMemoryError.identityChanged) {
            try fixture.store.completeWrite(pending, outcome: .completed, for: original)
        }
    }

    @Test
    func explicitCorrectionSupersedesFactAndPreservesSourceLineage() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let first = try fixture.commit("Refund expected Tuesday.",
                                       provenance: .observedSource(snapshotID: UUID(), category: .selectedText), for: access)
        var correction = fixture.write("Correction: refund expected Thursday.")
        correction.supersedesRecordID = first.id
        let token = try fixture.store.beginWrite(correction, for: access)
        let corrected = try #require(try fixture.store.completeWrite(token, outcome: .completed, for: access))
        let result = try fixture.retrieve(for: access)
        #expect(result.facts.map(\.id) == [corrected.id])
        #expect(result.supersededLineage.map(\.id) == [first.id])
        #expect(result.dataCategories.contains(.selectedText))
        #expect(corrected.supersedesRecordID == first.id)
    }

    @Test
    func expiringCorrectionCannotReviveAnOlderFact() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let first = try fixture.commit("Obsolete Tuesday fact.", for: access)
        var correction = fixture.write("Correct Thursday fact.", expiresAt: fixture.now + 30)
        correction.supersedesRecordID = first.id
        let token = try fixture.store.beginWrite(correction, for: access)
        _ = try fixture.store.completeWrite(token, outcome: .completed, for: access)
        fixture.now += 31
        let result = try fixture.retrieve(for: access)
        #expect(result.facts.isEmpty)
        #expect(result.supersededLineage.isEmpty)
    }

    @Test
    func correctionRequiresExplicitUserAndSameScopeAndRejectsLateCompetingCorrection() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let first = try fixture.commit("Initial fact", for: access)
        var invalid = fixture.write("An observed correction", provenance: .observedSource(snapshotID: UUID(), category: .selectedText))
        invalid.supersedesRecordID = first.id
        #expect(throws: ScribeSessionMemoryError.invalidCorrection) {
            try fixture.store.beginWrite(invalid, for: access)
        }
        var correction = fixture.write("User correction")
        correction.supersedesRecordID = first.id
        let firstToken = try fixture.store.beginWrite(correction, for: access)
        let lateToken = try fixture.store.beginWrite(correction, for: access)
        _ = try fixture.store.completeWrite(firstToken, outcome: .completed, for: access)
        #expect(throws: ScribeSessionMemoryError.invalidCorrection) {
            try fixture.store.completeWrite(lateToken, outcome: .completed, for: access)
        }
        let other = try fixture.access(thread: "thread-b")
        #expect(throws: ScribeSessionMemoryError.invalidCorrection) {
            try fixture.store.beginWrite(correction, for: other)
        }
    }

    @Test
    func inactivityExpiresAtThirtyMinutesAndSuccessfulRetrievalRefreshesActivity() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        _ = try fixture.commit("Longer-authorized fact", for: access)
        fixture.now += 1_799
        #expect(try fixture.retrieve(for: access).facts.count == 1)
        fixture.now += 1_800
        #expect(try fixture.retrieve(for: access).facts.isEmpty)
    }

    @Test
    func recordExpiryAndPermissionLossRemoveOtherwiseActiveRecords() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let write = fixture.write("Short-lived fact", expiresAt: fixture.now + 20)
        let token = try fixture.store.beginWrite(write, for: access)
        _ = try fixture.store.completeWrite(token, outcome: .completed, for: access)
        fixture.now += 20
        #expect(try fixture.retrieve(for: access).facts.isEmpty)
        _ = try fixture.commit("Selected text fact", provenance: .observedSource(snapshotID: UUID(), category: .selectedText), for: access)
        fixture.permissions.accessibility = false
        #expect(try fixture.retrieve(for: access).facts.isEmpty)
    }

    @Test
    func grantRevocationInvalidatesPendingWritesRetrievalsAndIssuedReadLeases() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        _ = try fixture.commit("Stored fact", for: access)
        let result = try fixture.retrieve(for: access)
        let write = try fixture.store.beginWrite(fixture.write("Pending fact"), for: access)
        let read = try fixture.store.beginRetrieval(.init(topics: ["refund"]), for: access)
        fixture.policy.revokedGrantIDs.insert(fixture.policy.captureGrants[0].id)
        #expect(throws: ScribeSessionMemoryError.unknownOperation) {
            try fixture.store.completeWrite(write, outcome: .completed, for: access)
        }
        #expect(throws: ScribeSessionMemoryError.unknownOperation) {
            try fixture.store.completeRetrieval(read, for: access)
        }
        #expect(throws: ScribeSessionMemoryError.staleRetrieval) {
            try fixture.store.revalidateRetrieval(result, for: access)
        }
        fixture.policy.revokedGrantIDs = []
        #expect(try fixture.retrieve(for: access).facts.isEmpty)
    }

    @Test
    func forgettingScopeInvalidatesAllItsCallbacksAndPreservesAnotherScope() throws {
        let fixture = MemoryFixture()
        let b = try fixture.access(thread: "thread-b")
        let retainedB = try fixture.commit("B fact", for: b)
        let a = try fixture.access()
        _ = try fixture.commit("A fact", for: a)
        let result = try fixture.retrieve(for: a)
        let write = try fixture.store.beginWrite(fixture.write("Late A fact"), for: a)
        let read = try fixture.store.beginRetrieval(.init(topics: ["refund"]), for: a)
        fixture.store.forget(scopeKey: a.conversation.memoryKey)
        #expect(throws: ScribeSessionMemoryError.unknownOperation) {
            try fixture.store.completeWrite(write, outcome: .completed, for: a)
        }
        #expect(throws: ScribeSessionMemoryError.unknownOperation) {
            try fixture.store.completeRetrieval(read, for: a)
        }
        #expect(throws: ScribeSessionMemoryError.staleRetrieval) {
            try fixture.store.revalidateRetrieval(result, for: a)
        }
        #expect(try fixture.retrieve(for: a).facts.isEmpty)
        let returnedB = try fixture.access(thread: "thread-b")
        #expect(try fixture.retrieve(for: returnedB).facts.map(\.id) == [retainedB.id])
    }

    @Test
    func clearCancelAndEndSessionInvalidateOutstandingWork() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let cancelled = try fixture.store.beginWrite(fixture.write("Cancelled"), for: access)
        fixture.store.cancel(actionID: access.contextAction.actionID)
        #expect(throws: ScribeSessionMemoryError.unknownOperation) {
            try fixture.store.completeWrite(cancelled, outcome: .completed, for: access)
        }
        _ = try fixture.commit("Confirmed", for: access)
        let result = try fixture.retrieve(for: access)
        fixture.store.clear()
        #expect(throws: ScribeSessionMemoryError.staleRetrieval) {
            try fixture.store.revalidateRetrieval(result, for: access)
        }
        #expect(try fixture.retrieve(for: access).facts.isEmpty)
        fixture.store.endSession()
        #expect(throws: ScribeSessionMemoryError.revoked) {
            try fixture.store.beginWrite(fixture.write("Cannot reopen"), for: access)
        }
    }

    @Test
    func relevanceAndRetrievalLimitsAvoidWholeHistoryAndPartialUTF8Content() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        _ = try fixture.commit("Refund fact", for: access)
        let other = fixture.write("Unrelated release detail", topics: ["release"])
        let otherToken = try fixture.store.beginWrite(other, for: access)
        _ = try fixture.store.completeWrite(otherToken, outcome: .completed, for: access)
        #expect(try fixture.retrieve(.init(topics: ["missing-topic"]), for: access).facts.isEmpty)
        #expect(try fixture.retrieve(for: access).facts.count == 1)
        #expect(try fixture.retrieve(.init(topics: ["refund"], maximumRecords: 1, maximumUTF8Bytes: 3), for: access).facts.isEmpty)
        #expect(throws: ScribeSessionMemoryError.invalidQuery) {
            try fixture.store.beginRetrieval(.init(topics: []), for: access)
        }
        #expect(throws: ScribeSessionMemoryError.invalidQuery) {
            try fixture.store.beginRetrieval(.init(topics: ["refund"], maximumRecords: 100), for: access)
        }
    }

    @Test
    func scopeRecordByteAndPendingLimitsRejectGrowthWithoutEvictingFacts() throws {
        var limits = ScribeSessionMemoryLimits()
        limits.maximumScopes = 1
        limits.maximumRecordsPerScope = 1
        limits.maximumRecordUTF8Bytes = 8
        limits.maximumPendingOperations = 2
        let fixture = MemoryFixture(limits: limits)
        let access = try fixture.access()
        #expect(throws: ScribeSessionMemoryError.invalidRecord) {
            try fixture.store.beginWrite(fixture.write("🙂🙂🙂"), for: access)
        }
        let first = try fixture.store.beginWrite(fixture.write("Fact"), for: access)
        let second = try fixture.store.beginWrite(fixture.write("Other"), for: access)
        #expect(throws: ScribeSessionMemoryError.capacityExceeded) {
            try fixture.store.beginWrite(fixture.write("Third"), for: access)
        }
        _ = try fixture.store.completeWrite(first, outcome: .completed, for: access)
        #expect(throws: ScribeSessionMemoryError.capacityExceeded) {
            try fixture.store.completeWrite(second, outcome: .completed, for: access)
        }
        let result = try fixture.retrieve(for: access)
        #expect(result.facts.map(\.text) == ["Fact"])
        fixture.store.releaseRetrieval(result)
        let otherScope = try fixture.access(thread: "thread-b")
        let pendingOther = try fixture.store.beginWrite(fixture.write("B fact"), for: otherScope)
        #expect(throws: ScribeSessionMemoryError.capacityExceeded) {
            try fixture.store.completeWrite(pendingOther, outcome: .completed, for: otherScope)
        }
    }

    @Test
    func resultLeasesExpireAndCorrectionsInvalidateAlreadyReturnedFacts() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let first = try fixture.commit("Earlier fact", for: access)
        let result = try fixture.retrieve(for: access)
        try fixture.store.revalidateRetrieval(result, for: access)
        var correction = fixture.write("Corrected fact")
        correction.supersedesRecordID = first.id
        let token = try fixture.store.beginWrite(correction, for: access)
        _ = try fixture.store.completeWrite(token, outcome: .completed, for: access)
        #expect(throws: ScribeSessionMemoryError.staleRetrieval) {
            try fixture.store.revalidateRetrieval(result, for: access)
        }
        let current = try fixture.retrieve(for: access)
        fixture.now += 60
        #expect(throws: ScribeSessionMemoryError.staleRetrieval) {
            try fixture.store.revalidateRetrieval(current, for: access)
        }
    }

    @Test
    func backwardOrInvalidClockFailsClosedAndCannotExtendMemoryLifetime() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        _ = try fixture.commit("Stored fact", for: access)
        fixture.now -= 1
        #expect(throws: ScribeSessionMemoryError.invalidClock) {
            try fixture.store.purgeExpiredAndRevoked()
        }
        #expect(try fixture.retrieve(for: access).facts.isEmpty)
        fixture.now = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(throws: ScribeSessionMemoryError.invalidClock) {
            try fixture.store.purgeExpiredAndRevoked()
        }
    }

    @Test
    func CodableProjectionPreservesAttributedRecordWithoutRestoringStore() throws {
        let fixture = MemoryFixture()
        let access = try fixture.access()
        let record = try fixture.commit("Chosen claim is not proven", provenance: .chosenDraft(draftID: UUID(), selection: .inserted, derivedFrom: [.screenText]), for: access)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ScribeSessionMemoryRecord.self, from: data) == record)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["scopeKey"] = "thread title"
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ScribeSessionMemoryRecord.self, from: invalid)
        }
    }
}

@MainActor
private final class MemoryFixture {
    static let bundleID = "com.example.MemoryFixture"
    var now = Date(timeIntervalSince1970: 50_000)
    var policy = ScribeContextPolicySnapshot()
    var permissions = ScribeContextPlatformPermissions(accessibility: true, screenRecording: true)
    let limits: ScribeSessionMemoryLimits
    let adapter = SessionMemoryFixtureAdapter()
    lazy var resolver = try! ScribeConversationIdentityResolver(adapters: [adapter])
    lazy var store = ScribeSessionMemoryStore(
        identityResolver: resolver, actionIsCurrent: { _ in true },
        policy: { [unowned self] in self.policy },
        permissions: { [unowned self] in self.permissions }, clock: { [unowned self] in self.now }, limits: limits
    )
    var scope: ScribeContextAccessScope { .application(bundleIdentifier: Self.bundleID) }
    var window: ScribeContextGrantWindow { .init(acceptedAt: Date(timeIntervalSince1970: 49_000), expiresAt: Date(timeIntervalSince1970: 90_000)) }

    init(limits: ScribeSessionMemoryLimits = .init()) {
        self.limits = limits
        policy.isEnabled = true
        policy.captureGrants = [.init(id: UUID(), scope: scope, categories: Set(ScribeContextCaptureCategory.allCases), window: window)]
        policy.retentionGrants = [.init(id: UUID(), scope: scope, categories: Set(ScribeContextDataCategory.allCases),
                                        destination: .sessionMemory, maximumRetentionInterval: 20_000, window: window)]
    }

    func access(account: String = "account-a", workspace: String = "workspace-a", project: String = "project-a", thread: String = "thread-a") throws -> ScribeSessionMemoryAccess {
        adapter.account = account
        adapter.workspace = workspace
        adapter.project = project
        adapter.thread = thread
        let binding = ScribeConversationActionBinding(
            actionID: UUID(), process: adapter.process, windowIncarnation: adapter.window,
            tabIncarnation: adapter.tab, navigationRevision: UUID()
        )
        adapter.currentBinding = binding
        guard case let .verified(identity) = resolver.resolve(adapterID: adapter.registration.adapterID, for: binding) else {
            throw ScribeSessionMemoryError.identityChanged
        }
        return .init(conversation: identity, currentBinding: binding,
                     contextAction: .init(actionID: binding.actionID, captureID: UUID(),
                                          target: .init(processIdentifier: binding.process.processIdentifier, bundleIdentifier: Self.bundleID),
                                          opaqueSurfaceID: identity.memoryKey.opaqueValue, eligibility: .eligible))
    }

    func write(_ text: String, provenance: ScribeSessionMemoryProvenance = .explicitUser(statementID: UUID()),
               topics: Set<String> = ["refund"], expiresAt: Date? = nil) -> ScribeSessionMemoryWrite {
        .init(text: text, topics: topics, provenance: provenance, expiresAt: expiresAt ?? now + 7_200)
    }

    func commit(_ text: String, provenance: ScribeSessionMemoryProvenance = .explicitUser(statementID: UUID()),
                for access: ScribeSessionMemoryAccess) throws -> ScribeSessionMemoryRecord {
        let token = try store.beginWrite(write(text, provenance: provenance), for: access)
        return try #require(try store.completeWrite(token, outcome: .completed, for: access))
    }

    func retrieve(_ query: ScribeSessionMemoryQuery = .init(topics: ["refund"]),
                  for access: ScribeSessionMemoryAccess) throws -> ScribeSessionMemoryRetrieval {
        let token = try store.beginRetrieval(query, for: access)
        return try store.completeRetrieval(token, for: access)
    }
}

@MainActor
private final class SessionMemoryFixtureAdapter: ScribeConversationIdentityAdapter {
    let registration = ScribeConversationAdapterRegistration(
        adapterID: .init(rawValue: "session-memory-fixture")!, schemaVersion: 1, source: .browserIntegration,
        hostBundleIdentifier: MemoryFixture.bundleID, applicationID: .init(rawValue: "fixture-support")!
    )
    let process = ApplicationProcessIdentity(processIdentifier: 77, bundleIdentifier: MemoryFixture.bundleID,
                                             bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"), incarnation: UUID())
    let window = UUID()
    let tab = UUID()
    var currentBinding: ScribeConversationActionBinding?
    var account = "account-a"
    var workspace = "workspace-a"
    var project = "project-a"
    var thread = "thread-a"

    func evidence(for binding: ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence? {
        guard let currentBinding else { return nil }
        return .init(adapterID: registration.adapterID, schemaVersion: 1, source: .browserIntegration,
                     binding: currentBinding, confidence: .verifiedStableIdentifiers, privacyState: .regular,
                     applicationID: registration.applicationID, accountID: .init(rawValue: account),
                     workspaceID: .identified(.init(rawValue: workspace)!), projectID: .identified(.init(rawValue: project)!),
                     conversationID: .init(rawValue: thread))
    }
}
