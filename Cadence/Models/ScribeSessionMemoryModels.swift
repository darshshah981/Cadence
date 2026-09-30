import Foundation

enum ScribeSessionMemorySourceCategory: String, Codable, Hashable, Sendable {
    case selectedText, surroundingText, screenText, sessionMemory, persistentMemory, priorDraft

    var contextCategory: ScribeContextDataCategory {
        switch self {
        case .selectedText: return .selectedText
        case .surroundingText: return .surroundingText
        case .screenText: return .screenText
        case .sessionMemory: return .sessionMemory
        case .persistentMemory: return .persistentMemory
        case .priorDraft: return .priorDraft
        }
    }
}

enum ScribeSessionMemoryDraftSelection: String, Codable, Hashable, Sendable {
    case copied, inserted
}

/// These labels describe evidence, not independently established truth. A copied
/// or inserted draft does not establish delivery, approval, payment, or a fact.
enum ScribeSessionMemoryProvenance: Codable, Equatable, Sendable {
    case explicitUser(statementID: UUID)
    case observedSource(snapshotID: UUID, category: ScribeSessionMemorySourceCategory)
    case chosenDraft(draftID: UUID, selection: ScribeSessionMemoryDraftSelection,
                     derivedFrom: Set<ScribeSessionMemorySourceCategory>)

    var kind: ScribeSessionMemoryRecordKind {
        switch self {
        case .explicitUser: return .explicitUserFact
        case .observedSource: return .observedSourceFact
        case .chosenDraft: return .chosenDraft
        }
    }

    var dataCategories: Set<ScribeContextDataCategory> {
        switch self {
        case .explicitUser: return [.sessionMemory]
        case let .observedSource(_, category): return [.sessionMemory, category.contextCategory]
        case let .chosenDraft(_, _, derivedFrom):
            return Set(derivedFrom.map(\.contextCategory)).union([.sessionMemory, .priorDraft])
        }
    }
}

enum ScribeSessionMemoryRecordKind: String, Codable, Hashable, Sendable {
    case explicitUserFact, observedSourceFact, chosenDraft
}

struct ScribeSessionMemoryOrigin: Codable, Equatable, Sendable {
    let actionID: UUID
    let captureID: UUID
}

/// Committed session content. Codable is an explicit DTO seam for separately
/// authorized persistence; the session store has no decode/import/restore API.
/// Decoding a record cannot confer identity, consent, or confirmation authority.
struct ScribeSessionMemoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let scopeKey: ScribeConversationMemoryKey
    let text: String
    let topics: Set<String>
    let provenance: ScribeSessionMemoryProvenance
    let origin: ScribeSessionMemoryOrigin
    let createdAt: Date
    let expiresAt: Date
    let supersedesRecordID: UUID?

    var kind: ScribeSessionMemoryRecordKind { provenance.kind }
    var dataCategories: Set<ScribeContextDataCategory> { provenance.dataCategories }

    init(id: UUID, scopeKey: ScribeConversationMemoryKey, text: String, topics: Set<String>,
         provenance: ScribeSessionMemoryProvenance, origin: ScribeSessionMemoryOrigin,
         createdAt: Date, expiresAt: Date, supersedesRecordID: UUID?) {
        self.id = id
        self.scopeKey = scopeKey
        self.text = text
        self.topics = topics
        self.provenance = provenance
        self.origin = origin
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.supersedesRecordID = supersedesRecordID
    }

    private enum CodingKeys: String, CodingKey {
        case id, scopeKey, text, topics, provenance, origin, createdAt, expiresAt, supersedesRecordID
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let key = try values.decode(String.self, forKey: .scopeKey)
        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .scopeKey, in: values, debugDescription: "Invalid opaque scope key")
        }
        self.init(
            id: try values.decode(UUID.self, forKey: .id), scopeKey: .init(opaqueValue: key),
            text: try values.decode(String.self, forKey: .text), topics: try values.decode(Set<String>.self, forKey: .topics),
            provenance: try values.decode(ScribeSessionMemoryProvenance.self, forKey: .provenance),
            origin: try values.decode(ScribeSessionMemoryOrigin.self, forKey: .origin),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            expiresAt: try values.decode(Date.self, forKey: .expiresAt),
            supersedesRecordID: try values.decodeIfPresent(UUID.self, forKey: .supersedesRecordID)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(scopeKey.opaqueValue, forKey: .scopeKey)
        try values.encode(text, forKey: .text)
        try values.encode(topics, forKey: .topics)
        try values.encode(provenance, forKey: .provenance)
        try values.encode(origin, forKey: .origin)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(expiresAt, forKey: .expiresAt)
        try values.encodeIfPresent(supersedesRecordID, forKey: .supersedesRecordID)
    }
}

/// Every call needs current authority-supplied process/surface identity and the
/// matching U8 capture binding. This value itself grants no memory access.
struct ScribeSessionMemoryAccess: Equatable, Sendable {
    let conversation: ScribeVerifiedConversationIdentity
    let currentBinding: ScribeConversationActionBinding
    let contextAction: ScribeContextActionBinding
}

struct ScribeSessionMemoryWrite: Equatable, Sendable {
    let text: String
    let topics: Set<String>
    let provenance: ScribeSessionMemoryProvenance
    let expiresAt: Date
    var supersedesRecordID: UUID? = nil
}

enum ScribeSessionMemoryActionOutcome: Equatable, Sendable {
    case completed, cancelled, failed
}

struct ScribeSessionMemoryWriteToken: Equatable, Sendable { let id: UUID }
struct ScribeSessionMemoryRetrievalToken: Equatable, Sendable { let id: UUID }

/// Topics are explicit compiler-supplied relevance tags. No fuzzy matching,
/// implicit whole-history fallback, or meaning inference happens in this store.
struct ScribeSessionMemoryQuery: Equatable, Sendable {
    let topics: Set<String>
    var includesChosenDrafts = false
    var maximumRecords = 6
    var maximumUTF8Bytes = 8_192
}

struct ScribeSessionMemoryRetrieval: Equatable, Sendable {
    let id: UUID
    let facts: [ScribeSessionMemoryRecord]
    let chosenDrafts: [ScribeSessionMemoryRecord]
    /// Historical facts are lineage only, never current factual candidates.
    let supersededLineage: [ScribeSessionMemoryRecord]

    var dataCategories: Set<ScribeContextDataCategory> {
        (facts + chosenDrafts + supersededLineage).reduce(into: [.sessionMemory]) { $0.formUnion($1.dataCategories) }
    }
}

struct ScribeSessionMemoryLimits: Equatable, Sendable {
    static let inactivityInterval: TimeInterval = 30 * 60
    var maximumScopes = 16
    var maximumRecordsPerScope = 32
    var maximumRecordUTF8Bytes = 4_096
    var maximumPendingOperations = 32
    var maximumRetrievalRecords = 12
    var maximumRetrievalUTF8Bytes = 16_384
    var operationLifetime: TimeInterval = 60
}

enum ScribeSessionMemoryError: Error, Equatable, Sendable {
    case revoked, invalidClock, identityChanged, actionBindingMismatch, actionNoLongerCurrent
    case invalidRecord, invalidQuery, capacityExceeded, invalidCorrection
    case unknownOperation, staleRetrieval
}
