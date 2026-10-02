import Foundation
import OSLog

private let composeSessionMemoryContextLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeSessionMemoryContext"
)

@MainActor
protocol ComposeSessionMemoryContextServing: AnyObject {
    var acceptsExplicitCommands: Bool { get }
    func draftFacts(
        for spokenRequest: String, actionID: UUID, capture: ScribeContextSnapshot,
        destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryDraftFacts?
    func begin(actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination)
    @discardableResult func rebindAction(
        from oldActionID: UUID, to newActionID: UUID,
        capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) -> Bool
    func perform(
        _ command: ComposeSessionMemoryCommand, actionID: UUID,
        capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryNotice
    @discardableResult func rememberChosenDraft(
        _ text: String, draftID: UUID, selection: ScribeSessionMemoryDraftSelection,
        actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) -> Bool
    func clear(actionID: UUID?)
}

enum ComposeSessionMemoryContextError: Error, Equatable {
    case unavailable
    case retentionNotAllowed
    case invalidFact
    case factNotFound
    case ambiguousFact
    case ambiguousFollowUp
}

/// An immutable, bounded snapshot of explicit facts selected for one draft.
/// IDs let retries reject a changed scope or a changed fact set.
struct ComposeSessionMemoryDraftFacts: Equatable, Sendable {
    let recordIDs: [UUID]
    let texts: [String]
    var localUseRevision = UUID()
}

/// Owns the local TextEdit conversation scope for one Compose action. It never
/// derives consent from selected-text settings or authorizes cloud egress.
@MainActor
final class ComposeSessionMemoryContextController: ComposeSessionMemoryContextServing {
    private let consent: ComposeSessionMemoryConsentController
    private let scope: ScribeConversationActionScope
    private let store: ScribeSessionMemoryStore
    private let now: @MainActor () -> Date
    private var activeActionID: UUID?
    private struct ChosenDraftKey: Hashable {
        let draftID: UUID
        let selection: ScribeSessionMemoryDraftSelection
    }
    private var rememberedDraftSelections = Set<ChosenDraftKey>()

    var acceptsExplicitCommands: Bool { consent.policy.isEnabled }

    init(
        consent: ComposeSessionMemoryConsentController,
        adapter: (any ScribeConversationBindingCapturing)? = nil,
        additionalAdapters: [any ScribeConversationBindingCapturing] = [],
        enabled: @escaping @MainActor () -> Bool = { false },
        permissions: @escaping @MainActor () -> ScribeContextPlatformPermissions = { .init() },
        actionIsCurrent: @escaping @MainActor (UUID) -> Bool = { _ in false },
        targetIsCurrent: @escaping @MainActor (ScribeContextSnapshot) -> Bool = { _ in false },
        now: @escaping @MainActor () -> Date = Date.init
    ) throws {
        self.consent = consent
        self.now = now
        let adapter = adapter ?? ScribeTextEditDocumentIdentityAdapter()
        let scope = try ScribeConversationActionScope(
            adapter: adapter, additionalAdapters: additionalAdapters,
            enabled: enabled, policy: { consent.policy },
            permissions: permissions, actionIsCurrent: actionIsCurrent,
            targetIsCurrent: targetIsCurrent, now: now
        )
        self.scope = scope
        self.store = ScribeSessionMemoryStore(
            identityResolver: scope.identityResolver, actionIsCurrent: { scope.isCurrent($0) },
            policy: { consent.policy }, permissions: permissions, clock: now
        )
    }

    func begin(actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination) {
        guard destination == .legacyLocal, consent.policy.isEnabled else { return }
        guard scope.begin(actionID: actionID, capture: capture) != nil else { return }
        if let previous = activeActionID, previous != actionID { store.cancel(actionID: previous) }
        if activeActionID != actionID { rememberedDraftSelections.removeAll() }
        activeActionID = actionID
        composeSessionMemoryContextLogger.debug("Conversation scope bound to Compose action")
    }

    @discardableResult
    func rebindAction(
        from oldActionID: UUID, to newActionID: UUID,
        capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) -> Bool {
        guard destination == .legacyLocal, activeActionID == oldActionID,
              scope.rebind(from: oldActionID, to: newActionID, capture: capture) != nil else {
            clear(actionID: oldActionID)
            return false
        }
        store.cancel(actionID: oldActionID)
        rememberedDraftSelections.removeAll()
        activeActionID = newActionID
        return true
    }

    /// Memory use remains local and separately guarded at every store call.
    /// No transcript is mined or retained merely by binding an action.
    func currentAccess(actionID: UUID, capture: ScribeContextSnapshot) -> ScribeSessionMemoryAccess? {
        scope.currentAccess(actionID: actionID, capture: capture)
    }

    /// The caller must first classify this action as an explicit user command.
    /// A generated draft, observed source, or copied result never enters here.
    func rememberExplicitFact(
        _ fact: String, actionID: UUID, capture: ScribeContextSnapshot,
        destination: ScribeEgressDestination
    ) throws -> ScribeSessionMemoryRecord {
        guard consent.preferences.permitsTextEditRetention else {
            throw ComposeSessionMemoryContextError.retentionNotAllowed
        }
        let fact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty, fact.utf8.count <= 4_096 else {
            throw ComposeSessionMemoryContextError.invalidFact
        }
        let access = try authorizedAccess(actionID: actionID, capture: capture, destination: destination)
        let write = ScribeSessionMemoryWrite(
            text: fact, topics: ["general"],
            provenance: .explicitUser(statementID: UUID()),
            expiresAt: now().addingTimeInterval(ScribeSessionMemoryLimits.inactivityInterval)
        )
        let token = try store.beginWrite(write, for: access)
        guard let record = try store.completeWrite(token, outcome: .completed, for: access) else {
            throw ComposeSessionMemoryContextError.unavailable
        }
        return record
    }

    @discardableResult
    func rememberChosenDraft(
        _ text: String, draftID: UUID, selection: ScribeSessionMemoryDraftSelection,
        actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) -> Bool {
        let key = ChosenDraftKey(draftID: draftID, selection: selection)
        guard consent.preferences.permitsChosenDraftRetention,
              destination == .legacyLocal, activeActionID == actionID,
              !rememberedDraftSelections.contains(key),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 4_096,
              let access = scope.currentAccess(actionID: actionID, capture: capture) else { return false }
        let write = ScribeSessionMemoryWrite(
            text: text, topics: ["general"],
            provenance: .chosenDraft(draftID: draftID, selection: selection, derivedFrom: []),
            expiresAt: now().addingTimeInterval(ScribeSessionMemoryLimits.inactivityInterval)
        )
        guard let token = try? store.beginWrite(write, for: access),
              (try? store.completeWrite(token, outcome: .completed, for: access)) != nil else { return false }
        rememberedDraftSelections.insert(key)
        return true
    }

    func inspectCurrentDocument(
        actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) throws -> [ScribeSessionMemoryRecord] {
        let access = try authorizedAccess(actionID: actionID, capture: capture, destination: destination)
        let token = try store.beginRetrieval(.init(topics: ["general"]), for: access)
        let result = try store.completeRetrieval(token, for: access)
        defer { store.releaseRetrieval(result) }
        try store.revalidateRetrieval(result, for: access)
        return result.facts
    }

    private func inspectChosenDrafts(
        actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) throws -> [ScribeSessionMemoryRecord] {
        let access = try authorizedAccess(actionID: actionID, capture: capture, destination: destination)
        let token = try store.beginRetrieval(
            .init(topics: ["general"], includesChosenDrafts: true, maximumRecords: 12), for: access
        )
        let result = try store.completeRetrieval(token, for: access)
        defer { store.releaseRetrieval(result) }
        try store.revalidateRetrieval(result, for: access)
        return result.chosenDrafts
    }

    func correctExplicitFact(
        oldFact: String, newFact: String, actionID: UUID,
        capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) throws -> (previous: ScribeSessionMemoryRecord, corrected: ScribeSessionMemoryRecord) {
        guard consent.preferences.permitsTextEditRetention else {
            throw ComposeSessionMemoryContextError.retentionNotAllowed
        }
        let oldKey = ComposeMemoryFactMatch.key(oldFact)
        let newKey = ComposeMemoryFactMatch.key(newFact)
        guard !oldKey.isEmpty, oldKey.utf8.count <= 4_096,
              !newKey.isEmpty, oldKey != newKey,
              newFact.utf8.count <= 4_096 else {
            throw ComposeSessionMemoryContextError.invalidFact
        }
        let matches = try inspectCurrentDocument(
            actionID: actionID, capture: capture, destination: destination
        ).filter { ComposeMemoryFactMatch.key($0.text) == oldKey }
        guard !matches.isEmpty else { throw ComposeSessionMemoryContextError.factNotFound }
        guard matches.count == 1, let previous = matches.first else {
            throw ComposeSessionMemoryContextError.ambiguousFact
        }
        let access = try authorizedAccess(actionID: actionID, capture: capture, destination: destination)
        let write = ScribeSessionMemoryWrite(
            text: newFact.trimmingCharacters(in: .whitespacesAndNewlines),
            topics: previous.topics,
            provenance: .explicitUser(statementID: UUID()),
            expiresAt: now().addingTimeInterval(ScribeSessionMemoryLimits.inactivityInterval),
            supersedesRecordID: previous.id
        )
        let token = try store.beginWrite(write, for: access)
        guard let corrected = try store.completeWrite(token, outcome: .completed, for: access) else {
            throw ComposeSessionMemoryContextError.unavailable
        }
        return (previous, corrected)
    }

    func draftFacts(
        for spokenRequest: String, actionID: UUID, capture: ScribeContextSnapshot,
        destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryDraftFacts? {
        guard destination == .legacyLocal else { return nil }
        guard consent.preferences.permitsLocalDraftUse else { return nil }
        // Unsupported or unavailable documents leave ordinary Compose on its
        // transcript-only path. Retrying a draft that used facts still fails
        // because the coordinator compares the immutable fact snapshot.
        guard let access = try? authorizedAccess(
            actionID: actionID, capture: capture, destination: destination
        ), let token = try? store.beginRetrieval(.init(topics: ["general"]), for: access),
           let result = try? store.completeRetrieval(token, for: access) else { return nil }
        defer { store.releaseRetrieval(result) }
        guard (try? store.revalidateRetrieval(result, for: access)) != nil else { return nil }
        if ComposeSessionMemoryRelevance.needsClarification(result.facts, for: spokenRequest) {
            throw ComposeSessionMemoryContextError.ambiguousFollowUp
        }
        let relevant = ComposeSessionMemoryRelevance.select(result.facts, for: spokenRequest)
        guard !relevant.isEmpty else { return nil }
        return .init(
            recordIDs: relevant.map(\.id), texts: relevant.map(\.text),
            localUseRevision: consent.localUseRevision
        )
    }

    func forgetCurrentDocument(
        actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) throws {
        let access = try authorizedAccess(actionID: actionID, capture: capture, destination: destination)
        store.forget(scopeKey: access.conversation.memoryKey)
    }

    func perform(
        _ command: ComposeSessionMemoryCommand, actionID: UUID,
        capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryNotice {
        switch command {
        case let .remember(fact):
            let saved = try rememberExplicitFact(
                fact, actionID: actionID, capture: capture, destination: destination
            )
            return .init(requestID: actionID, title: "Remembered for this session", detail: saved.text)
        case let .correct(oldFact, newFact):
            do {
                let change = try correctExplicitFact(
                    oldFact: oldFact, newFact: newFact, actionID: actionID,
                    capture: capture, destination: destination
                )
                return .init(
                    requestID: actionID, title: "Corrected for this session",
                    detail: "Previous: \(change.previous.text)\nNow: \(change.corrected.text)"
                )
            } catch ComposeSessionMemoryContextError.factNotFound {
                return .init(
                    requestID: actionID, title: "Correction not applied",
                    detail: "No matching recent fact was found for this document. Inspect its memory and try the exact wording."
                )
            } catch ComposeSessionMemoryContextError.ambiguousFact {
                return .init(
                    requestID: actionID, title: "Correction not applied",
                    detail: "More than one recent fact matches. No fact was changed."
                )
            }
        case .inspectCurrentDocument:
            let facts = try inspectCurrentDocument(
                actionID: actionID, capture: capture, destination: destination
            )
            let drafts = try inspectChosenDrafts(
                actionID: actionID, capture: capture, destination: destination
            )
            var sections: [String] = []
            if !facts.isEmpty {
                sections.append("Facts you explicitly saved:\n" + facts.map { "• \($0.text)" }.joined(separator: "\n\n"))
            }
            if !drafts.isEmpty {
                let lines = drafts.map { record in
                    let label: String
                    if case let .chosenDraft(_, selection, _) = record.provenance {
                        label = selection == .copied ? "Copied draft" : "Inserted draft"
                    } else { label = "Chosen draft" }
                    return "• \(label) (delivery not confirmed): \(record.text)"
                }
                sections.append("Drafts you chose:\n" + lines.joined(separator: "\n\n"))
            }
            let detail = sections.isEmpty
                ? "Nothing is remembered for this document."
                : sections.joined(separator: "\n\n")
            return .init(requestID: actionID, title: "Session memory for this document", detail: detail)
        case .forgetCurrentDocument:
            try forgetCurrentDocument(actionID: actionID, capture: capture, destination: destination)
            return .init(requestID: actionID, title: "Forgot this document", detail: "Its session memory was removed.")
        }
    }

    private func authorizedAccess(
        actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) throws -> ScribeSessionMemoryAccess {
        guard destination == .legacyLocal else { throw ComposeSessionMemoryContextError.unavailable }
        if let access = scope.currentAccess(actionID: actionID, capture: capture) { return access }
        begin(actionID: actionID, capture: capture, destination: destination)
        guard let access = scope.currentAccess(actionID: actionID, capture: capture) else {
            throw ComposeSessionMemoryContextError.unavailable
        }
        return access
    }

    func clear(actionID: UUID?) {
        if let actionID { store.cancel(actionID: actionID) }
        else if let activeActionID { store.cancel(actionID: activeActionID) }
        scope.clear(actionID: actionID)
        if actionID == nil || activeActionID == actionID {
            activeActionID = nil
            rememberedDraftSelections.removeAll()
        }
    }

    func updatePreferences(_ preferences: ComposeSessionMemoryPreferences) {
        let previous = consent.preferences
        clear(actionID: nil)
        if previous.isEnabled != preferences.isEnabled
            || previous.textEditAllowed != preferences.textEditAllowed
            || previous.rememberExplicitFacts != preferences.rememberExplicitFacts
            || previous.rememberChosenDrafts != preferences.rememberChosenDrafts
            || previous.disclosureRevision != preferences.disclosureRevision {
            store.clear()
        }
        consent.updatePreferences(preferences)
    }

    func endSession() {
        clear(actionID: nil)
        store.endSession()
        scope.revoke()
    }
}
