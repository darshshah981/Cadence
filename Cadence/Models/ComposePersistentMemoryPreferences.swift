import Foundation

/// Consent metadata only. No saved facts or encryption material live here.
/// Durable retention cannot turn on until the current terms are accepted.
struct ComposePersistentMemoryPreferences: Equatable, Sendable {
    static let currentDisclosureRevision = 1
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    var isEnabled = false
    var textEditAllowed = false
    var useFactsInLocalDrafts = false
    var acceptedDisclosureRevision = 0

    var permitsTextEditRetention: Bool {
        isEnabled && textEditAllowed
            && acceptedDisclosureRevision == Self.currentDisclosureRevision
    }

    var permitsLocalDraftUse: Bool {
        permitsTextEditRetention && useFactsInLocalDrafts
    }
}
