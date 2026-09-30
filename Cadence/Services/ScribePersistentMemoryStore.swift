import CryptoKit
import Darwin
import Foundation
import OSLog

private let scribePersistentMemoryLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribePersistentMemoryStore"
)

/// Explicitly configured encrypted storage, separate from history and session
/// memory. No migration, automatic save, runtime activation, or key provisioning.
@MainActor
final class ScribePersistentMemoryStore {
    private static let schema = 1
    private static let authenticatedHeader = Data("Cadence.Compose.PersistentMemory.v1".utf8)

    private struct Manifest: Codable {
        let schemaVersion: Int
        let storeID: UUID
        var revision: UInt64
        var records: [ScribeSessionMemoryRecord]
        var supersededRecordIDs: Set<UUID>
    }
    private struct Environment {
        let now: Date
        let policy: ScribeContextPolicySnapshot
        let permissions: ScribeContextPlatformPermissions
    }
    private struct PendingSave {
        let proposal: ScribePersistentMemorySaveProposal
        let access: ScribeSessionMemoryAccess
        let authorization: ScribeContextAccessAuthorization
        let keyFingerprint: Data
        let deadline: Date
    }
    private struct ReadLease {
        let result: ScribePersistentMemoryRead
        let access: ScribeSessionMemoryAccess
        let authorization: ScribeContextAccessAuthorization
        let keyFingerprint: Data
        let deadline: Date
    }

    private let url: URL
    private let keys: any ScribePersistentMemoryKeyProviding
    private let identityResolver: ScribeConversationIdentityResolver
    private let policyProvider: () -> ScribeContextPolicySnapshot
    private let permissionsProvider: () -> ScribeContextPlatformPermissions
    private let clock: () -> Date
    private let files: any ScribePersistentMemoryFileAccess
    private let limits: ScribePersistentMemoryLimits
    private let incarnation = UUID()
    private let emptyStoreID = UUID()
    private var hasObservedFile = false
    private var lastObservedTime: Date?
    private var pendingSaves: [UUID: PendingSave] = [:]
    private var readLeases: [UUID: ReadLease] = [:]

    init(
        url: URL, keyProvider: any ScribePersistentMemoryKeyProviding,
        identityResolver: ScribeConversationIdentityResolver,
        policy: @escaping () -> ScribeContextPolicySnapshot = { .init() },
        permissions: @escaping () -> ScribeContextPlatformPermissions = { .init() },
        clock: @escaping () -> Date = Date.init,
        fileAccess: (any ScribePersistentMemoryFileAccess)? = nil,
        limits: ScribePersistentMemoryLimits = .init()
    ) {
        precondition(url.isFileURL && limits.maximumRecords > 0 && limits.maximumRecordUTF8Bytes > 0)
        precondition(limits.maximumPlaintextBytes > 0 && limits.maximumFileBytes > 0 && limits.maximumPendingOperations > 0)
        precondition(limits.operationLifetime.isFinite && limits.operationLifetime > 0)
        self.url = url
        self.keys = keyProvider
        self.identityResolver = identityResolver
        self.policyProvider = policy
        self.permissionsProvider = permissions
        self.clock = clock
        self.files = fileAccess ?? SystemScribePersistentMemoryFileAccess()
        self.limits = limits
    }

    /// Freezes the exact record for user review without saving its content.
    func beginSave(_ record: ScribeSessionMemoryRecord, for access: ScribeSessionMemoryAccess) throws -> ScribePersistentMemorySaveProposal {
        let environment = try currentEnvironment()
        try validate(access)
        try validateRecord(record)
        guard record.scopeKey == access.conversation.memoryKey else { throw ScribePersistentMemoryError.scopeMismatch }
        guard record.createdAt <= environment.now, record.expiresAt > environment.now else { throw ScribePersistentMemoryError.invalidRecord }
        try checkPendingCapacity()
        let authorization = try retentionAuthorization(record, access: access, environment: environment)
        return try files.withExclusiveLock(at: url) {
            let (manifest, key) = try loadManifest()
            try validateAddition(record, to: manifest, at: environment.now)
            let proposal = ScribePersistentMemorySaveProposal(token: token(manifest, scope: record.scopeKey), record: record)
            pendingSaves[proposal.token.id] = .init(proposal: proposal, access: access, authorization: authorization,
                                                   keyFingerprint: fingerprint(key),
                                                   deadline: environment.now.addingTimeInterval(limits.operationLifetime))
            return proposal
        }
    }

    func completeSave(
        _ proposal: ScribePersistentMemorySaveProposal, decision: ScribePersistentMemorySaveDecision,
        for access: ScribeSessionMemoryAccess
    ) throws {
        let environment = try currentEnvironment()
        guard let pending = pendingSaves.removeValue(forKey: proposal.token.id), pending.proposal == proposal,
              pending.access == access, proposal.token.storeIncarnation == incarnation else {
            throw ScribePersistentMemoryError.staleToken
        }
        guard decision == .confirmedByUser else { throw ScribePersistentMemoryError.unconfirmed }
        try validate(access)
        try revalidate(pending.authorization, environment)
        _ = try retentionAuthorization(proposal.record, access: access, environment: environment)
        try files.withExclusiveLock(at: url) {
            var (manifest, key) = try loadManifest()
            guard fingerprint(key) == pending.keyFingerprint else { throw ScribePersistentMemoryError.staleToken }
            try validate(proposal.token, against: manifest)
            try validateAddition(proposal.record, to: manifest, at: environment.now)
            pruneExpired(&manifest, at: environment.now)
            guard manifest.records.count < limits.maximumRecords else { throw ScribePersistentMemoryError.capacityExceeded }
            manifest.records.append(proposal.record)
            if let prior = proposal.record.supersedesRecordID { manifest.supersededRecordIDs.insert(prior) }
            try advanceRevision(&manifest)
            try writeManifest(manifest, key: key)
        }
        invalidateOperations()
    }

    /// Returns only the verified scope. The receipt must be revalidated before
    /// values are consumed at a later async boundary; egress needs its own grant.
    func read(for access: ScribeSessionMemoryAccess) throws -> ScribePersistentMemoryRead {
        let environment = try currentEnvironment()
        try validate(access)
        try checkPendingCapacity()
        let authorization = try authorize(.init(action: access.contextAction, operation: .capture(.persistentMemory)), environment)
        return try files.withExclusiveLock(at: url) {
            let (manifest, key) = try loadManifest()
            let matching = manifest.records.filter {
                $0.scopeKey == access.conversation.memoryKey && $0.createdAt <= environment.now && $0.expiresAt > environment.now
            }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
            for record in matching { _ = try retentionAuthorization(record, access: access, environment: environment) }
            let result = ScribePersistentMemoryRead(
                token: token(manifest, scope: access.conversation.memoryKey),
                records: matching.filter { !manifest.supersededRecordIDs.contains($0.id) },
                supersededLineage: matching.filter { manifest.supersededRecordIDs.contains($0.id) }
            )
            readLeases[result.token.id] = .init(result: result, access: access, authorization: authorization,
                                               keyFingerprint: fingerprint(key),
                                               deadline: environment.now.addingTimeInterval(limits.operationLifetime))
            return result
        }
    }

    func revalidateRead(_ result: ScribePersistentMemoryRead, for access: ScribeSessionMemoryAccess) throws {
        let environment = try currentEnvironment()
        guard let lease = readLeases[result.token.id], lease.result == result, lease.access == access,
              result.token.storeIncarnation == incarnation else { throw ScribePersistentMemoryError.staleToken }
        try validate(access)
        try revalidate(lease.authorization, environment)
        for record in result.records + result.supersededLineage {
            guard record.expiresAt > environment.now else { throw ScribePersistentMemoryError.staleToken }
            _ = try retentionAuthorization(record, access: access, environment: environment)
        }
        try files.withExclusiveLock(at: url) {
            let (manifest, key) = try loadManifest()
            guard fingerprint(key) == lease.keyFingerprint else { throw ScribePersistentMemoryError.staleToken }
            try validate(result.token, against: manifest)
        }
    }

    func releaseRead(_ result: ScribePersistentMemoryRead) { readLeases.removeValue(forKey: result.token.id) }

    /// Encrypted deletion and the advanced revision persist together. Keeping an
    /// empty manifest prevents reopening from undoing forget. OS backups and
    /// already returned or transmitted copies cannot be retroactively recalled.
    func forget(
        scopeKey: ScribeConversationMemoryKey,
        expectedRevision: ScribePersistentMemoryRevisionToken? = nil
    ) throws {
        guard validScopeKey(scopeKey) else { throw ScribePersistentMemoryError.scopeMismatch }
        if let expectedRevision, expectedRevision.scopeKey != scopeKey {
            throw ScribePersistentMemoryError.scopeMismatch
        }
        invalidateOperations()
        try files.withExclusiveLock(at: url) {
            var (manifest, key) = try loadManifest()
            if let expectedRevision { try validate(expectedRevision, against: manifest) }
            manifest.records.removeAll { $0.scopeKey == scopeKey }
            manifest.supersededRecordIDs.formIntersection(manifest.records.map(\.id))
            try advanceRevision(&manifest)
            try writeManifest(manifest, key: key)
        }
    }

    func forgetAll() throws {
        invalidateOperations()
        try files.withExclusiveLock(at: url) {
            var (manifest, key) = try loadManifest()
            manifest.records.removeAll()
            manifest.supersededRecordIDs.removeAll()
            try advanceRevision(&manifest)
            try writeManifest(manifest, key: key)
        }
    }

    /// Explicit housekeeping physically removes expired rows and advances the
    /// durable revision in one transaction. No timer or launch hook is installed
    /// here; while the app is closed, expiry prevents retrieval upon reopening
    /// but encrypted bytes remain until this operation or a confirmed mutation.
    @discardableResult
    func purgeExpired() throws -> Int {
        let now = try currentEnvironment().now
        return try files.withExclusiveLock(at: url) {
            var (manifest, key) = try loadManifest()
            let previousCount = manifest.records.count
            pruneExpired(&manifest, at: now)
            let removed = previousCount - manifest.records.count
            guard removed > 0 else { return 0 }
            try advanceRevision(&manifest)
            try writeManifest(manifest, key: key)
            invalidateOperations()
            return removed
        }
    }

    /// Permission changes invalidate pending use without implying disk deletion.
    func invalidateOperations() {
        pendingSaves.removeAll()
        readLeases.removeAll()
    }

    private func currentEnvironment() throws -> Environment {
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite, lastObservedTime.map({ now >= $0 }) ?? true else {
            invalidateOperations()
            // Keep the high-water mark: accepting a second call at the rolled
            // back time could make an expired disk record eligible again.
            throw ScribePersistentMemoryError.invalidClock
        }
        lastObservedTime = now
        let environment = Environment(now: now, policy: policyProvider(), permissions: permissionsProvider())
        pendingSaves = pendingSaves.filter { $0.value.deadline > now }
        readLeases = readLeases.filter { $0.value.deadline > now }
        if !environment.policy.isEnabled { invalidateOperations() }
        return environment
    }

    private func validate(_ access: ScribeSessionMemoryAccess) throws {
        guard identityResolver.revalidate(access.conversation, for: access.currentBinding) else {
            throw ScribePersistentMemoryError.identityChanged
        }
        let action = access.contextAction
        guard action.actionID == access.currentBinding.actionID,
              action.target.processIdentifier == access.currentBinding.process.processIdentifier,
              action.target.bundleIdentifier == access.currentBinding.process.bundleIdentifier,
              action.opaqueSurfaceID == access.conversation.memoryKey.opaqueValue,
              validScopeKey(access.conversation.memoryKey) else { throw ScribePersistentMemoryError.scopeMismatch }
    }

    private func authorize(_ request: ScribeContextPolicyRequest, _ environment: Environment) throws -> ScribeContextAccessAuthorization {
        try ScribeContextPolicy.authorize(request, using: environment.policy, permissions: environment.permissions, at: environment.now)
    }

    private func revalidate(_ authorization: ScribeContextAccessAuthorization, _ environment: Environment) throws {
        try ScribeContextPolicy.revalidate(authorization, for: authorization.request, using: environment.policy,
                                           permissions: environment.permissions, at: environment.now)
    }

    private func retentionAuthorization(_ record: ScribeSessionMemoryRecord, access: ScribeSessionMemoryAccess,
                                        environment: Environment) throws -> ScribeContextAccessAuthorization {
        try authorize(.init(action: access.contextAction,
                            operation: .retain(categories: record.dataCategories.union([.persistentMemory]),
                                               destination: .persistentMemory, until: record.expiresAt)), environment)
    }

    private func token(_ manifest: Manifest, scope: ScribeConversationMemoryKey) -> ScribePersistentMemoryRevisionToken {
        .init(id: UUID(), storeID: manifest.storeID, storeIncarnation: incarnation, revision: manifest.revision, scopeKey: scope)
    }

    private func validate(_ token: ScribePersistentMemoryRevisionToken, against manifest: Manifest) throws {
        guard token.storeIncarnation == incarnation, token.storeID == manifest.storeID, token.revision == manifest.revision else {
            throw ScribePersistentMemoryError.staleToken
        }
    }

    private func key() throws -> SymmetricKey {
        let data: Data
        do { data = try keys.keyData() } catch { throw ScribePersistentMemoryError.keyUnavailable }
        guard data.count == 32 else { throw ScribePersistentMemoryError.keyUnavailable }
        return SymmetricKey(data: data)
    }

    private func fingerprint(_ key: SymmetricKey) -> Data {
        Data(SHA256.hash(data: key.withUnsafeBytes { Data($0) }))
    }

    /// Validate the full existing file before every mutation. Corruption or an
    /// unavailable key never falls back to replacing the store with empty data.
    private func loadManifest() throws -> (Manifest, SymmetricKey) {
        let key = try key()
        guard let data = try files.read(at: url, maximumBytes: limits.maximumFileBytes) else {
            guard !hasObservedFile else { throw ScribePersistentMemoryError.staleToken }
            return (.init(schemaVersion: Self.schema, storeID: emptyStoreID, revision: 0, records: [], supersededRecordIDs: []), key)
        }
        let envelope: ScribePersistentMemoryEnvelope
        do { envelope = try JSONDecoder().decode(ScribePersistentMemoryEnvelope.self, from: data) }
        catch { throw ScribePersistentMemoryError.unreadable }
        guard envelope.schemaVersion == Self.schema else { throw ScribePersistentMemoryError.unknownSchema }
        guard envelope.nonce.count == 12, envelope.tag.count == 16,
              envelope.ciphertext.count <= limits.maximumPlaintextBytes else { throw ScribePersistentMemoryError.unreadable }
        let manifest: Manifest
        do {
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce), ciphertext: envelope.ciphertext, tag: envelope.tag)
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: Self.authenticatedHeader)
            guard plaintext.count <= limits.maximumPlaintextBytes else { throw ScribePersistentMemoryError.capacityExceeded }
            manifest = try JSONDecoder().decode(Manifest.self, from: plaintext)
        } catch { throw ScribePersistentMemoryError.unreadable }
        guard manifest.schemaVersion == Self.schema else { throw ScribePersistentMemoryError.unknownSchema }
        try validateManifest(manifest)
        hasObservedFile = true
        return (manifest, key)
    }

    private func validateManifest(_ manifest: Manifest) throws {
        guard manifest.records.count <= limits.maximumRecords else { throw ScribePersistentMemoryError.capacityExceeded }
        let ids = Set(manifest.records.map(\.id))
        guard ids.count == manifest.records.count, manifest.supersededRecordIDs.isSubset(of: ids) else {
            throw ScribePersistentMemoryError.unreadable
        }
        let indexed = Dictionary(uniqueKeysWithValues: manifest.records.map { ($0.id, $0) })
        for record in manifest.records {
            try validateRecord(record)
            var visited: Set<UUID> = [record.id]
            var next = record.supersedesRecordID
            while let priorID = next {
                guard visited.insert(priorID).inserted else { throw ScribePersistentMemoryError.unreadable }
                guard let prior = indexed[priorID] else { break }
                guard prior.scopeKey == record.scopeKey, prior.kind != .chosenDraft,
                      manifest.supersededRecordIDs.contains(priorID) else { throw ScribePersistentMemoryError.unreadable }
                next = prior.supersedesRecordID
            }
        }
    }

    private func validateRecord(_ record: ScribeSessionMemoryRecord) throws {
        guard validScopeKey(record.scopeKey), !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.text.utf8.count <= limits.maximumRecordUTF8Bytes,
              !record.topics.isEmpty, record.topics.count <= 8,
              record.topics.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
              }}), record.createdAt.timeIntervalSinceReferenceDate.isFinite,
              record.expiresAt.timeIntervalSinceReferenceDate.isFinite, record.createdAt < record.expiresAt,
              record.supersedesRecordID != record.id else { throw ScribePersistentMemoryError.invalidRecord }
        if case let .observedSource(_, category) = record.provenance {
            guard [.selectedText, .surroundingText, .screenText].contains(category) else { throw ScribePersistentMemoryError.invalidRecord }
        }
        if record.supersedesRecordID != nil {
            guard case .explicitUser = record.provenance else { throw ScribePersistentMemoryError.invalidCorrection }
        }
    }

    private func validateAddition(_ record: ScribeSessionMemoryRecord, to manifest: Manifest, at now: Date) throws {
        try validateRecord(record)
        guard !manifest.records.contains(where: { $0.id == record.id }) else { throw ScribePersistentMemoryError.recordConflict }
        guard record.createdAt <= now, record.expiresAt > now else { throw ScribePersistentMemoryError.invalidRecord }
        if let prior = record.supersedesRecordID {
            guard let previous = manifest.records.first(where: { $0.id == prior }), previous.expiresAt > now,
                  previous.scopeKey == record.scopeKey, previous.kind != .chosenDraft,
                  !manifest.supersededRecordIDs.contains(prior) else { throw ScribePersistentMemoryError.invalidCorrection }
        }
    }

    private func pruneExpired(_ manifest: inout Manifest, at now: Date) {
        manifest.records.removeAll { $0.expiresAt <= now }
        manifest.supersededRecordIDs.formIntersection(manifest.records.map(\.id))
    }

    private func advanceRevision(_ manifest: inout Manifest) throws {
        guard manifest.revision < UInt64.max else { throw ScribePersistentMemoryError.revisionExhausted }
        manifest.revision += 1
    }

    private func writeManifest(_ manifest: Manifest, key: SymmetricKey) throws {
        try validateManifest(manifest)
        let plaintext: Data
        do { plaintext = try JSONEncoder().encode(manifest) } catch { throw ScribePersistentMemoryError.unreadable }
        guard plaintext.count <= limits.maximumPlaintextBytes else { throw ScribePersistentMemoryError.capacityExceeded }
        let encoded: Data
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.authenticatedHeader)
            encoded = try JSONEncoder().encode(ScribePersistentMemoryEnvelope(
                schemaVersion: Self.schema, nonce: Data(sealed.nonce), ciphertext: sealed.ciphertext, tag: sealed.tag
            ))
        } catch { throw ScribePersistentMemoryError.unreadable }
        guard encoded.count <= limits.maximumFileBytes else { throw ScribePersistentMemoryError.capacityExceeded }
        try files.writeAtomically(encoded, to: url)
        hasObservedFile = true
    }

    private func validScopeKey(_ key: ScribeConversationMemoryKey) -> Bool {
        key.opaqueValue.utf8.count == 64 && key.opaqueValue.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func checkPendingCapacity() throws {
        guard pendingSaves.count + readLeases.count < limits.maximumPendingOperations else { throw ScribePersistentMemoryError.capacityExceeded }
    }
}

/// Cooperating processes lock the complete read/validate/replace transaction.
/// Atomic file replacement preserves the previous encrypted bytes on failure.
@MainActor
final class SystemScribePersistentMemoryFileAccess: ScribePersistentMemoryFileAccess {
    func withExclusiveLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw ScribePersistentMemoryError.ioFailure }
        let descriptor = Darwin.open(url.appendingPathExtension("lock").path,
                                     O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ScribePersistentMemoryError.ioFailure }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw ScribePersistentMemoryError.ioFailure
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? ScribePersistentMemoryError.storeBusy : ScribePersistentMemoryError.ioFailure
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    func read(at url: URL, maximumBytes: Int) throws -> Data? {
        guard maximumBytes > 0, maximumBytes < Int.max else { throw ScribePersistentMemoryError.capacityExceeded }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw ScribePersistentMemoryError.ioFailure
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw ScribePersistentMemoryError.ioFailure
        }
        guard metadata.st_size >= 0, metadata.st_size <= Int64(maximumBytes) else {
            throw ScribePersistentMemoryError.capacityExceeded
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(16_384, maximumBytes + 1))
        while data.count <= maximumBytes {
            let requested = min(buffer.count, maximumBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, requested) }
            if count == 0 { return data }
            guard count > 0 else { throw ScribePersistentMemoryError.ioFailure }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw ScribePersistentMemoryError.capacityExceeded
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .atomic) }
        catch { throw ScribePersistentMemoryError.ioFailure }
    }
}
