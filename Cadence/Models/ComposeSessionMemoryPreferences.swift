import Foundation

/// Consent metadata only. Neither facts nor source text are persisted here.
/// A new disclosure revision invalidates consent saved by an older build.
struct ComposeSessionMemoryPreferences: Equatable, Sendable {
    static let currentDisclosureRevision = 3

    var isEnabled = false
    var textEditAllowed = false
    var rememberExplicitFacts = false
    var rememberChosenDrafts = false
    var useFactsInLocalDrafts = false
    var disclosureRevision = currentDisclosureRevision

    var permitsTextEditUse: Bool {
        isEnabled && textEditAllowed && disclosureRevision == Self.currentDisclosureRevision
    }

    var permitsTextEditRetention: Bool {
        permitsTextEditUse && rememberExplicitFacts
    }

    var permitsChosenDraftRetention: Bool {
        permitsTextEditUse && rememberChosenDrafts
    }

    var permitsLocalDraftUse: Bool {
        permitsTextEditRetention && useFactsInLocalDrafts
    }
}
