import Foundation
import OSLog

private let composePersistentMemoryRuntimeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposePersistentMemoryRuntime"
)

enum ComposePersistentMemoryRuntimeError: Error, Equatable {
    case unavailable, confirmationRequired, noCurrentAction, invalidFact
    case factNotFound, ambiguousFact
}

enum ComposePersistentMemoryActivationAuthority: Equatable {
    case notConfirmed, confirmedByUser
}

enum ComposePersistentMemoryDeletionAuthority: Equatable {
    case notConfirmed, confirmedByUser
}

@MainActor
protocol ComposePersistentMemoryContextServing: AnyObject {
    var acceptsExplicitSaves: Bool { get }
    var permitsLocalDraftUse: Bool { get }
    @discardableResult func begin(actionID: UUID, capture: ScribeContextSnapshot) -> Bool
    @discardableResult func rebindAction(
        from oldActionID: UUID, to newActionID: UUID,
        capture: ScribeContextSnapshot
    ) -> Bool
    func prepareSaveExplicitFact(
        _ text: String, actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> ScribePersistentMemorySaveProposal
    func prepareCorrection(
        oldFact: String, newFact: String, actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> (previous: ScribeSessionMemoryRecord, proposal: ScribePersistentMemorySaveProposal)
    func completeSave(
        _ proposal: ScribePersistentMemorySaveProposal,
        decision: ScribePersistentMemorySaveDecision,
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws
    func inspect(actionID: UUID, capture: ScribeContextSnapshot) throws -> [ScribeSessionMemoryRecord]
    func draftFacts(
        for spokenRequest: String, actionID: UUID, capture: ScribeContextSnapshot,
        destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryDraftFacts?
    func prepareForgetCurrentDocument(
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> ScribePersistentMemoryForgetProposal
    func confirmForgetCurrentDocument(
        _ proposal: ScribePersistentMemoryForgetProposal,
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws
    func clear(actionID: UUID?)
}

/// Explicit durable-memory lifecycle for one supported surface. AppModel
/// constructs it inertly and opens only an already authorized domain. The
/// caller must bind identity at invocation,
/// show the exact save proposal, and obtain a fresh confirmation for both
/// storage activation and each fact before calling the corresponding methods.
@MainActor
final class ComposePersistentMemoryRuntime: ComposePersistentMemoryContextServing {
    private let consent: ComposePersistentMemoryConsentController
    private let domainStore: ScribePersistentMemoryDomainStore
    private let scope: ScribeConversationActionScope
    private let securityBackend: any ScribePersistentMemorySecurityBackend
    private let permissions: @MainActor () -> ScribeContextPlatformPermissions
    private let now: @MainActor () -> Date
    private let onInvalidated: @MainActor () -> Void
    private var store: ScribePersistentMemoryStore?
    private var maintenance: ScribePersistentMemoryMaintenance?
    private var activeActionID: UUID?

    init(
        consent: ComposePersistentMemoryConsentController,
        domainStore: ScribePersistentMemoryDomainStore,
        adapter: any ScribeConversationBindingCapturing,
        enabled: @escaping @MainActor () -> Bool,
        permissions: @escaping @MainActor () -> ScribeContextPlatformPermissions,
        actionIsCurrent: @escaping @MainActor (UUID) -> Bool,
        targetIsCurrent: @escaping @MainActor (ScribeContextSnapshot) -> Bool,
        now: @escaping @MainActor () -> Date = Date.init,
        onInvalidated: @escaping @MainActor () -> Void = {},
        securityBackend: any ScribePersistentMemorySecurityBackend = SystemScribePersistentMemorySecurityBackend()
    ) throws {
        self.consent = consent
        self.domainStore = domainStore
        self.securityBackend = securityBackend
        self.permissions = permissions
        self.now = now
        self.onInvalidated = onInvalidated
        self.scope = try ScribeConversationActionScope(
            adapter: adapter, enabled: enabled, policy: { consent.policy },
            permissions: permissions, actionIsCurrent: actionIsCurrent,
            targetIsCurrent: targetIsCurrent, now: now
        )
    }

    var isOpen: Bool { consent.policy.isEnabled && store != nil && maintenance?.isRunning == true }
    var acceptsExplicitSaves: Bool { isOpen }
    var permitsLocalDraftUse: Bool { isOpen && consent.preferences.permitsLocalDraftUse }
    var maintenanceFailure: ScribePersistentMemoryMaintenance.Failure? { maintenance?.lastFailure }

    /// A previously confirmed domain may be reopened without creating one.
    /// Missing or corrupt data/key state is never replaced with an empty store.
    @discardableResult
    func openExisting() throws -> Bool {
        guard consent.policy.isEnabled else {
            stopMaintenance()
            clear()
            store = nil
            return false
        }
        guard let domain = try domainStore.load() else { return false }
        let keys = try domainStore.makeKeyStore(for: domain, backend: securityBackend)
        _ = try keys.keyData()
        try openStore(domain: domain, keys: keys)
        return true
    }

    /// Only the UI for the current local installation may call this after
    /// presenting the retention and backup terms. It creates no fact.
    func activate(authority: ComposePersistentMemoryActivationAuthority) throws {
        guard authority == .confirmedByUser else {
            throw ComposePersistentMemoryRuntimeError.confirmationRequired
        }
        guard consent.policy.isEnabled else { throw ComposePersistentMemoryRuntimeError.unavailable }
        let domain = try domainStore.create(authority: .confirmedByUser)
        let keys = try domainStore.makeKeyStore(for: domain, backend: securityBackend)
        _ = try keys.provision(authority: .confirmedByUser)
        try openStore(domain: domain, keys: keys)
        composePersistentMemoryRuntimeLogger.debug("Durable-memory domain opened")
    }

    @discardableResult
    func begin(actionID: UUID, capture: ScribeContextSnapshot) -> Bool {
        guard isOpen else { return false }
        guard scope.begin(actionID: actionID, capture: capture) != nil else { return false }
        activeActionID = actionID
        store?.invalidateOperations()
        return true
    }

    @discardableResult
    func rebindAction(
        from oldActionID: UUID, to newActionID: UUID,
        capture: ScribeContextSnapshot
    ) -> Bool {
        guard isOpen, activeActionID == oldActionID,
              scope.rebind(from: oldActionID, to: newActionID, capture: capture) != nil else {
            clear()
            return false
        }
        activeActionID = newActionID
        store?.invalidateOperations()
        return true
    }

    func prepareSaveExplicitFact(
        _ text: String, actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> ScribePersistentMemorySaveProposal {
        let fact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty, fact.utf8.count <= 4_096 else {
            throw ComposePersistentMemoryRuntimeError.invalidFact
        }
        let (store, access) = try currentStoreAndAccess(actionID: actionID, capture: capture)
        let createdAt = now()
        let record = ScribeSessionMemoryRecord(
            id: UUID(), scopeKey: access.conversation.memoryKey, text: fact,
            topics: ["general"], provenance: .explicitUser(statementID: UUID()),
            origin: .init(actionID: actionID, captureID: capture.id),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(ComposePersistentMemoryPreferences.retentionInterval),
            supersedesRecordID: nil
        )
        return try store.beginSave(record, for: access)
    }

    /// A correction is another reviewed save. The prior fact remains current
    /// until the replacement proposal is explicitly confirmed and committed.
    func prepareCorrection(
        oldFact: String, newFact: String,
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> (previous: ScribeSessionMemoryRecord, proposal: ScribePersistentMemorySaveProposal) {
        let oldKey = ComposeMemoryFactMatch.key(oldFact)
        let newKey = ComposeMemoryFactMatch.key(newFact)
        let replacement = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldKey.isEmpty, !newKey.isEmpty, oldKey != newKey,
              oldFact.utf8.count <= 4_096, replacement.utf8.count <= 4_096 else {
            throw ComposePersistentMemoryRuntimeError.invalidFact
        }
        let (store, access) = try currentStoreAndAccess(actionID: actionID, capture: capture)
        let read = try store.read(for: access)
        defer { store.releaseRead(read) }
        try store.revalidateRead(read, for: access)
        let matches = read.records.filter {
            $0.kind == .explicitUserFact && ComposeMemoryFactMatch.key($0.text) == oldKey
        }
        guard !matches.isEmpty else { throw ComposePersistentMemoryRuntimeError.factNotFound }
        guard matches.count == 1, let previous = matches.first else {
            throw ComposePersistentMemoryRuntimeError.ambiguousFact
        }
        let createdAt = now()
        let record = ScribeSessionMemoryRecord(
            id: UUID(), scopeKey: access.conversation.memoryKey, text: replacement,
            topics: previous.topics, provenance: .explicitUser(statementID: UUID()),
            origin: .init(actionID: actionID, captureID: capture.id),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(ComposePersistentMemoryPreferences.retentionInterval),
            supersedesRecordID: previous.id
        )
        return (previous, try store.beginSave(record, for: access))
    }

    func completeSave(
        _ proposal: ScribePersistentMemorySaveProposal,
        decision: ScribePersistentMemorySaveDecision,
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws {
        let (store, access) = try currentStoreAndAccess(actionID: actionID, capture: capture)
        try store.completeSave(proposal, decision: decision, for: access)
    }

    func inspect(actionID: UUID, capture: ScribeContextSnapshot) throws -> [ScribeSessionMemoryRecord] {
        let (store, access) = try currentStoreAndAccess(actionID: actionID, capture: capture)
        let read = try store.read(for: access)
        defer { store.releaseRead(read) }
        try store.revalidateRead(read, for: access)
        return read.records
    }

    func draftFacts(
        for spokenRequest: String, actionID: UUID, capture: ScribeContextSnapshot,
        destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryDraftFacts? {
        guard destination == .legacyLocal,
              consent.preferences.permitsLocalDraftUse else { return nil }
        // An unavailable or unsupported document follows the transcript-only
        // path. A previously fact-backed action still fails its pinned-snapshot
        // recheck if this changes before publication, Copy, or Insert.
        guard let (store, access) = try? currentStoreAndAccess(
            actionID: actionID, capture: capture
        ) else { return nil }
        let read = try store.read(for: access)
        defer { store.releaseRead(read) }
        try store.revalidateRead(read, for: access)
        let facts = read.records.filter { $0.kind == .explicitUserFact }
        if ComposeSessionMemoryRelevance.needsClarification(facts, for: spokenRequest) {
            throw ComposeSessionMemoryContextError.ambiguousFollowUp
        }
        let relevant = ComposeSessionMemoryRelevance.select(facts, for: spokenRequest)
        guard !relevant.isEmpty else { return nil }
        guard relevant.count <= 6,
              relevant.reduce(0, { $0 + $1.text.utf8.count }) <= 8_192 else {
            throw ComposeSessionMemoryContextError.unavailable
        }
        return .init(
            recordIDs: relevant.map(\.id), texts: relevant.map(\.text),
            localUseRevision: consent.localUseRevision
        )
    }

    func prepareForgetCurrentDocument(
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> ScribePersistentMemoryForgetProposal {
        let (store, access) = try currentStoreAndAccess(actionID: actionID, capture: capture)
        let read = try store.read(for: access)
        defer { store.releaseRead(read) }
        try store.revalidateRead(read, for: access)
        return .init(token: read.token, activeFactCount: read.records.count)
    }

    func confirmForgetCurrentDocument(
        _ proposal: ScribePersistentMemoryForgetProposal,
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws {
        let (store, access) = try currentStoreAndAccess(actionID: actionID, capture: capture)
        guard proposal.token.scopeKey == access.conversation.memoryKey else {
            throw ScribePersistentMemoryError.scopeMismatch
        }
        try store.forget(
            scopeKey: access.conversation.memoryKey, expectedRevision: proposal.token
        )
        clear(actionID: actionID)
    }

    func forgetCurrentDocument(actionID: UUID, capture: ScribeContextSnapshot) throws {
        let (store, access) = try currentStoreAndAccess(actionID: actionID, capture: capture)
        try store.forget(scopeKey: access.conversation.memoryKey)
        // Forget also ends this action's authority. A delayed callback from
        // the same recording must not create a new proposal after deletion.
        clear(actionID: actionID)
    }

    /// Settings can erase every local record even after retention is disabled.
    /// A missing domain is absence, never a reason to create a key or store.
    @discardableResult
    func forgetAll(authority: ComposePersistentMemoryDeletionAuthority) throws -> Bool {
        guard authority == .confirmedByUser else {
            throw ComposePersistentMemoryRuntimeError.confirmationRequired
        }
        guard let domain = try domainStore.load() else { return false }
        let keys = try domainStore.makeKeyStore(for: domain, backend: securityBackend)
        _ = try keys.keyData()
        clear()
        stopMaintenance()
        store?.invalidateOperations()
        let deletionStore = makeStore(domain: domain, keys: keys)
        try deletionStore.forgetAll()
        if consent.policy.isEnabled {
            try openStore(domain: domain, keys: keys)
        } else {
            store = nil
        }
        onInvalidated()
        return true
    }

    func clear(actionID: UUID? = nil) {
        if let actionID, activeActionID != actionID { return }
        scope.clear(actionID: actionID)
        activeActionID = nil
        store?.invalidateOperations()
    }

    func updatePreferences(_ preferences: ComposePersistentMemoryPreferences) {
        guard consent.preferences != preferences else { return }
        clear()
        consent.updatePreferences(preferences)
        if !consent.policy.isEnabled {
            stopMaintenance()
            store = nil
        }
        onInvalidated()
    }

    private func currentStoreAndAccess(
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> (ScribePersistentMemoryStore, ScribeSessionMemoryAccess) {
        guard isOpen, let store else {
            throw ComposePersistentMemoryRuntimeError.unavailable
        }
        guard let access = scope.currentAccess(actionID: actionID, capture: capture) else {
            store.invalidateOperations()
            throw ComposePersistentMemoryRuntimeError.noCurrentAction
        }
        return (store, access)
    }

    private func makeStore(
        domain: ScribePersistentMemoryDomain,
        keys: KeychainScribePersistentMemoryKeyStore
    ) -> ScribePersistentMemoryStore {
        ScribePersistentMemoryStore(
            url: domain.storeURL, keyProvider: keys,
            identityResolver: scope.identityResolver,
            policy: { [consent] in consent.policy }, permissions: permissions,
            clock: now
        )
    }

    private func openStore(
        domain: ScribePersistentMemoryDomain,
        keys: KeychainScribePersistentMemoryKeyStore
    ) throws {
        stopMaintenance()
        store?.invalidateOperations()
        let newStore = makeStore(domain: domain, keys: keys)
        store = newStore
        let driver = ScribePersistentMemoryMaintenance(
            store: newStore,
            isAuthorized: { [weak self] in
                self?.consent.policy.isEnabled == true && self?.store === newStore
            },
            onInvalidated: { [weak self] in self?.onInvalidated() }
        )
        maintenance = driver
        driver.start()
        guard driver.isRunning else {
            store = nil
            throw ComposePersistentMemoryRuntimeError.unavailable
        }
    }

    private func stopMaintenance() {
        _ = maintenance?.stop()
        maintenance = nil
    }
}
