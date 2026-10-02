import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribePersistentMemoryStoreTests {
    @Test
    func maintenanceActivationPurgesExpiredCiphertextAndInvalidatesPendingWork() async throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        try fixture.save(fixture.record("Expires during idle time.", for: access, expiresAt: fixture.now + 5), using: store, for: access)
        let read = try store.read(for: access)
        let pending = try store.beginSave(fixture.record("Pending save.", for: access), for: access)
        let before = try Data(contentsOf: fixture.url)
        var notifications = 0
        let maintenance = ScribePersistentMemoryMaintenance(store: store,
            isAuthorized: { fixture.policy.isEnabled }, onInvalidated: { notifications += 1 })
        fixture.now += 10
        maintenance.start()
        #expect(notifications == 1)
        #expect(try Data(contentsOf: fixture.url) != before)
        #expect(try fixture.makeStore().read(for: access).records.isEmpty)
        #expect(throws: ScribePersistentMemoryError.staleToken) { try store.revalidateRead(read, for: access) }
        #expect(throws: ScribePersistentMemoryError.staleToken) {
            try store.completeSave(pending, decision: .confirmedByUser, for: access)
        }
        let stopped = maintenance.stop()
        await stopped?.value
        #expect(!maintenance.isRunning)
    }

    @Test
    func domainOwnerReopensEncryptedRecordWithStableKeyButDoesNotGrantRetention() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let directory = URL(fileURLWithPath: fixture.directory.path, isDirectory: true)
        let owner = try ScribePersistentMemoryDomainStore(directoryURL: directory, applicationBundleIdentifier: PersistentMemoryFixture.bundleID)
        let domain = try owner.create(authority: .confirmedByUser)
        let backend = DomainKeyBackend()
        let keyStore = try owner.makeKeyStore(for: domain, backend: backend)
        _ = try keyStore.provision(authority: .confirmedByUser)
        let store = ScribePersistentMemoryStore(url: domain.storeURL, keyProvider: keyStore,
            identityResolver: fixture.resolver, policy: { fixture.policy },
            permissions: { fixture.permissions }, clock: { fixture.now })
        let access = try fixture.access()
        let record = fixture.record("Synthetic project uses SwiftUI.", for: access)
        try fixture.save(record, using: store, for: access)
        let bytes = try Data(contentsOf: domain.storeURL)
        #expect(bytes.range(of: Data(record.text.utf8)) == nil)
        let namespaceBytes = try Data(contentsOf: owner.namespaceURL)
        #expect(namespaceBytes.range(of: Data(record.text.utf8)) == nil)
        let reopenedOwner = try ScribePersistentMemoryDomainStore(directoryURL: directory, applicationBundleIdentifier: PersistentMemoryFixture.bundleID)
        let reopenedDomain = try #require(try reopenedOwner.load())
        #expect(reopenedDomain == domain)
        #expect(try reopenedOwner.create(authority: .confirmedByUser) == domain)
        let reopenedKeys = try reopenedOwner.makeKeyStore(for: reopenedDomain, backend: backend)
        let reopenedStore = ScribePersistentMemoryStore(url: reopenedDomain.storeURL, keyProvider: reopenedKeys,
            identityResolver: fixture.resolver, policy: { fixture.policy },
            permissions: { fixture.permissions }, clock: { fixture.now })
        #expect(try reopenedStore.read(for: access).records == [record])
        #expect(try Data(contentsOf: domain.storeURL) == bytes)
        #expect(try Data(contentsOf: owner.namespaceURL) == namespaceBytes)
        fixture.policy.isEnabled = false
        let callsBeforeDeniedRead = backend.calls
        #expect(throws: ScribeContextPolicyRejection.disabled) { try reopenedStore.read(for: access) }
        #expect(backend.calls == callsBeforeDeniedRead)
        #expect(try Data(contentsOf: domain.storeURL) == bytes)
    }

    @Test
    func defaultPolicyDeniesBeforeDiskAccessAndProposalRequiresExplicitConfirmation() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let files = PersistentMemoryTestFiles()
        let disabled = ScribePersistentMemoryStore(url: fixture.url, keyProvider: fixture.key, identityResolver: fixture.resolver,
                                                    clock: { fixture.now }, fileAccess: files)
        #expect(throws: ScribeContextPolicyRejection.disabled) { try disabled.beginSave(fixture.record(for: access), for: access) }
        #expect(throws: ScribeContextPolicyRejection.disabled) { try disabled.read(for: access) }
        #expect(files.readCount == 0 && files.writeCount == 0)
        let store = fixture.makeStore()
        let proposal = try store.beginSave(fixture.record(for: access), for: access)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(throws: ScribePersistentMemoryError.unconfirmed) { try store.completeSave(proposal, decision: .notConfirmed, for: access) }
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(throws: ScribePersistentMemoryError.staleToken) { try store.completeSave(proposal, decision: .confirmedByUser, for: access) }
    }

    @Test
    func confirmedRecordSurvivesRestartWithProvenanceAndEncryptedContent() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let record = fixture.record("SYNTHETIC-CANARY: payment is only a draft claim.", for: access,
                                    provenance: .chosenDraft(draftID: UUID(), selection: .copied, derivedFrom: [.screenText]))
        try fixture.save(record, using: fixture.makeStore(), for: access)
        let bytes = try Data(contentsOf: fixture.url)
        #expect(bytes.range(of: Data(record.text.utf8)) == nil)
        #expect(bytes.range(of: Data(record.scopeKey.opaqueValue.utf8)) == nil)
        let reopened = fixture.makeStore()
        let result = try reopened.read(for: access)
        #expect(result.records == [record])
        #expect(result.records.first?.kind == .chosenDraft)
        #expect(result.dataCategories == [.persistentMemory, .sessionMemory, .priorDraft, .screenText])
        try reopened.revalidateRead(result, for: access)
    }

    @Test
    func accountThreadWorkspaceAndProjectRemainIsolatedAcrossRestart() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let a = try fixture.access()
        let original = fixture.record(for: a)
        try fixture.save(original, using: fixture.makeStore(), for: a)
        for (account, workspace, project, thread) in [
            ("b", "a", "a", "a"), ("a", "b", "a", "a"), ("a", "a", "b", "a"), ("a", "a", "a", "b")
        ] {
            let other = try fixture.access(account: account, workspace: workspace, project: project, thread: thread)
            let store = fixture.makeStore()
            #expect(try store.read(for: other).records.isEmpty)
            #expect(throws: ScribePersistentMemoryError.scopeMismatch) { try store.beginSave(original, for: other) }
        }
        let returned = try fixture.access()
        #expect(try fixture.makeStore().read(for: returned).records == [original])
    }

    @Test
    func forgetPersistsAcrossRestartAndPreservesOtherScope() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let store = fixture.makeStore()
        let a = try fixture.access()
        try fixture.save(fixture.record("A", for: a), using: store, for: a)
        let b = try fixture.access(thread: "b")
        let bRecord = fixture.record("B", for: b)
        try fixture.save(bRecord, using: store, for: b)
        try store.forget(scopeKey: a.conversation.memoryKey)
        let reopened = fixture.makeStore()
        #expect(try reopened.read(for: b).records == [bRecord])
        let returnedA = try fixture.access()
        #expect(try reopened.read(for: returnedA).records.isEmpty)
        try reopened.forgetAll()
        let returnedB = try fixture.access(thread: "b")
        #expect(try fixture.makeStore().read(for: returnedB).records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test
    func forgetInvalidatesPendingSaveAndReadAcrossStoreInstances() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let first = fixture.makeStore()
        try fixture.save(fixture.record(for: access), using: first, for: access)
        let second = fixture.makeStore()
        let read = try second.read(for: access)
        let pending = try second.beginSave(fixture.record("Late callback", for: access), for: access)
        try first.forget(scopeKey: access.conversation.memoryKey)
        #expect(throws: ScribePersistentMemoryError.staleToken) { try second.revalidateRead(read, for: access) }
        #expect(throws: ScribePersistentMemoryError.staleToken) { try second.completeSave(pending, decision: .confirmedByUser, for: access) }
        #expect(try fixture.makeStore().read(for: access).records.isEmpty)
    }

    @Test
    func reviewedForgetRejectsInterveningSaveAndPreservesNewFact() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        let original = fixture.record("Original", for: access)
        try fixture.save(original, using: store, for: access)
        let review = try store.read(for: access)
        let intervening = fixture.record("New after review", for: access)
        try fixture.save(intervening, using: store, for: access)

        #expect(throws: ScribePersistentMemoryError.staleToken) {
            try store.forget(scopeKey: access.conversation.memoryKey, expectedRevision: review.token)
        }
        #expect(try fixture.makeStore().read(for: access).records.count == 2)

        let current = try store.read(for: access)
        try store.forget(scopeKey: access.conversation.memoryKey, expectedRevision: current.token)
        #expect(try fixture.makeStore().read(for: access).records.isEmpty)
    }

    @Test
    func concurrentProposalsAndReopenedIncarnationsCannotReplay() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let first = fixture.makeStore()
        try fixture.save(fixture.record("Seed", for: access), using: first, for: access)
        let second = fixture.makeStore()
        let firstProposal = try first.beginSave(fixture.record("First", for: access), for: access)
        let secondProposal = try second.beginSave(fixture.record("Second", for: access), for: access)
        #expect(throws: ScribePersistentMemoryError.staleToken) { try fixture.makeStore().completeSave(firstProposal, decision: .confirmedByUser, for: access) }
        try first.completeSave(firstProposal, decision: .confirmedByUser, for: access)
        #expect(throws: ScribePersistentMemoryError.staleToken) { try second.completeSave(secondProposal, decision: .confirmedByUser, for: access) }
        #expect(Set(try fixture.makeStore().read(for: access).records.map(\.text)) == ["Seed", "First"])
    }

    @Test
    func changedProposalActionCaptureAndProcessAreRejected() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        let pending = try store.beginSave(fixture.record(for: access), for: access)
        let changed = ScribePersistentMemorySaveProposal(token: pending.token, record: fixture.record("Tampered", for: access))
        #expect(throws: ScribePersistentMemoryError.staleToken) { try store.completeSave(changed, decision: .confirmedByUser, for: access) }
        let secondPending = try store.beginSave(fixture.record(for: access), for: access)
        let recapture = ScribeSessionMemoryAccess(conversation: access.conversation, currentBinding: access.currentBinding,
            contextAction: .init(actionID: access.contextAction.actionID, captureID: UUID(), target: access.contextAction.target,
                                 opaqueSurfaceID: access.contextAction.opaqueSurfaceID, eligibility: .eligible))
        #expect(throws: ScribePersistentMemoryError.staleToken) { try store.completeSave(secondPending, decision: .confirmedByUser, for: recapture) }
        let thirdPending = try store.beginSave(fixture.record(for: access), for: access)
        fixture.adapter.currentBinding = nil
        #expect(throws: ScribePersistentMemoryError.identityChanged) { try store.completeSave(thirdPending, decision: .confirmedByUser, for: access) }
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test
    func revokedGrantsAndSourcePermissionLossDenySaveAndRead() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        let record = fixture.record(for: access, provenance: .observedSource(snapshotID: UUID(), category: .selectedText))
        try fixture.save(record, using: store, for: access)
        let read = try store.read(for: access)
        let pending = try store.beginSave(fixture.record("Pending", for: access), for: access)
        fixture.policy.revision = UUID()
        #expect(throws: ScribeContextPolicyRejection.policyChanged) { try store.revalidateRead(read, for: access) }
        #expect(throws: ScribeContextPolicyRejection.policyChanged) { try store.completeSave(pending, decision: .confirmedByUser, for: access) }
        fixture.permissions.accessibility = false
        #expect(throws: ScribeContextPolicyRejection.missingPlatformPermission) { try store.read(for: access) }
        fixture.permissions.accessibility = true
        fixture.policy.captureGrants[0] = .init(id: UUID(), scope: fixture.scope, categories: [.persistentMemory], window: fixture.window)
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) { try store.read(for: access) }
    }

    @Test
    func correctionPreservesLineageAndExpiredCorrectionCannotReviveOldFact() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        let old = fixture.record("Tuesday", for: access)
        try fixture.save(old, using: store, for: access)
        let correction = fixture.record("Thursday", for: access, expiresAt: fixture.now + 30, supersedes: old.id)
        try fixture.save(correction, using: store, for: access)
        let corrected = try store.read(for: access)
        #expect(corrected.records == [correction] && corrected.supersededLineage == [old])
        fixture.now += 30
        let expired = try fixture.makeStore().read(for: access)
        #expect(expired.records.isEmpty && expired.supersededLineage == [old])
        try fixture.save(fixture.record("Unrelated", for: access), using: store, for: access)
        #expect(try fixture.makeStore().read(for: access).records.map(\.text) == ["Unrelated"])
    }

    @Test
    func duplicateIDsAndInvalidCorrectionsPreserveExistingBytes() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        let old = fixture.record(for: access)
        try fixture.save(old, using: store, for: access)
        let bytes = try Data(contentsOf: fixture.url)
        #expect(throws: ScribePersistentMemoryError.recordConflict) { try store.beginSave(fixture.record("Overwrite", for: access, id: old.id), for: access) }
        #expect(throws: ScribePersistentMemoryError.invalidCorrection) { try store.beginSave(fixture.record(for: access, supersedes: UUID()), for: access) }
        let observed = fixture.record(for: access, provenance: .observedSource(snapshotID: UUID(), category: .selectedText), supersedes: old.id)
        #expect(throws: ScribePersistentMemoryError.invalidCorrection) { try store.beginSave(observed, for: access) }
        let other = try fixture.access(thread: "b")
        #expect(throws: ScribePersistentMemoryError.invalidCorrection) { try store.beginSave(fixture.record(for: other, supersedes: old.id), for: other) }
        #expect(try Data(contentsOf: fixture.url) == bytes)
    }

    @Test
    func malformedRecordsFailBeforeReplacingValidData() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        try fixture.save(fixture.record(for: access), using: store, for: access)
        let bytes = try Data(contentsOf: fixture.url)
        let invalid = [fixture.record(" ", for: access), fixture.record(String(repeating: "🙂", count: 1_025), for: access),
                       fixture.record(for: access, topics: []), fixture.record(for: access, topics: ["raw title with spaces"]),
                       fixture.record(for: access, createdAt: fixture.now + 1), fixture.record(for: access, expiresAt: fixture.now),
                       fixture.record(for: access, createdAt: Date(timeIntervalSinceReferenceDate: .infinity)),
                       fixture.record(for: access, provenance: .observedSource(snapshotID: UUID(), category: .persistentMemory))]
        for record in invalid { #expect(throws: ScribePersistentMemoryError.invalidRecord) { try store.beginSave(record, for: access) } }
        #expect(try Data(contentsOf: fixture.url) == bytes)
    }

    @Test
    func corruptEnvelopeUnknownSchemasAndAuthenticationFailureNeverReplaceData() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        try fixture.save(fixture.record(for: access), using: store, for: access)
        let original = try Data(contentsOf: fixture.url)
        let envelope = try JSONDecoder().decode(ScribePersistentMemoryEnvelope.self, from: original)
        let badTag = try JSONEncoder().encode(ScribePersistentMemoryEnvelope(schemaVersion: 1, nonce: envelope.nonce, ciphertext: envelope.ciphertext, tag: Data(repeating: 0, count: 16)))
        let unknown = try JSONEncoder().encode(ScribePersistentMemoryEnvelope(schemaVersion: 99, nonce: envelope.nonce, ciphertext: envelope.ciphertext, tag: envelope.tag))
        let unknownInner = try fixture.rewriteManifest(original) { $0["schemaVersion"] = 99 }
        for corrupt in [Data("not json".utf8), badTag, unknown, unknownInner] {
            try corrupt.write(to: fixture.url, options: .atomic)
            let reopened = fixture.makeStore()
            #expect(throws: (any Error).self) { try reopened.read(for: access) }
            #expect(throws: (any Error).self) { try reopened.beginSave(fixture.record(for: access), for: access) }
            #expect(throws: (any Error).self) { try reopened.forget(scopeKey: access.conversation.memoryKey) }
            #expect(try Data(contentsOf: fixture.url) == corrupt)
        }
    }

    @Test
    func authenticatedInvalidManifestIsNotSilentlyAcceptedOrOverwritten() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        try fixture.save(fixture.record(for: access), using: fixture.makeStore(), for: access)
        let original = try Data(contentsOf: fixture.url)
        let duplicate = try fixture.rewriteManifest(original) { object in
            let records = object["records"] as! [[String: Any]]
            object["records"] = records + records
        }
        try duplicate.write(to: fixture.url, options: .atomic)
        #expect(throws: ScribePersistentMemoryError.unreadable) { try fixture.makeStore().forgetAll() }
        #expect(try Data(contentsOf: fixture.url) == duplicate)
    }

    @Test
    func unavailableMalformedAndWrongKeysPreserveEncryptedBytes() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        try fixture.save(fixture.record(for: access), using: fixture.makeStore(), for: access)
        let bytes = try Data(contentsOf: fixture.url)
        for key in [PersistentMemoryTestKey(data: nil), .init(data: Data(repeating: 1, count: 31)), .init(data: Data(repeating: 1, count: 32))] {
            let store = fixture.makeStore(key: key)
            #expect(throws: (any Error).self) { try store.read(for: access) }
            #expect(throws: (any Error).self) { try store.forgetAll() }
            #expect(try Data(contentsOf: fixture.url) == bytes)
        }
    }

    @Test
    func failedAtomicSaveAndForgetPreservePreviousBytesAndThrow() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let files = PersistentMemoryTestFiles()
        let store = fixture.makeStore(files: files)
        try fixture.save(fixture.record("Original", for: access), using: store, for: access)
        let bytes = try Data(contentsOf: fixture.url)
        let pending = try store.beginSave(fixture.record("Interrupted", for: access), for: access)
        files.failWrite = true
        #expect(throws: ScribePersistentMemoryError.ioFailure) { try store.completeSave(pending, decision: .confirmedByUser, for: access) }
        #expect(throws: ScribePersistentMemoryError.ioFailure) { try store.forgetAll() }
        #expect(try Data(contentsOf: fixture.url) == bytes)
        #expect(try fixture.makeStore().read(for: access).records.map(\.text) == ["Original"])
    }

    @Test
    func recordPendingPlaintextAndFileBoundsFailWithoutEviction() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        var limits = ScribePersistentMemoryLimits()
        limits.maximumRecords = 1
        limits.maximumPendingOperations = 1
        let store = fixture.makeStore(limits: limits)
        let first = try store.beginSave(fixture.record("First", for: access), for: access)
        #expect(throws: ScribePersistentMemoryError.capacityExceeded) { try store.beginSave(fixture.record(for: access), for: access) }
        try store.completeSave(first, decision: .confirmedByUser, for: access)
        let original = try Data(contentsOf: fixture.url)
        let second = try store.beginSave(fixture.record("Second", for: access), for: access)
        #expect(throws: ScribePersistentMemoryError.capacityExceeded) { try store.completeSave(second, decision: .confirmedByUser, for: access) }
        #expect(try Data(contentsOf: fixture.url) == original)
        limits.maximumFileBytes = original.count - 1
        #expect(throws: ScribePersistentMemoryError.capacityExceeded) { try fixture.makeStore(limits: limits).read(for: access) }
        let fresh = PersistentMemoryFixture()
        defer { fresh.removeFiles() }
        let freshAccess = try fresh.access()
        limits = .init()
        limits.maximumPlaintextBytes = 10
        let tiny = fresh.makeStore(limits: limits)
        let tooLarge = try tiny.beginSave(fresh.record(for: freshAccess), for: freshAccess)
        #expect(throws: ScribePersistentMemoryError.capacityExceeded) { try tiny.completeSave(tooLarge, decision: .confirmedByUser, for: freshAccess) }
        #expect(!FileManager.default.fileExists(atPath: fresh.url.path))
    }

    @Test
    func expiryPendingDeadlinesClockRollbackAndExplicitInvalidationFailClosed() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        try fixture.save(fixture.record(for: access, expiresAt: fixture.now + 30), using: store, for: access)
        let read = try store.read(for: access)
        let pending = try store.beginSave(fixture.record("Late", for: access), for: access)
        fixture.now += 60
        #expect(throws: ScribePersistentMemoryError.staleToken) { try store.revalidateRead(read, for: access) }
        #expect(throws: ScribePersistentMemoryError.staleToken) { try store.completeSave(pending, decision: .confirmedByUser, for: access) }
        #expect(try fixture.makeStore().read(for: access).records.isEmpty)
        let current = try store.beginSave(fixture.record(for: access), for: access)
        store.invalidateOperations()
        #expect(throws: ScribePersistentMemoryError.staleToken) { try store.completeSave(current, decision: .confirmedByUser, for: access) }
        fixture.now -= 60
        #expect(throws: ScribePersistentMemoryError.invalidClock) { try store.read(for: access) }
        #expect(throws: ScribePersistentMemoryError.invalidClock) { try store.read(for: access) }
        #expect(throws: ScribePersistentMemoryError.invalidClock) { try store.read(for: access) }
        fixture.now += 60
        #expect(try store.read(for: access).records.isEmpty)
    }

    @Test
    func expiryHousekeepingDeletesDurablyAndInvalidatesOtherReadersAndCallbacks() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        try fixture.save(fixture.record("Expires", for: access, expiresAt: fixture.now + 10), using: store, for: access)
        let other = fixture.makeStore()
        let read = try other.read(for: access)
        let pending = try other.beginSave(fixture.record("Late", for: access), for: access)
        let before = try Data(contentsOf: fixture.url)
        fixture.now += 10
        #expect(try store.purgeExpired() == 1)
        #expect(try Data(contentsOf: fixture.url) != before)
        #expect(try fixture.makeStore().read(for: access).records.isEmpty)
        #expect(try store.purgeExpired() == 0)
        #expect(throws: ScribePersistentMemoryError.staleToken) { try other.revalidateRead(read, for: access) }
        #expect(throws: ScribePersistentMemoryError.staleToken) { try other.completeSave(pending, decision: .confirmedByUser, for: access) }
    }

    @Test
    func removalOfObservedFileAndRevisionExhaustionCannotResetDurableAuthority() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        let access = try fixture.access()
        let store = fixture.makeStore()
        try fixture.save(fixture.record(for: access), using: store, for: access)
        let bytes = try Data(contentsOf: fixture.url)
        let exhausted = try fixture.rewriteManifest(bytes) { $0["revision"] = NSNumber(value: UInt64.max) }
        try exhausted.write(to: fixture.url, options: .atomic)
        #expect(throws: ScribePersistentMemoryError.revisionExhausted) { try store.forgetAll() }
        #expect(try Data(contentsOf: fixture.url) == exhausted)
        try FileManager.default.removeItem(at: fixture.url)
        #expect(throws: ScribePersistentMemoryError.staleToken) { try store.beginSave(fixture.record(for: access), for: access) }
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test
    func independentFileLockFailsPromptlyWithoutRunningOperation() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(fixture.url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        var ran = false
        #expect(throws: ScribePersistentMemoryError.storeBusy) {
            try SystemScribePersistentMemoryFileAccess().withExclusiveLock(at: fixture.url) { ran = true }
        }
        #expect(!ran)
    }

    @Test
    func nonregularLockFileFailsPromptlyWithoutRunningOperation() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let lockURL = fixture.url.appendingPathExtension("lock")
        #expect(mkfifo(lockURL.path, S_IRUSR | S_IWUSR) == 0)
        var ran = false
        #expect(throws: ScribePersistentMemoryError.ioFailure) {
            try SystemScribePersistentMemoryFileAccess().withExclusiveLock(at: fixture.url) { ran = true }
        }
        #expect(!ran)
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
        #expect(throws: ScribePersistentMemoryError.ioFailure) {
            try SystemScribePersistentMemoryFileAccess().withExclusiveLock(at: fixture.url) { ran = true }
        }
        #expect(!ran)
    }

    @Test
    func descriptorReadRejectsOversizeSymlinksAndNonregularFiles() throws {
        let fixture = PersistentMemoryFixture()
        defer { fixture.removeFiles() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let files = SystemScribePersistentMemoryFileAccess()
        #expect(try files.read(at: fixture.url, maximumBytes: 10) == nil)
        try Data(repeating: 7, count: 11).write(to: fixture.url)
        #expect(throws: ScribePersistentMemoryError.capacityExceeded) { try files.read(at: fixture.url, maximumBytes: 10) }
        #expect(try files.read(at: fixture.url, maximumBytes: 11)?.count == 11)
        let link = fixture.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url)
        #expect(throws: ScribePersistentMemoryError.ioFailure) { try files.read(at: link, maximumBytes: 100) }
        #expect(throws: ScribePersistentMemoryError.ioFailure) { try files.read(at: fixture.directory, maximumBytes: 100) }
    }
}

private struct PersistentMemoryTestKey: ScribePersistentMemoryKeyProviding {
    let data: Data?
    func keyData() throws -> Data {
        guard let data else { throw ScribePersistentMemoryError.keyUnavailable }
        return data
    }
}

@MainActor
private final class PersistentMemoryTestFiles: ScribePersistentMemoryFileAccess {
    let system = SystemScribePersistentMemoryFileAccess()
    var failWrite = false
    var readCount = 0
    var writeCount = 0
    func withExclusiveLock<T>(at url: URL, _ operation: () throws -> T) throws -> T { try system.withExclusiveLock(at: url, operation) }
    func read(at url: URL, maximumBytes: Int) throws -> Data? {
        readCount += 1
        return try system.read(at: url, maximumBytes: maximumBytes)
    }
    func writeAtomically(_ data: Data, to url: URL) throws {
        writeCount += 1
        if failWrite { throw ScribePersistentMemoryError.ioFailure }
        try system.writeAtomically(data, to: url)
    }
}

@MainActor
private final class PersistentMemoryFixture {
    static let bundleID = "com.example.PersistentMemoryFixture"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Cadence-memory-test-" + UUID().uuidString)
    var url: URL { directory.appendingPathComponent("memory.json") }
    let key = PersistentMemoryTestKey(data: Data(repeating: 7, count: 32))
    var now = Date(timeIntervalSince1970: 50_000)
    var policy = ScribeContextPolicySnapshot()
    var permissions = ScribeContextPlatformPermissions(accessibility: true, screenRecording: true)
    let adapter = PersistentMemoryFixtureAdapter()
    lazy var resolver = try! ScribeConversationIdentityResolver(adapters: [adapter])
    var scope: ScribeContextAccessScope { .application(bundleIdentifier: Self.bundleID) }
    var window: ScribeContextGrantWindow { .init(acceptedAt: Date(timeIntervalSince1970: 49_000), expiresAt: Date(timeIntervalSince1970: 90_000)) }
    init() {
        policy.isEnabled = true
        policy.captureGrants = [.init(id: UUID(), scope: scope, categories: Set(ScribeContextCaptureCategory.allCases), window: window)]
        policy.retentionGrants = [.init(id: UUID(), scope: scope, categories: Set(ScribeContextDataCategory.allCases), destination: .persistentMemory,
                                        maximumRetentionInterval: 20_000, window: window)]
    }
    func removeFiles() { try? FileManager.default.removeItem(at: directory) }
    func makeStore(key: PersistentMemoryTestKey? = nil, files: (any ScribePersistentMemoryFileAccess)? = nil,
                   limits: ScribePersistentMemoryLimits = .init()) -> ScribePersistentMemoryStore {
        .init(url: url, keyProvider: key ?? self.key, identityResolver: resolver, policy: { [unowned self] in self.policy },
              permissions: { [unowned self] in self.permissions }, clock: { [unowned self] in self.now }, fileAccess: files, limits: limits)
    }
    func access(account: String = "a", workspace: String = "a", project: String = "a", thread: String = "a") throws -> ScribeSessionMemoryAccess {
        adapter.account = account
        adapter.workspace = workspace
        adapter.project = project
        adapter.thread = thread
        let binding = ScribeConversationActionBinding(actionID: UUID(), process: adapter.process, windowIncarnation: adapter.window,
                                                       tabIncarnation: adapter.tab, navigationRevision: UUID())
        adapter.currentBinding = binding
        guard case let .verified(identity) = resolver.resolve(adapterID: adapter.registration.adapterID, for: binding) else {
            throw ScribePersistentMemoryError.identityChanged
        }
        return .init(conversation: identity, currentBinding: binding, contextAction: .init(actionID: binding.actionID, captureID: UUID(),
            target: .init(processIdentifier: binding.process.processIdentifier, bundleIdentifier: Self.bundleID),
            opaqueSurfaceID: identity.memoryKey.opaqueValue, eligibility: .eligible))
    }
    func record(_ text: String = "Synthetic refund fact", for access: ScribeSessionMemoryAccess, id: UUID = UUID(),
                provenance: ScribeSessionMemoryProvenance = .explicitUser(statementID: UUID()), topics: Set<String> = ["refund"],
                createdAt: Date? = nil, expiresAt: Date? = nil, supersedes: UUID? = nil) -> ScribeSessionMemoryRecord {
        .init(id: id, scopeKey: access.conversation.memoryKey, text: text, topics: topics, provenance: provenance,
              origin: .init(actionID: access.contextAction.actionID, captureID: access.contextAction.captureID),
              createdAt: createdAt ?? now, expiresAt: expiresAt ?? now + 7_200, supersedesRecordID: supersedes)
    }
    func save(_ record: ScribeSessionMemoryRecord, using store: ScribePersistentMemoryStore, for access: ScribeSessionMemoryAccess) throws {
        let proposal = try store.beginSave(record, for: access)
        try store.completeSave(proposal, decision: .confirmedByUser, for: access)
    }
    func rewriteManifest(_ data: Data, mutate: (inout [String: Any]) -> Void) throws -> Data {
        let envelope = try JSONDecoder().decode(ScribePersistentMemoryEnvelope.self, from: data)
        let symmetricKey = SymmetricKey(data: try key.keyData())
        let header = Data("Cadence.Compose.PersistentMemory.v1".utf8)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce), ciphertext: envelope.ciphertext, tag: envelope.tag)
        let plaintext = try AES.GCM.open(box, using: symmetricKey, authenticating: header)
        var object = try #require(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        mutate(&object)
        let rewritten = try JSONSerialization.data(withJSONObject: object)
        let sealed = try AES.GCM.seal(rewritten, using: symmetricKey, authenticating: header)
        return try JSONEncoder().encode(ScribePersistentMemoryEnvelope(schemaVersion: 1, nonce: Data(sealed.nonce), ciphertext: sealed.ciphertext, tag: sealed.tag))
    }
}

@MainActor
private final class PersistentMemoryFixtureAdapter: ScribeConversationIdentityAdapter {
    let registration = ScribeConversationAdapterRegistration(adapterID: .init(rawValue: "persistent-memory-fixture")!, schemaVersion: 1,
        source: .browserIntegration, hostBundleIdentifier: PersistentMemoryFixture.bundleID, applicationID: .init(rawValue: "fixture-support")!)
    let process = ApplicationProcessIdentity(processIdentifier: 88, bundleIdentifier: PersistentMemoryFixture.bundleID,
        bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"), incarnation: UUID())
    let window = UUID()
    let tab = UUID()
    var currentBinding: ScribeConversationActionBinding?
    var account = "a"
    var workspace = "a"
    var project = "a"
    var thread = "a"
    func evidence(for binding: ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence? {
        guard let currentBinding else { return nil }
        return .init(adapterID: registration.adapterID, schemaVersion: 1, source: .browserIntegration, binding: currentBinding,
            confidence: .verifiedStableIdentifiers, privacyState: .regular, applicationID: registration.applicationID,
            accountID: .init(rawValue: account), workspaceID: .identified(.init(rawValue: workspace)!),
            projectID: .identified(.init(rawValue: project)!), conversationID: .init(rawValue: thread))
    }
}
