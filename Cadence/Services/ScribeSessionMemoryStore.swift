import Foundation
import OSLog

private let scribeSessionMemoryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribeSessionMemoryStore"
)

/// Bounded, in-memory working context. Construction does not enable retention:
/// its default policy is disabled. No app, provider, history, disk, or UI access
/// occurs here. The owner supplies live identity and policy at every boundary.
@MainActor
final class ScribeSessionMemoryStore {
    private struct Environment {
        let policy: ScribeContextPolicySnapshot
        let permissions: ScribeContextPlatformPermissions
        let now: Date
    }

    private struct StoredRecord {
        let record: ScribeSessionMemoryRecord
        let authorization: ScribeContextAccessAuthorization
    }

    private struct Scope {
        var records: [UUID: StoredRecord] = [:]
        // Keep supersession while the old fact remains, even if its correction
        // expires first. Expiry must never make an obsolete fact current again.
        var supersededRecordIDs: Set<UUID> = []
        var lastActivity: Date
        var revision = UUID()
    }

    private struct PendingWrite {
        let access: ScribeSessionMemoryAccess
        let write: ScribeSessionMemoryWrite
        let authorization: ScribeContextAccessAuthorization
        let deadline: Date
    }

    private struct PendingRetrieval {
        let access: ScribeSessionMemoryAccess
        let query: ScribeSessionMemoryQuery
        let authorization: ScribeContextAccessAuthorization
        let deadline: Date
    }

    private struct RetrievalLease {
        let access: ScribeSessionMemoryAccess
        let result: ScribeSessionMemoryRetrieval
        let authorization: ScribeContextAccessAuthorization
        let scopeRevision: UUID?
        let deadline: Date
    }

    private let identityResolver: ScribeConversationIdentityResolver
    private let actionIsCurrent: @MainActor (ScribeSessionMemoryAccess) -> Bool
    private let policyProvider: () -> ScribeContextPolicySnapshot
    private let permissionsProvider: () -> ScribeContextPlatformPermissions
    private let clock: () -> Date
    private let limits: ScribeSessionMemoryLimits
    private var scopes: [ScribeConversationMemoryKey: Scope] = [:]
    private var pendingWrites: [UUID: PendingWrite] = [:]
    private var pendingRetrievals: [UUID: PendingRetrieval] = [:]
    private var retrievalLeases: [UUID: RetrievalLease] = [:]
    private var lastObservedTime: Date?
    private var isRevoked = false

    init(
        identityResolver: ScribeConversationIdentityResolver,
        actionIsCurrent: @escaping @MainActor (ScribeSessionMemoryAccess) -> Bool,
        policy: @escaping () -> ScribeContextPolicySnapshot = { .init() },
        permissions: @escaping () -> ScribeContextPlatformPermissions = { .init() },
        clock: @escaping () -> Date = Date.init,
        limits: ScribeSessionMemoryLimits = .init()
    ) {
        precondition(limits.maximumScopes > 0 && limits.maximumRecordsPerScope > 0)
        precondition(limits.maximumRecordUTF8Bytes > 0 && limits.maximumPendingOperations > 0)
        precondition(limits.maximumRetrievalRecords > 0 && limits.maximumRetrievalUTF8Bytes > 0)
        precondition(limits.operationLifetime.isFinite && limits.operationLifetime > 0
                     && limits.operationLifetime <= ScribeSessionMemoryLimits.inactivityInterval)
        self.identityResolver = identityResolver
        self.actionIsCurrent = actionIsCurrent
        self.policyProvider = policy
        self.permissionsProvider = permissions
        self.clock = clock
        self.limits = limits
    }

    func beginWrite(_ write: ScribeSessionMemoryWrite, for access: ScribeSessionMemoryAccess) throws -> ScribeSessionMemoryWriteToken {
        let environment = try refresh()
        try validate(access)
        try validate(write, at: environment.now)
        try validateCorrection(write, in: access.conversation.memoryKey)
        try checkPendingCapacity()
        let request = ScribeContextPolicyRequest(
            action: access.contextAction,
            operation: .retain(categories: write.provenance.dataCategories, destination: .sessionMemory, until: write.expiresAt)
        )
        let authorization = try authorize(request, environment)
        let token = ScribeSessionMemoryWriteToken(id: UUID())
        pendingWrites[token.id] = .init(access: access, write: write, authorization: authorization,
                                       deadline: environment.now.addingTimeInterval(limits.operationLifetime))
        return token
    }

    /// A failed/cancelled action cannot commit even an explicit-user fact. A
    /// successful action records attributed evidence, never proof of delivery.
    @discardableResult
    func completeWrite(
        _ token: ScribeSessionMemoryWriteToken,
        outcome: ScribeSessionMemoryActionOutcome,
        for access: ScribeSessionMemoryAccess
    ) throws -> ScribeSessionMemoryRecord? {
        let environment = try refresh()
        guard let pending = pendingWrites.removeValue(forKey: token.id) else {
            throw ScribeSessionMemoryError.unknownOperation
        }
        guard outcome == .completed else {
            cancel(actionID: pending.access.contextAction.actionID)
            return nil
        }
        try validate(pending.access, matches: access)
        try revalidate(pending.authorization, environment)
        try validate(pending.write, at: environment.now)
        let key = access.conversation.memoryKey
        try validateCorrection(pending.write, in: key)
        guard scopes[key] != nil || scopes.count < limits.maximumScopes else {
            throw ScribeSessionMemoryError.capacityExceeded
        }
        var scope = scopes[key] ?? Scope(lastActivity: environment.now)
        guard scope.records.count < limits.maximumRecordsPerScope else {
            throw ScribeSessionMemoryError.capacityExceeded
        }
        let record = ScribeSessionMemoryRecord(
            id: UUID(), scopeKey: key, text: pending.write.text, topics: pending.write.topics,
            provenance: pending.write.provenance,
            origin: .init(actionID: access.contextAction.actionID, captureID: access.contextAction.captureID),
            createdAt: environment.now, expiresAt: pending.write.expiresAt,
            supersedesRecordID: pending.write.supersedesRecordID
        )
        scope.records[record.id] = .init(record: record, authorization: pending.authorization)
        if let superseded = record.supersedesRecordID { scope.supersededRecordIDs.insert(superseded) }
        scope.lastActivity = environment.now
        scope.revision = UUID()
        scopes[key] = scope
        return record
    }

    func beginRetrieval(_ query: ScribeSessionMemoryQuery, for access: ScribeSessionMemoryAccess) throws -> ScribeSessionMemoryRetrievalToken {
        let environment = try refresh()
        try validate(access)
        guard validTopics(query.topics), query.maximumRecords > 0,
              query.maximumRecords <= limits.maximumRetrievalRecords,
              query.maximumUTF8Bytes > 0, query.maximumUTF8Bytes <= limits.maximumRetrievalUTF8Bytes else {
            throw ScribeSessionMemoryError.invalidQuery
        }
        try checkPendingCapacity()
        let authorization = try authorize(.init(action: access.contextAction, operation: .capture(.sessionMemory)), environment)
        let token = ScribeSessionMemoryRetrievalToken(id: UUID())
        pendingRetrievals[token.id] = .init(access: access, query: query, authorization: authorization,
                                           deadline: environment.now.addingTimeInterval(limits.operationLifetime))
        return token
    }

    func completeRetrieval(
        _ token: ScribeSessionMemoryRetrievalToken, for access: ScribeSessionMemoryAccess
    ) throws -> ScribeSessionMemoryRetrieval {
        let environment = try refresh()
        guard let pending = pendingRetrievals.removeValue(forKey: token.id) else {
            throw ScribeSessionMemoryError.unknownOperation
        }
        try validate(pending.access, matches: access)
        try revalidate(pending.authorization, environment)
        let key = access.conversation.memoryKey
        let records = scopes[key]?.records.values.map(\.record) ?? []
        let result = select(records, superseded: scopes[key]?.supersededRecordIDs ?? [], query: pending.query, id: token.id)
        if var scope = scopes[key] {
            scope.lastActivity = environment.now
            scopes[key] = scope
        }
        retrievalLeases[token.id] = .init(
            access: access, result: result, authorization: pending.authorization,
            scopeRevision: scopes[key]?.revision,
            deadline: environment.now.addingTimeInterval(limits.operationLifetime)
        )
        return result
    }

    /// Recheck immediately before consuming an earlier read at a later async
    /// boundary. A value already returned cannot be physically recalled, so its
    /// owner must enforce this check and separately authorize provider egress.
    func revalidateRetrieval(_ result: ScribeSessionMemoryRetrieval, for access: ScribeSessionMemoryAccess) throws {
        let environment = try refresh()
        guard let lease = retrievalLeases[result.id], lease.result == result,
              lease.scopeRevision == scopes[access.conversation.memoryKey]?.revision else {
            throw ScribeSessionMemoryError.staleRetrieval
        }
        try validate(lease.access, matches: access)
        try revalidate(lease.authorization, environment)
    }

    func releaseRetrieval(_ result: ScribeSessionMemoryRetrieval) {
        retrievalLeases.removeValue(forKey: result.id)
    }

    func cancel(actionID: UUID) {
        pendingWrites = pendingWrites.filter { $0.value.access.contextAction.actionID != actionID }
        pendingRetrievals = pendingRetrievals.filter { $0.value.access.contextAction.actionID != actionID }
        retrievalLeases = retrievalLeases.filter { $0.value.access.contextAction.actionID != actionID }
    }

    func forget(scopeKey: ScribeConversationMemoryKey) {
        scopes.removeValue(forKey: scopeKey)
        pendingWrites = pendingWrites.filter { $0.value.access.conversation.memoryKey != scopeKey }
        pendingRetrievals = pendingRetrievals.filter { $0.value.access.conversation.memoryKey != scopeKey }
        retrievalLeases = retrievalLeases.filter { $0.value.access.conversation.memoryKey != scopeKey }
    }

    func clear() {
        scopes.removeAll()
        pendingWrites.removeAll()
        pendingRetrievals.removeAll()
        retrievalLeases.removeAll()
    }

    /// Ends this store's authority permanently. A new explicitly configured
    /// store is needed for a new session; late callbacks cannot reactivate it.
    func revokeAccess() {
        isRevoked = true
        clear()
    }

    func endSession() { revokeAccess() }

    /// An owner may call this on permission changes or an idle timer. Every
    /// public read/write boundary also performs the same expiry/revocation pass.
    func purgeExpiredAndRevoked() throws { _ = try refresh() }

    private func refresh() throws -> Environment {
        guard !isRevoked else { throw ScribeSessionMemoryError.revoked }
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite,
              lastObservedTime.map({ now >= $0 }) ?? true else {
            clear()
            lastObservedTime = nil
            throw ScribeSessionMemoryError.invalidClock
        }
        lastObservedTime = now
        let environment = Environment(policy: policyProvider(), permissions: permissionsProvider(), now: now)
        guard environment.policy.isEnabled else {
            clear()
            return environment
        }
        for key in Array(scopes.keys) {
            guard var scope = scopes[key] else { continue }
            if now.timeIntervalSince(scope.lastActivity) >= ScribeSessionMemoryLimits.inactivityInterval {
                forget(scopeKey: key)
                continue
            }
            let retained = scope.records.filter { _, stored in
                stored.record.expiresAt > now && (try? revalidate(stored.authorization, environment)) != nil
            }
            if retained.count != scope.records.count {
                scope.records = retained
                scope.supersededRecordIDs.formIntersection(retained.keys)
                scope.revision = UUID()
            }
            if retained.isEmpty { forget(scopeKey: key) } else { scopes[key] = scope }
        }
        pendingWrites = pendingWrites.filter { _, pending in
            pending.deadline > now && actionIsCurrent(pending.access)
                && (try? revalidate(pending.authorization, environment)) != nil
        }
        pendingRetrievals = pendingRetrievals.filter { _, pending in
            pending.deadline > now && actionIsCurrent(pending.access)
                && (try? revalidate(pending.authorization, environment)) != nil
        }
        retrievalLeases = retrievalLeases.filter { _, lease in
            lease.deadline > now && actionIsCurrent(lease.access)
                && (try? revalidate(lease.authorization, environment)) != nil
                && lease.scopeRevision == scopes[lease.access.conversation.memoryKey]?.revision
        }
        return environment
    }

    private func authorize(_ request: ScribeContextPolicyRequest, _ environment: Environment) throws -> ScribeContextAccessAuthorization {
        try ScribeContextPolicy.authorize(request, using: environment.policy,
                                          permissions: environment.permissions, at: environment.now)
    }

    private func revalidate(_ authorization: ScribeContextAccessAuthorization, _ environment: Environment) throws {
        try ScribeContextPolicy.revalidate(authorization, for: authorization.request,
                                           using: environment.policy, permissions: environment.permissions, at: environment.now)
    }

    private func validate(_ access: ScribeSessionMemoryAccess) throws {
        guard actionIsCurrent(access) else { throw ScribeSessionMemoryError.actionNoLongerCurrent }
        guard identityResolver.revalidate(access.conversation, for: access.currentBinding) else {
            throw ScribeSessionMemoryError.identityChanged
        }
        let action = access.contextAction
        let binding = access.currentBinding
        guard action.actionID == binding.actionID,
              action.target.processIdentifier == binding.process.processIdentifier,
              action.target.bundleIdentifier == binding.process.bundleIdentifier,
              action.opaqueSurfaceID == access.conversation.memoryKey.opaqueValue else {
            throw ScribeSessionMemoryError.actionBindingMismatch
        }
    }

    private func validate(_ original: ScribeSessionMemoryAccess, matches current: ScribeSessionMemoryAccess) throws {
        guard original == current else { throw ScribeSessionMemoryError.actionBindingMismatch }
        try validate(current)
    }

    private func validate(_ write: ScribeSessionMemoryWrite, at now: Date) throws {
        guard !write.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              write.text.utf8.count <= limits.maximumRecordUTF8Bytes, validTopics(write.topics),
              write.expiresAt.timeIntervalSinceReferenceDate.isFinite, write.expiresAt > now else {
            throw ScribeSessionMemoryError.invalidRecord
        }
        if case let .observedSource(_, category) = write.provenance {
            guard [.selectedText, .surroundingText, .screenText].contains(category) else {
                throw ScribeSessionMemoryError.invalidRecord
            }
        }
    }

    private func validateCorrection(_ write: ScribeSessionMemoryWrite, in key: ScribeConversationMemoryKey) throws {
        guard let target = write.supersedesRecordID else { return }
        guard case .explicitUser = write.provenance,
              let scope = scopes[key], let previous = scope.records[target]?.record,
              previous.kind != .chosenDraft,
              !scope.supersededRecordIDs.contains(target) else {
            throw ScribeSessionMemoryError.invalidCorrection
        }
    }

    private func validTopics(_ topics: Set<String>) -> Bool {
        !topics.isEmpty && topics.count <= 8 && topics.allSatisfy { topic in
            !topic.isEmpty && topic.utf8.count <= 64 && topic.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
        }
    }

    private func checkPendingCapacity() throws {
        guard pendingWrites.count + pendingRetrievals.count + retrievalLeases.count < limits.maximumPendingOperations else {
            throw ScribeSessionMemoryError.capacityExceeded
        }
    }

    private func select(_ records: [ScribeSessionMemoryRecord], superseded: Set<UUID>, query: ScribeSessionMemoryQuery, id: UUID) -> ScribeSessionMemoryRetrieval {
        let ordered = records.filter {
            !superseded.contains($0.id) && !$0.topics.isDisjoint(with: query.topics)
                && (query.includesChosenDrafts || $0.kind != .chosenDraft)
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        var selected: [ScribeSessionMemoryRecord] = []
        var lineage: [ScribeSessionMemoryRecord] = []
        var bytes = 0
        for record in ordered where selected.count < query.maximumRecords {
            guard record.text.utf8.count <= query.maximumUTF8Bytes - bytes else { continue }
            selected.append(record)
            bytes += record.text.utf8.count
        }
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var visited = Set(selected.map(\.id))
        for record in selected {
            var previous = record.supersedesRecordID
            while let previousID = previous, let source = indexed[previousID], visited.insert(previousID).inserted {
                guard selected.count + lineage.count < query.maximumRecords,
                      source.text.utf8.count <= query.maximumUTF8Bytes - bytes else { break }
                lineage.append(source)
                bytes += source.text.utf8.count
                previous = source.supersedesRecordID
            }
        }
        return .init(id: id, facts: selected.filter { $0.kind != .chosenDraft },
                     chosenDrafts: selected.filter { $0.kind == .chosenDraft }, supersededLineage: lineage)
    }
}
