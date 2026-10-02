import Foundation

enum ScribePersistentMemoryError: Error, Equatable, Sendable {
    case keyUnavailable, unreadable, unknownSchema, staleToken, unconfirmed
    case invalidRecord, scopeMismatch, identityChanged, capacityExceeded
    case recordConflict, invalidCorrection, invalidClock, ioFailure, storeBusy, revisionExhausted
}

/// Durable revision plus a process-local owner prevents reuse after deletion,
/// another writer's commit, or reopening this service.
struct ScribePersistentMemoryRevisionToken: Equatable, Sendable {
    let id: UUID
    let storeID: UUID
    let storeIncarnation: UUID
    let revision: UInt64
    let scopeKey: ScribeConversationMemoryKey
}

struct ScribePersistentMemorySaveProposal: Equatable, Sendable {
    let token: ScribePersistentMemoryRevisionToken
    let record: ScribeSessionMemoryRecord
}

struct ScribePersistentMemoryForgetProposal: Equatable, Sendable {
    let token: ScribePersistentMemoryRevisionToken
    let activeFactCount: Int
}

/// The caller obtains this decision for the concrete proposal. There is no
/// default, serialized consent, or automatic confirmation in this foundation.
enum ScribePersistentMemorySaveDecision: Equatable, Sendable {
    case notConfirmed
    case confirmedByUser
}

struct ScribePersistentMemoryRead: Equatable, Sendable {
    let token: ScribePersistentMemoryRevisionToken
    let records: [ScribeSessionMemoryRecord]
    let supersededLineage: [ScribeSessionMemoryRecord]

    var dataCategories: Set<ScribeContextDataCategory> {
        (records + supersededLineage).reduce(into: [.persistentMemory]) { $0.formUnion($1.dataCategories) }
    }
}

struct ScribePersistentMemoryEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let nonce: Data
    let ciphertext: Data
    let tag: Data
}

struct ScribePersistentMemoryLimits: Equatable, Sendable {
    var maximumRecords = 128
    var maximumRecordUTF8Bytes = 4_096
    var maximumPlaintextBytes = 786_432
    var maximumFileBytes = 1_048_576
    var maximumPendingOperations = 16
    var operationLifetime: TimeInterval = 60
}

/// This foundation never creates, persists, or recovers a key. Exactly 32 bytes
/// must come from a separately configured local authority for AES-256.
protocol ScribePersistentMemoryKeyProviding: Sendable { func keyData() throws -> Data }

/// Injectable disk boundary. Writers must coordinate for this URL and preserve
/// previous file bytes if an atomic replacement fails before commit.
@MainActor
protocol ScribePersistentMemoryFileAccess {
    func withExclusiveLock<T>(at url: URL, _ operation: () throws -> T) throws -> T
    func read(at url: URL, maximumBytes: Int) throws -> Data?
    func writeAtomically(_ data: Data, to url: URL) throws
}
