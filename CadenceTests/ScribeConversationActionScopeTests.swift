import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeConversationActionScopeTests {
    @Test
    func durableFactsEnterOnlyOptedInLocalDraftsForTheVerifiedDocument() throws {
        let fixture = ActionScopeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cadence-durable-local-use-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ScribePersistentMemoryDomainStore(
            directoryURL: directory, applicationBundleIdentifier: "com.example.CadenceTests"
        )
        let accepted = ComposePersistentMemoryPreferences(
            isEnabled: true, textEditAllowed: true,
            acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision
        )
        let consent = ComposePersistentMemoryConsentController(
            preferences: accepted, enabled: { fixture.enabled }, now: { fixture.now }
        )
        var invalidations = 0
        let runtime = try ComposePersistentMemoryRuntime(
            consent: consent, domainStore: owner, adapter: fixture.adapter,
            enabled: { fixture.enabled }, permissions: { fixture.permissions },
            actionIsCurrent: { fixture.currentActionID == $0 },
            targetIsCurrent: { _ in fixture.targetCurrent },
            now: { fixture.now }, onInvalidated: { invalidations += 1 },
            securityBackend: DomainKeyBackend()
        )
        try runtime.activate(authority: .confirmedByUser)
        let saveAction = UUID()
        fixture.currentActionID = saveAction
        let saveCapture = fixture.capture()
        #expect(runtime.begin(actionID: saveAction, capture: saveCapture))
        let proposal = try runtime.prepareSaveExplicitFact(
            "The synthetic project uses SwiftUI.", actionID: saveAction, capture: saveCapture
        )
        try runtime.completeSave(
            proposal, decision: .confirmedByUser, actionID: saveAction, capture: saveCapture
        )
        runtime.clear(actionID: saveAction)

        let draftAction = UUID()
        fixture.currentActionID = draftAction
        let draftCapture = fixture.capture()
        #expect(runtime.begin(actionID: draftAction, capture: draftCapture))
        let request = "Write a project update about SwiftUI."
        #expect(try runtime.draftFacts(
            for: request, actionID: draftAction, capture: draftCapture,
            destination: .legacyLocal
        ) == nil)
        var localUse = accepted
        localUse.useFactsInLocalDrafts = true
        runtime.updatePreferences(localUse)
        #expect(invalidations == 1)
        #expect(runtime.begin(actionID: draftAction, capture: draftCapture))
        let facts = try #require(try runtime.draftFacts(
            for: request, actionID: draftAction, capture: draftCapture,
            destination: .legacyLocal
        ))
        #expect(facts.texts == ["The synthetic project uses SwiftUI."])
        #expect(try runtime.draftFacts(
            for: request, actionID: draftAction, capture: draftCapture,
            destination: .openAIDirect
        ) == nil)

        let replacementAction = UUID()
        let capturesBeforeReview = fixture.adapter.captureCount
        fixture.currentActionID = replacementAction
        #expect(runtime.rebindAction(
            from: draftAction, to: replacementAction, capture: draftCapture
        ))
        #expect(fixture.adapter.captureCount == capturesBeforeReview)
        #expect(try runtime.draftFacts(
            for: request, actionID: replacementAction, capture: draftCapture,
            destination: .legacyLocal
        ) == facts)
        #expect(try runtime.draftFacts(
            for: request, actionID: draftAction, capture: draftCapture,
            destination: .legacyLocal
        ) == nil)

        fixture.adapter.documentID = .init(rawValue: "other-document")!
        fixture.adapter.navigationRevision = UUID()
        #expect(try runtime.draftFacts(
            for: request, actionID: replacementAction, capture: draftCapture,
            destination: .legacyLocal
        ) == nil)
        runtime.updatePreferences(accepted)
        #expect(invalidations == 2)
        #expect(!consent.preferences.permitsLocalDraftUse)
    }

    @Test
    func openingDurableMemoryPurgesExpiredCiphertextAndRevocationClosesIt() throws {
        let fixture = ActionScopeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cadence-durable-expiry-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ScribePersistentMemoryDomainStore(
            directoryURL: directory, applicationBundleIdentifier: "com.example.CadenceTests"
        )
        let backend = DomainKeyBackend()
        let accepted = ComposePersistentMemoryPreferences(
            isEnabled: true, textEditAllowed: true,
            acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision
        )
        let consent = ComposePersistentMemoryConsentController(
            preferences: accepted, enabled: { fixture.enabled }, now: { fixture.now }
        )
        var invalidations = 0
        func makeRuntime() throws -> ComposePersistentMemoryRuntime {
            try ComposePersistentMemoryRuntime(
                consent: consent, domainStore: owner, adapter: fixture.adapter,
                enabled: { fixture.enabled }, permissions: { fixture.permissions },
                actionIsCurrent: { fixture.currentActionID == $0 },
                targetIsCurrent: { _ in fixture.targetCurrent },
                now: { fixture.now }, onInvalidated: { invalidations += 1 },
                securityBackend: backend
            )
        }
        let runtime = try makeRuntime()
        try runtime.activate(authority: .confirmedByUser)
        #expect(runtime.isOpen)
        let saveAction = UUID()
        fixture.currentActionID = saveAction
        let saveCapture = fixture.capture()
        #expect(runtime.begin(actionID: saveAction, capture: saveCapture))
        let proposal = try runtime.prepareSaveExplicitFact(
            "An expiring synthetic fact.", actionID: saveAction, capture: saveCapture
        )
        try runtime.completeSave(
            proposal, decision: .confirmedByUser, actionID: saveAction,
            capture: saveCapture
        )
        let encryptedBeforeExpiry = try Data(contentsOf: owner.storeURL)
        runtime.clear(actionID: saveAction)

        fixture.now = fixture.now.addingTimeInterval(
            ComposePersistentMemoryPreferences.retentionInterval + 1
        )
        let reopened = try makeRuntime()
        #expect(try reopened.openExisting())
        #expect(reopened.isOpen)
        #expect(invalidations == 1)
        #expect(try Data(contentsOf: owner.storeURL) != encryptedBeforeExpiry)
        let inspectAction = UUID()
        fixture.currentActionID = inspectAction
        let inspectCapture = fixture.capture()
        #expect(reopened.begin(actionID: inspectAction, capture: inspectCapture))
        #expect(try reopened.inspect(actionID: inspectAction, capture: inspectCapture).isEmpty)

        reopened.updatePreferences(.init())
        #expect(!reopened.isOpen)
        #expect(throws: ComposePersistentMemoryRuntimeError.unavailable) {
            try reopened.inspect(actionID: inspectAction, capture: inspectCapture)
        }
    }

    @Test
    func durableMemoryRuntimeCannotCreateAKeyOrDomainWithoutCurrentConsentAndConfirmation() throws {
        let fixture = ActionScopeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cadence-durable-runtime-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ScribePersistentMemoryDomainStore(
            directoryURL: directory, applicationBundleIdentifier: "com.example.CadenceTests"
        )
        let backend = DomainKeyBackend()
        let consent = ComposePersistentMemoryConsentController(enabled: { fixture.enabled }, now: { fixture.now })
        let runtime = try ComposePersistentMemoryRuntime(
            consent: consent, domainStore: owner, adapter: fixture.adapter,
            enabled: { fixture.enabled }, permissions: { fixture.permissions },
            actionIsCurrent: { fixture.currentActionID == $0 },
            targetIsCurrent: { _ in fixture.targetCurrent },
            now: { fixture.now }, securityBackend: backend
        )

        #expect(try !runtime.openExisting())
        #expect(throws: ComposePersistentMemoryRuntimeError.confirmationRequired) {
            try runtime.activate(authority: .notConfirmed)
        }
        #expect(throws: ComposePersistentMemoryRuntimeError.unavailable) {
            try runtime.activate(authority: .confirmedByUser)
        }
        #expect(throws: ComposePersistentMemoryRuntimeError.confirmationRequired) {
            try runtime.forgetAll(authority: .notConfirmed)
        }
        #expect(try !runtime.forgetAll(authority: .confirmedByUser))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(backend.calls == 0)
    }

    @Test
    func confirmedForgetAllWorksAfterConsentIsDisabledAndSurvivesReopen() throws {
        let fixture = ActionScopeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cadence-durable-forget-all-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ScribePersistentMemoryDomainStore(
            directoryURL: directory, applicationBundleIdentifier: "com.example.CadenceTests"
        )
        let backend = DomainKeyBackend()
        let accepted = ComposePersistentMemoryPreferences(
            isEnabled: true, textEditAllowed: true,
            acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision
        )
        let consent = ComposePersistentMemoryConsentController(
            preferences: accepted, enabled: { fixture.enabled }, now: { fixture.now }
        )
        func makeRuntime() throws -> ComposePersistentMemoryRuntime {
            try ComposePersistentMemoryRuntime(
                consent: consent, domainStore: owner, adapter: fixture.adapter,
                enabled: { fixture.enabled }, permissions: { fixture.permissions },
                actionIsCurrent: { fixture.currentActionID == $0 },
                targetIsCurrent: { _ in fixture.targetCurrent },
                now: { fixture.now }, securityBackend: backend
            )
        }
        let runtime = try makeRuntime()
        try runtime.activate(authority: .confirmedByUser)
        let actionID = UUID()
        fixture.currentActionID = actionID
        let capture = fixture.capture()
        #expect(runtime.begin(actionID: actionID, capture: capture))
        let proposal = try runtime.prepareSaveExplicitFact(
            "Synthetic durable fact.", actionID: actionID, capture: capture
        )
        try runtime.completeSave(
            proposal, decision: .confirmedByUser, actionID: actionID, capture: capture
        )
        runtime.updatePreferences(.init())
        #expect(!runtime.isOpen)
        #expect(try runtime.forgetAll(authority: .confirmedByUser))
        #expect(throws: ComposePersistentMemoryRuntimeError.unavailable) {
            try runtime.inspect(actionID: actionID, capture: capture)
        }

        runtime.updatePreferences(accepted)
        #expect(try runtime.openExisting())
        let newAction = UUID()
        fixture.currentActionID = newAction
        let newCapture = fixture.capture()
        #expect(runtime.begin(actionID: newAction, capture: newCapture))
        #expect(try runtime.inspect(actionID: newAction, capture: newCapture).isEmpty)
    }

    @Test
    func confirmedDurableFactSurvivesReopenAndForgetStaysScoped() throws {
        let fixture = ActionScopeFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cadence-durable-runtime-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ScribePersistentMemoryDomainStore(
            directoryURL: directory, applicationBundleIdentifier: "com.example.CadenceTests"
        )
        let backend = DomainKeyBackend()
        let acceptedPreferences = ComposePersistentMemoryPreferences(
            isEnabled: true, textEditAllowed: true,
            acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision
        )
        let consent = ComposePersistentMemoryConsentController(
            preferences: acceptedPreferences, enabled: { fixture.enabled }, now: { fixture.now }
        )
        func makeRuntime() throws -> ComposePersistentMemoryRuntime {
            try ComposePersistentMemoryRuntime(
                consent: consent, domainStore: owner, adapter: fixture.adapter,
                enabled: { fixture.enabled }, permissions: { fixture.permissions },
                actionIsCurrent: { fixture.currentActionID == $0 },
                targetIsCurrent: { _ in fixture.targetCurrent },
                now: { fixture.now }, securityBackend: backend
            )
        }
        let runtime = try makeRuntime()
        try runtime.activate(authority: .confirmedByUser)
        let saveAction = UUID()
        fixture.currentActionID = saveAction
        let saveCapture = fixture.capture()
        #expect(runtime.begin(actionID: saveAction, capture: saveCapture))
        let rejected = try runtime.prepareSaveExplicitFact(
            "Synthetic project uses SwiftUI.", actionID: saveAction, capture: saveCapture
        )
        #expect(!FileManager.default.fileExists(atPath: owner.storeURL.path))
        #expect(throws: ScribePersistentMemoryError.unconfirmed) {
            try runtime.completeSave(
                rejected, decision: .notConfirmed,
                actionID: saveAction, capture: saveCapture
            )
        }
        #expect(!FileManager.default.fileExists(atPath: owner.storeURL.path))
        let confirmed = try runtime.prepareSaveExplicitFact(
            "Synthetic project uses SwiftUI.", actionID: saveAction, capture: saveCapture
        )
        try runtime.completeSave(
            confirmed, decision: .confirmedByUser,
            actionID: saveAction, capture: saveCapture
        )
        #expect(try runtime.inspect(actionID: saveAction, capture: saveCapture).map(\.text)
                == ["Synthetic project uses SwiftUI."])
        #expect(try Data(contentsOf: owner.storeURL).range(of: Data("Synthetic project uses SwiftUI.".utf8)) == nil)

        let encryptedBeforeDisable = try Data(contentsOf: owner.storeURL)
        let pendingBeforeDisable = try runtime.prepareSaveExplicitFact(
            "Must not persist after disabling.", actionID: saveAction, capture: saveCapture
        )
        runtime.updatePreferences(.init())
        #expect(!runtime.isOpen)
        #expect(throws: ComposePersistentMemoryRuntimeError.unavailable) {
            try runtime.completeSave(
                pendingBeforeDisable, decision: .confirmedByUser,
                actionID: saveAction, capture: saveCapture
            )
        }
        #expect(try Data(contentsOf: owner.storeURL) == encryptedBeforeDisable)
        runtime.updatePreferences(acceptedPreferences)

        runtime.clear(actionID: saveAction)
        let reopened = try makeRuntime()
        #expect(try reopened.openExisting())
        let resumedAction = UUID()
        fixture.currentActionID = resumedAction
        let resumedCapture = fixture.capture()
        #expect(reopened.begin(actionID: resumedAction, capture: resumedCapture))
        #expect(try reopened.inspect(actionID: resumedAction, capture: resumedCapture).map(\.text)
                == ["Synthetic project uses SwiftUI."])
        #expect(throws: ComposePersistentMemoryRuntimeError.factNotFound) {
            try reopened.prepareCorrection(
                oldFact: "Synthetic project uses UIKit.",
                newFact: "Synthetic project uses AppKit.",
                actionID: resumedAction, capture: resumedCapture
            )
        }
        let rejectedCorrection = try reopened.prepareCorrection(
            oldFact: "synthetic project uses swiftui",
            newFact: "Synthetic project uses AppKit.",
            actionID: resumedAction, capture: resumedCapture
        )
        #expect(rejectedCorrection.proposal.record.supersedesRecordID == rejectedCorrection.previous.id)
        #expect(throws: ScribePersistentMemoryError.unconfirmed) {
            try reopened.completeSave(
                rejectedCorrection.proposal, decision: .notConfirmed,
                actionID: resumedAction, capture: resumedCapture
            )
        }
        #expect(try reopened.inspect(actionID: resumedAction, capture: resumedCapture).map(\.text)
                == ["Synthetic project uses SwiftUI."])
        let correction = try reopened.prepareCorrection(
            oldFact: "Synthetic project uses SwiftUI.",
            newFact: "Synthetic project uses AppKit.",
            actionID: resumedAction, capture: resumedCapture
        )
        try reopened.completeSave(
            correction.proposal, decision: .confirmedByUser,
            actionID: resumedAction, capture: resumedCapture
        )
        #expect(try reopened.inspect(actionID: resumedAction, capture: resumedCapture).map(\.text)
                == ["Synthetic project uses AppKit."])
        let correctionReader = try makeRuntime()
        #expect(try correctionReader.openExisting())
        #expect(correctionReader.begin(actionID: resumedAction, capture: resumedCapture))
        #expect(try correctionReader.inspect(actionID: resumedAction, capture: resumedCapture).map(\.text)
                == ["Synthetic project uses AppKit."])
        correctionReader.clear(actionID: resumedAction)
        let currentProposal = try reopened.prepareSaveExplicitFact(
            "Another synthetic project fact.", actionID: resumedAction, capture: resumedCapture
        )
        reopened.clear(actionID: saveAction)
        try reopened.completeSave(
            currentProposal, decision: .confirmedByUser,
            actionID: resumedAction, capture: resumedCapture
        )
        #expect(try reopened.inspect(actionID: resumedAction, capture: resumedCapture).count == 2)

        fixture.adapter.documentID = .init(rawValue: "document-b")!
        fixture.adapter.navigationRevision = UUID()
        let otherAction = UUID()
        fixture.currentActionID = otherAction
        let otherCapture = fixture.capture()
        #expect(reopened.begin(actionID: otherAction, capture: otherCapture))
        #expect(try reopened.inspect(actionID: otherAction, capture: otherCapture).isEmpty)

        fixture.adapter.documentID = .init(rawValue: "document-a")!
        fixture.adapter.navigationRevision = UUID()
        let forgetAction = UUID()
        fixture.currentActionID = forgetAction
        let forgetCapture = fixture.capture()
        #expect(reopened.begin(actionID: forgetAction, capture: forgetCapture))
        let pendingAtForget = try reopened.prepareSaveExplicitFact(
            "A late fact must not revive memory.", actionID: forgetAction,
            capture: forgetCapture
        )
        try reopened.forgetCurrentDocument(actionID: forgetAction, capture: forgetCapture)
        #expect(throws: ComposePersistentMemoryRuntimeError.noCurrentAction) {
            try reopened.completeSave(
                pendingAtForget, decision: .confirmedByUser,
                actionID: forgetAction, capture: forgetCapture
            )
        }
        #expect(throws: ComposePersistentMemoryRuntimeError.noCurrentAction) {
            try reopened.prepareSaveExplicitFact(
                "Another late fact.", actionID: forgetAction, capture: forgetCapture
            )
        }
        let afterForget = try makeRuntime()
        #expect(try afterForget.openExisting())
        let inspectAction = UUID()
        fixture.currentActionID = inspectAction
        let inspectCapture = fixture.capture()
        #expect(afterForget.begin(actionID: inspectAction, capture: inspectCapture))
        #expect(try afterForget.inspect(actionID: inspectAction, capture: inspectCapture).isEmpty)
    }

    @Test
    func explicitCorrectionSupersedesOnlyTheMatchedDocumentFact() throws {
        let fixture = ActionScopeFixture()
        let consent = ComposeSessionMemoryConsentController(
            preferences: .init(
                isEnabled: true, textEditAllowed: true,
                rememberExplicitFacts: true, useFactsInLocalDrafts: true
            ), enabled: { true }, now: { fixture.now }
        )
        let controller = try ComposeSessionMemoryContextController(
            consent: consent, adapter: fixture.adapter,
            enabled: { fixture.enabled }, permissions: { fixture.permissions },
            actionIsCurrent: { fixture.currentActionID == $0 },
            targetIsCurrent: { _ in fixture.targetCurrent }, now: { fixture.now }
        )
        let saveAction = UUID()
        fixture.currentActionID = saveAction
        let saved = try controller.rememberExplicitFact(
            "The refund was approved.", actionID: saveAction,
            capture: fixture.capture(), destination: .legacyLocal
        )
        let correctionAction = UUID()
        fixture.currentActionID = correctionAction
        let correctionCapture = fixture.capture()
        let changed = try controller.correctExplicitFact(
            oldFact: "the refund was approved", newFact: "The refund is delayed.",
            actionID: correctionAction, capture: correctionCapture,
            destination: .legacyLocal
        )
        #expect(changed.corrected.supersedesRecordID == saved.id)
        #expect(try controller.inspectCurrentDocument(
            actionID: correctionAction, capture: correctionCapture,
            destination: .legacyLocal
        ).map(\.text) == ["The refund is delayed."])
        #expect(try controller.draftFacts(
            for: "Ask for an update on the refund.", actionID: correctionAction,
            capture: correctionCapture, destination: .legacyLocal
        )?.texts == ["The refund is delayed."])
        let noMatch = try controller.perform(
            .correct(oldFact: "The refund was approved.", newFact: "The refund was paid."),
            actionID: correctionAction, capture: correctionCapture,
            destination: .legacyLocal
        )
        #expect(noMatch.title == "Correction not applied")

        fixture.adapter.documentID = .init(rawValue: "document-b")!
        fixture.adapter.navigationRevision = UUID()
        let otherAction = UUID()
        fixture.currentActionID = otherAction
        #expect(try controller.inspectCurrentDocument(
            actionID: otherAction, capture: fixture.capture(), destination: .legacyLocal
        ).isEmpty)

        fixture.adapter.documentID = .init(rawValue: "document-a")!
        fixture.adapter.navigationRevision = UUID()
        let returnedAction = UUID()
        fixture.currentActionID = returnedAction
        #expect(try controller.inspectCurrentDocument(
            actionID: returnedAction, capture: fixture.capture(), destination: .legacyLocal
        ).map(\.id) == [changed.corrected.id])
    }

    @Test
    func localDraftUsesOnlyRelevantFactsFromTheVerifiedDocument() throws {
        let fixture = ActionScopeFixture()
        let consent = ComposeSessionMemoryConsentController(
            preferences: .init(
                isEnabled: true, textEditAllowed: true,
                rememberExplicitFacts: true, useFactsInLocalDrafts: true
            ), enabled: { true }, now: { fixture.now }
        )
        let controller = try ComposeSessionMemoryContextController(
            consent: consent, adapter: fixture.adapter,
            enabled: { fixture.enabled }, permissions: { fixture.permissions },
            actionIsCurrent: { fixture.currentActionID == $0 },
            targetIsCurrent: { _ in fixture.targetCurrent }, now: { fixture.now }
        )
        let firstAction = UUID()
        fixture.currentActionID = firstAction
        let firstCapture = fixture.capture()
        _ = try controller.rememberExplicitFact(
            "The refund is delayed.", actionID: firstAction,
            capture: firstCapture, destination: .legacyLocal
        )
        _ = try controller.rememberExplicitFact(
            "The conference is next week.", actionID: firstAction,
            capture: firstCapture, destination: .legacyLocal
        )

        let draftAction = UUID()
        fixture.currentActionID = draftAction
        let draftCapture = fixture.capture()
        let firstDraftFacts = try controller.draftFacts(
            for: "Ask for an update on the refund.", actionID: draftAction,
            capture: draftCapture, destination: .legacyLocal
        )
        #expect(firstDraftFacts?.texts == ["The refund is delayed."])
        #expect(try controller.draftFacts(
            for: "Ask for an update on the refund.", actionID: draftAction,
            capture: draftCapture, destination: .deepSeek
        ) == nil)

        controller.updatePreferences(.init(
            isEnabled: true, textEditAllowed: true, rememberExplicitFacts: true,
            useFactsInLocalDrafts: false
        ))
        #expect(try controller.draftFacts(
            for: "Ask for an update on the refund.", actionID: draftAction,
            capture: draftCapture, destination: .legacyLocal
        ) == nil)
        controller.updatePreferences(.init(
            isEnabled: true, textEditAllowed: true, rememberExplicitFacts: true,
            useFactsInLocalDrafts: true
        ))
        let resumedAction = UUID()
        fixture.currentActionID = resumedAction
        let resumedCapture = fixture.capture()
        let resumedFacts = try controller.draftFacts(
            for: "Ask for an update on the refund.", actionID: resumedAction,
            capture: resumedCapture, destination: .legacyLocal
        )
        #expect(resumedFacts?.texts == firstDraftFacts?.texts)
        #expect(resumedFacts != firstDraftFacts)

        fixture.adapter.documentID = .init(rawValue: "document-b")!
        fixture.adapter.navigationRevision = UUID()
        let otherAction = UUID()
        fixture.currentActionID = otherAction
        #expect(try controller.draftFacts(
            for: "Ask for an update on the refund.", actionID: otherAction,
            capture: fixture.capture(), destination: .legacyLocal
        ) == nil)
        #expect(try controller.draftFacts(
            for: "Ask for an update on the refund.", actionID: draftAction,
            capture: draftCapture, destination: .legacyLocal
        ) == nil)
    }

    @Test
    func genericFollowUpUsesOneExplicitFactButNeverGuessesBetweenFactsOrDocuments() throws {
        let fixture = ActionScopeFixture()
        let consent = ComposeSessionMemoryConsentController(
            preferences: .init(
                isEnabled: true, textEditAllowed: true,
                rememberExplicitFacts: true, useFactsInLocalDrafts: true
            ), enabled: { true }, now: { fixture.now }
        )
        let controller = try ComposeSessionMemoryContextController(
            consent: consent, adapter: fixture.adapter,
            enabled: { fixture.enabled }, permissions: { fixture.permissions },
            actionIsCurrent: { fixture.currentActionID == $0 },
            targetIsCurrent: { _ in fixture.targetCurrent }, now: { fixture.now }
        )
        let saveAction = UUID()
        fixture.currentActionID = saveAction
        let saveCapture = fixture.capture()
        _ = try controller.rememberExplicitFact(
            "The refund is delayed.", actionID: saveAction,
            capture: saveCapture, destination: .legacyLocal
        )

        let followUpAction = UUID()
        fixture.currentActionID = followUpAction
        let followUpCapture = fixture.capture()
        #expect(try controller.draftFacts(
            for: "Ask for an update.", actionID: followUpAction,
            capture: followUpCapture, destination: .legacyLocal
        )?.texts == ["The refund is delayed."])
        #expect(try controller.draftFacts(
            for: "Please follow up on this.", actionID: followUpAction,
            capture: followUpCapture, destination: .legacyLocal
        )?.texts == ["The refund is delayed."])
        #expect(try controller.draftFacts(
            for: "Ask for an update on the order.", actionID: followUpAction,
            capture: followUpCapture, destination: .legacyLocal
        ) == nil)
        #expect(try controller.draftFacts(
            for: "Ask for an update.", actionID: followUpAction,
            capture: followUpCapture, destination: .deepSeek
        ) == nil)

        _ = try controller.rememberExplicitFact(
            "The conference is next week.", actionID: followUpAction,
            capture: followUpCapture, destination: .legacyLocal
        )
        #expect(throws: ComposeSessionMemoryContextError.ambiguousFollowUp) {
            try controller.draftFacts(
                for: "Ask for an update.", actionID: followUpAction,
                capture: followUpCapture, destination: .legacyLocal
            )
        }

        fixture.adapter.documentID = .init(rawValue: "document-b")!
        fixture.adapter.navigationRevision = UUID()
        let otherAction = UUID()
        fixture.currentActionID = otherAction
        #expect(try controller.draftFacts(
            for: "Ask for an update.", actionID: otherAction,
            capture: fixture.capture(), destination: .legacyLocal
        ) == nil)
    }

    @Test
    func explicitVoiceCommandsDoNotConsumeOrdinaryMessageText() {
        #expect(ComposeSessionMemoryCommand.parse("Remember that this project uses SwiftUI.")
                == .remember(fact: "this project uses SwiftUI."))
        #expect(ComposeSessionMemoryCommand.parse(
            "Cadence, correct memory the refund was approved should be the refund is delayed."
        ) == .correct(oldFact: "the refund was approved", newFact: "the refund is delayed."))
        #expect(ComposeSessionMemoryCommand.parse(
            "Cadence correct memory, the refund was approved should be the refund is delayed."
        ) == .correct(oldFact: "the refund was approved", newFact: "the refund is delayed."))
        #expect(ComposeSessionMemoryCommand.parse("What do you remember for this document?")
                == .inspectCurrentDocument)
        #expect(ComposeSessionMemoryCommand.parse("Forget this document.")
                == .forgetCurrentDocument)
        #expect(ComposeSessionMemoryCommand.parse("Tell Alex to remember that this uses SwiftUI") == nil)
        #expect(ComposeSessionMemoryCommand.parse(
            "Tell Alex the refund was approved should be the refund is delayed"
        ) == nil)
        #expect(ComposeSessionMemoryCommand.parse("\"Remember that this uses SwiftUI\"") == nil)
        #expect(ComposeSessionMemoryCommand.parse("Remember that") == nil)
    }

    @Test
    func explicitSessionFactsStayInCurrentDocumentAndCanBeForgotten() throws {
        let fixture = ActionScopeFixture()
        let consent = ComposeSessionMemoryConsentController(
            preferences: .init(isEnabled: true, textEditAllowed: true, rememberExplicitFacts: true),
            enabled: { true }, now: { fixture.now }
        )
        let controller = try ComposeSessionMemoryContextController(
            consent: consent, adapter: fixture.adapter,
            enabled: { fixture.enabled }, permissions: { fixture.permissions },
            actionIsCurrent: { actionID in fixture.currentActionID == actionID },
            targetIsCurrent: { _ in fixture.targetCurrent }, now: { fixture.now }
        )
        let actionA = UUID()
        fixture.currentActionID = actionA
        let captureA = fixture.capture()
        let saved = try controller.rememberExplicitFact(
            "The refund is pending.", actionID: actionA, capture: captureA, destination: .legacyLocal
        )
        #expect(saved.kind == .explicitUserFact)
        #expect(try controller.inspectCurrentDocument(
            actionID: actionA, capture: captureA, destination: .legacyLocal
        ).map(\.text) == ["The refund is pending."])

        fixture.adapter.documentID = .init(rawValue: "document-b")!
        fixture.adapter.navigationRevision = UUID()
        let actionB = UUID()
        fixture.currentActionID = actionB
        let captureB = fixture.capture()
        #expect(try controller.inspectCurrentDocument(
            actionID: actionB, capture: captureB, destination: .legacyLocal
        ).isEmpty)
        #expect(throws: ComposeSessionMemoryContextError.unavailable) {
            try controller.inspectCurrentDocument(
                actionID: actionA, capture: captureA, destination: .legacyLocal
            )
        }

        fixture.adapter.documentID = .init(rawValue: "document-a")!
        fixture.adapter.navigationRevision = UUID()
        let returnAction = UUID()
        fixture.currentActionID = returnAction
        let returnCapture = fixture.capture()
        #expect(try controller.inspectCurrentDocument(
            actionID: returnAction, capture: returnCapture, destination: .legacyLocal
        ).map(\.id) == [saved.id])
        try controller.forgetCurrentDocument(
            actionID: returnAction, capture: returnCapture, destination: .legacyLocal
        )
        #expect(try controller.inspectCurrentDocument(
            actionID: returnAction, capture: returnCapture, destination: .legacyLocal
        ).isEmpty)
        consent.updatePreferences(.init(isEnabled: true, textEditAllowed: true))
        #expect(throws: ComposeSessionMemoryContextError.retentionNotAllowed) {
            try controller.rememberExplicitFact(
                "Do not save", actionID: returnAction, capture: returnCapture, destination: .legacyLocal
            )
        }
        controller.endSession()
    }

    @Test
    func chosenDraftIsOptInScopedAndNeverBecomesAFact() throws {
        let fixture = ActionScopeFixture()
        let consent = ComposeSessionMemoryConsentController(
            preferences: .init(isEnabled: true, textEditAllowed: true, rememberChosenDrafts: true),
            enabled: { true }, now: { fixture.now }
        )
        let controller = try ComposeSessionMemoryContextController(
            consent: consent, adapter: fixture.adapter,
            enabled: { fixture.enabled }, permissions: { fixture.permissions },
            actionIsCurrent: { fixture.currentActionID == $0 },
            targetIsCurrent: { _ in fixture.targetCurrent }, now: { fixture.now }
        )
        let action = UUID()
        fixture.currentActionID = action
        let capture = fixture.capture()
        controller.begin(actionID: action, capture: capture, destination: .legacyLocal)
        let draftID = UUID()
        #expect(!controller.rememberChosenDraft(
            "Draft to copy", draftID: draftID, selection: .copied,
            actionID: action, capture: capture, destination: .deepSeek
        ))
        #expect(controller.rememberChosenDraft(
            "Draft to copy", draftID: draftID, selection: .copied,
            actionID: action, capture: capture, destination: .legacyLocal
        ))
        #expect(!controller.rememberChosenDraft(
            "Draft to copy", draftID: draftID, selection: .copied,
            actionID: action, capture: capture, destination: .legacyLocal
        ))
        #expect(try controller.inspectCurrentDocument(
            actionID: action, capture: capture, destination: .legacyLocal
        ).isEmpty)
        #expect(try controller.draftFacts(
            for: "Write another reply", actionID: action, capture: capture,
            destination: .legacyLocal
        ) == nil)
        let notice = try controller.perform(
            .inspectCurrentDocument, actionID: action, capture: capture,
            destination: .legacyLocal
        )
        #expect(notice.detail.contains("Copied draft (delivery not confirmed): Draft to copy"))

        fixture.adapter.documentID = .init(rawValue: "document-b")!
        fixture.adapter.navigationRevision = UUID()
        let otherAction = UUID()
        fixture.currentActionID = otherAction
        let otherCapture = fixture.capture()
        #expect(try controller.perform(
            .inspectCurrentDocument, actionID: otherAction, capture: otherCapture,
            destination: .legacyLocal
        ).detail == "Nothing is remembered for this document.")
        #expect(!controller.rememberChosenDraft(
            "Draft to copy", draftID: UUID(), selection: .inserted,
            actionID: action, capture: capture, destination: .legacyLocal
        ))

        fixture.adapter.documentID = .init(rawValue: "document-a")!
        fixture.adapter.navigationRevision = UUID()
        let returnAction = UUID()
        fixture.currentActionID = returnAction
        let returnCapture = fixture.capture()
        #expect(try controller.perform(
            .inspectCurrentDocument, actionID: returnAction, capture: returnCapture,
            destination: .legacyLocal
        ).detail.contains("Draft to copy"))
        controller.updatePreferences(.init(isEnabled: true, textEditAllowed: true))
        #expect(try controller.perform(
            .inspectCurrentDocument, actionID: returnAction, capture: returnCapture,
            destination: .legacyLocal
        ).detail == "Nothing is remembered for this document.")
    }

    @Test
    func disabledOrUntrustedActionNeverQueriesTheAdapter() throws {
        let fixture = ActionScopeFixture()
        fixture.enabled = false
        let scope = try fixture.makeScope()
        #expect(scope.begin(actionID: UUID(), capture: fixture.capture()) == nil)
        #expect(fixture.adapter.captureCount == 0)

        fixture.enabled = true
        fixture.permissions.accessibility = false
        #expect(scope.begin(actionID: UUID(), capture: fixture.capture()) == nil)
        #expect(fixture.adapter.captureCount == 0)

        fixture.permissions.accessibility = true
        fixture.targetCurrent = false
        #expect(scope.begin(actionID: UUID(), capture: fixture.capture()) == nil)
        #expect(fixture.adapter.captureCount == 0)

        fixture.targetCurrent = true
        fixture.currentActionID = UUID()
        #expect(scope.begin(actionID: UUID(), capture: fixture.capture()) == nil)
        #expect(fixture.adapter.captureCount == 0)
    }

    @Test
    func actionScopeRequiresExactTargetProcessAndCapture() throws {
        let fixture = ActionScopeFixture()
        let scope = try fixture.makeScope()
        let actionID = UUID()
        let capture = fixture.capture()
        let access = try #require(scope.begin(actionID: actionID, capture: capture))
        #expect(access.contextAction.captureID == capture.id)
        #expect(access.contextAction.opaqueSurfaceID == access.conversation.memoryKey.opaqueValue)
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == access)
        #expect(scope.currentAccess(actionID: UUID(), capture: capture) == nil)
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == access)
        let newerCapture = fixture.capture()
        let newerAction = UUID()
        fixture.currentActionID = newerAction
        let newer = try #require(scope.begin(actionID: newerAction, capture: newerCapture))
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == nil)
        #expect(scope.currentAccess(actionID: newerAction, capture: newerCapture) == newer)
        #expect(scope.begin(actionID: actionID, capture: capture) == nil)
        #expect(scope.currentAccess(actionID: newerAction, capture: newerCapture) == newer)
        fixture.currentActionID = nil

        let changedProcess = fixture.capture(process: .init(
            processIdentifier: fixture.adapter.process.processIdentifier + 1,
            bundleIdentifier: fixture.adapter.process.bundleIdentifier,
            bundleURL: fixture.adapter.process.bundleURL,
            incarnation: UUID(), launchDate: fixture.adapter.process.launchDate
        ))
        #expect(scope.begin(actionID: UUID(), capture: changedProcess) == nil)
        let wrongApp = fixture.capture(targetBundle: "com.example.Other")
        #expect(scope.begin(actionID: UUID(), capture: wrongApp) == nil)
    }

    @Test
    func reviewedDraftRebindKeepsPinnedDocumentWithoutRecapturingFocus() throws {
        let fixture = ActionScopeFixture()
        let scope = try fixture.makeScope()
        let oldAction = UUID()
        fixture.currentActionID = oldAction
        let capture = fixture.capture()
        let original = try #require(scope.begin(actionID: oldAction, capture: capture))
        #expect(fixture.adapter.captureCount == 1)

        let newAction = UUID()
        fixture.currentActionID = newAction
        let rebound = try #require(scope.rebind(
            from: oldAction, to: newAction, capture: capture
        ))
        #expect(fixture.adapter.captureCount == 1)
        #expect(rebound.conversation.memoryKey == original.conversation.memoryKey)
        #expect(rebound.contextAction.actionID == newAction)
        #expect(!scope.isCurrent(original))
        #expect(scope.currentAccess(actionID: newAction, capture: capture) == rebound)
    }

    @Test
    func reviewedDraftRebindRejectsChangedDocumentOrWindowRevision() throws {
        let fixture = ActionScopeFixture()
        let scope = try fixture.makeScope()
        let oldAction = UUID()
        fixture.currentActionID = oldAction
        let capture = fixture.capture()
        #expect(scope.begin(actionID: oldAction, capture: capture) != nil)
        fixture.currentActionID = UUID()
        fixture.adapter.documentID = .init(rawValue: "document-b")!
        #expect(scope.rebind(
            from: oldAction, to: fixture.currentActionID!, capture: capture
        ) == nil)
        #expect(fixture.adapter.captureCount == 1)

        fixture.adapter.documentID = .init(rawValue: "document-a")!
        fixture.currentActionID = oldAction
        #expect(scope.begin(actionID: oldAction, capture: capture) != nil)
        fixture.adapter.navigationRevision = UUID()
        fixture.currentActionID = UUID()
        #expect(scope.rebind(
            from: oldAction, to: fixture.currentActionID!, capture: capture
        ) == nil)
        #expect(fixture.adapter.captureCount == 2)
    }

    @Test
    func consentExpiryRevocationAndTargetSwitchInvalidateAccess() throws {
        let fixture = ActionScopeFixture()
        let scope = try fixture.makeScope()
        let capture = fixture.capture()
        let actionID = UUID()
        #expect(scope.begin(actionID: actionID, capture: capture) != nil)
        fixture.currentActionID = UUID()
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == nil)
        fixture.currentActionID = nil
        #expect(scope.begin(actionID: actionID, capture: capture) != nil)
        fixture.targetCurrent = false
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == nil)

        fixture.targetCurrent = true
        #expect(scope.begin(actionID: actionID, capture: capture) != nil)
        fixture.policy.revision = UUID()
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == nil)

        #expect(scope.begin(actionID: actionID, capture: capture) != nil)
        let savedGrants = fixture.policy.captureGrants
        fixture.policy.captureGrants = []
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == nil)
        fixture.policy.captureGrants = savedGrants
        #expect(scope.begin(actionID: actionID, capture: capture) != nil)
        fixture.permissions.accessibility = false
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == nil)
        fixture.permissions.accessibility = true
        #expect(scope.begin(actionID: actionID, capture: capture) != nil)
        fixture.now = fixture.now.addingTimeInterval(2_000)
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == nil)
        fixture.now = Date(timeIntervalSince1970: 50_000)
        #expect(scope.begin(actionID: actionID, capture: capture) != nil)
        scope.revoke()
        #expect(scope.currentAccess(actionID: actionID, capture: capture) == nil)
        #expect(scope.begin(actionID: UUID(), capture: fixture.capture()) == nil)
    }

    @Test
    func verifiedActionAndSessionStoreKeepDocumentsIsolated() throws {
        let fixture = ActionScopeFixture()
        let scope = try fixture.makeScope()
        let store = ScribeSessionMemoryStore(
            identityResolver: scope.identityResolver,
            actionIsCurrent: { scope.isCurrent($0) },
            policy: { fixture.policy }, permissions: { fixture.permissions }, clock: { fixture.now }
        )
        let firstCapture = fixture.capture()
        let first = try #require(scope.begin(actionID: UUID(), capture: firstCapture))
        let write = ScribeSessionMemoryWrite(
            text: "Synthetic refund pending", topics: ["refund"],
            provenance: .explicitUser(statementID: UUID()), expiresAt: fixture.now + 600
        )
        let token = try store.beginWrite(write, for: first)
        #expect(try store.completeWrite(token, outcome: .completed, for: first) != nil)
        scope.clear(actionID: first.contextAction.actionID)
        #expect(throws: ScribeSessionMemoryError.actionNoLongerCurrent) {
            try store.beginRetrieval(.init(topics: ["refund"]), for: first)
        }

        let sameDocumentCapture = fixture.capture()
        let sameDocument = try #require(scope.begin(actionID: UUID(), capture: sameDocumentCapture))
        #expect(sameDocument.conversation.memoryKey == first.conversation.memoryKey)
        #expect(throws: ScribeSessionMemoryError.actionNoLongerCurrent) {
            try store.beginRetrieval(.init(topics: ["refund"]), for: first)
        }
        let pendingRead = try store.beginRetrieval(.init(topics: ["refund"]), for: sameDocument)
        let pendingWrite = try store.beginWrite(.init(
            text: "Must not be saved after action replacement", topics: ["refund"],
            provenance: .explicitUser(statementID: UUID()), expiresAt: fixture.now + 600
        ), for: sameDocument)
        let newerSameDocumentCapture = fixture.capture()
        let newerSameDocument = try #require(scope.begin(actionID: UUID(), capture: newerSameDocumentCapture))
        #expect(newerSameDocument.conversation.memoryKey == sameDocument.conversation.memoryKey)
        #expect(throws: ScribeSessionMemoryError.unknownOperation) {
            try store.completeRetrieval(pendingRead, for: sameDocument)
        }
        #expect(throws: ScribeSessionMemoryError.unknownOperation) {
            try store.completeWrite(pendingWrite, outcome: .completed, for: sameDocument)
        }
        let freshRead = try store.beginRetrieval(.init(topics: ["refund"]), for: newerSameDocument)
        #expect(try store.completeRetrieval(freshRead, for: newerSameDocument).facts.map(\.text)
                == ["Synthetic refund pending"])

        fixture.adapter.documentID = .init(rawValue: "document-b")!
        fixture.adapter.navigationRevision = UUID()
        #expect(scope.currentAccess(actionID: newerSameDocument.contextAction.actionID,
                                    capture: newerSameDocumentCapture) == nil)
        #expect(!scope.identityResolver.revalidate(first.conversation, for: first.currentBinding))
        #expect(throws: ScribeSessionMemoryError.actionNoLongerCurrent) {
            try store.beginRetrieval(.init(topics: ["refund"]), for: first)
        }
        let secondCapture = fixture.capture()
        let second = try #require(scope.begin(actionID: UUID(), capture: secondCapture))
        let secondRead = try store.beginRetrieval(.init(topics: ["refund"]), for: second)
        #expect(try store.completeRetrieval(secondRead, for: second).facts.isEmpty)

        fixture.adapter.documentID = .init(rawValue: "document-a")!
        fixture.adapter.navigationRevision = UUID()
        let returnCapture = fixture.capture()
        let returned = try #require(scope.begin(actionID: UUID(), capture: returnCapture))
        #expect(returned.conversation.memoryKey == first.conversation.memoryKey)
        let returnRead = try store.beginRetrieval(.init(topics: ["refund"]), for: returned)
        #expect(try store.completeRetrieval(returnRead, for: returned).facts.map(\.text) == ["Synthetic refund pending"])
    }
}

@MainActor
private final class ActionScopeFixture {
    let adapter = ActionScopeFixtureAdapter()
    var enabled = true
    var targetCurrent = true
    var currentActionID: UUID?
    var permissions = ScribeContextPlatformPermissions(accessibility: true, screenRecording: false)
    var policy = ScribeContextPolicySnapshot()
    var now = Date(timeIntervalSince1970: 50_000)

    init() {
        let window = ScribeContextGrantWindow(
            acceptedAt: now - 100, expiresAt: now + 1_000
        )
        policy.isEnabled = true
        policy.captureGrants = [.init(
            id: UUID(), scope: .application(bundleIdentifier: adapter.process.bundleIdentifier),
            categories: [.sessionMemory], window: window
        )]
        policy.retentionGrants = [.init(
            id: UUID(), scope: .application(bundleIdentifier: adapter.process.bundleIdentifier),
            categories: [.sessionMemory], destination: .sessionMemory,
            maximumRetentionInterval: 1_000, window: window
        )]
    }

    func makeScope() throws -> ScribeConversationActionScope {
        try ScribeConversationActionScope(
            adapter: adapter, enabled: { self.enabled }, policy: { self.policy },
            permissions: { self.permissions },
            actionIsCurrent: { actionID in self.currentActionID.map { $0 == actionID } ?? true },
            targetIsCurrent: { _ in self.targetCurrent },
            now: { self.now }
        )
    }

    func capture(
        process: ApplicationProcessIdentity? = nil,
        targetBundle: String? = ActionScopeFixtureAdapter.bundleIdentifier
    ) -> ScribeContextSnapshot {
        let captureID = UUID()
        let process = process ?? adapter.process
        return .init(
            id: captureID,
            target: .init(processIdentifier: process.processIdentifier, bundleIdentifier: targetBundle),
            scope: .none, selectedText: "", verificationToken: UUID().uuidString,
            applicationTarget: .init(id: captureID, process: process,
                                     identityRevision: 1, captureRevision: 1,
                                     source: .scribeAccessibility)
        )
    }
}

@MainActor
private final class ActionScopeFixtureAdapter: ScribeConversationBindingCapturing {
    static let bundleIdentifier = "com.apple.TextEdit"
    let registration = ScribeConversationAdapterRegistration(
        adapterID: .init(rawValue: "textedit-test-adapter")!, schemaVersion: 1,
        source: .nativeIntegration, hostBundleIdentifier: bundleIdentifier,
        applicationID: .init(rawValue: bundleIdentifier)!
    )
    let process = ApplicationProcessIdentity(
        processIdentifier: 77, bundleIdentifier: bundleIdentifier,
        bundleURL: URL(fileURLWithPath: "/Applications/TextEdit.app"),
        incarnation: UUID(), launchDate: Date(timeIntervalSince1970: 49_000)
    )
    let window = UUID()
    var navigationRevision = UUID()
    var documentID = ScribeConversationStableID(rawValue: "document-a")!
    var captureCount = 0

    func captureBinding(actionID: UUID, process: ApplicationProcessIdentity) -> ScribeConversationActionBinding? {
        captureCount += 1
        guard process == self.process else { return nil }
        return .init(actionID: actionID, process: process, windowIncarnation: window,
                     tabIncarnation: nil, navigationRevision: navigationRevision)
    }

    func evidence(for binding: ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence? {
        guard binding.process == process, binding.windowIncarnation == window,
              binding.navigationRevision == navigationRevision else { return nil }
        return .init(
            adapterID: registration.adapterID, schemaVersion: registration.schemaVersion,
            source: .nativeIntegration, binding: binding,
            confidence: .verifiedStableIdentifiers, privacyState: .regular,
            applicationID: registration.applicationID,
            accountID: .init(rawValue: "synthetic-user"),
            workspaceID: .notApplicable, projectID: .notApplicable,
            conversationID: documentID
        )
    }
}
