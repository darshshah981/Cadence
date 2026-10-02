import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeDraftRevisionStoreTests {
    @Test
    func completionBindsToCurrentVersionAndRetainsOriginalRequestSeparately() throws {
        let store = ScribeDraftRevisionStore()
        let origin = makeOrigin()
        let session = store.start(origin: origin, originalSpokenRequest: "Tell Maya the preview is ready.", initialDraft: "Maya, the preview is ready.")
        let token = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "Make that warmer.")
        let revised = try store.completeRevision(token, refinedDraft: "Maya, the preview is ready whenever you have a moment.")

        #expect(revised.originalSpokenRequest == "Tell Maya the preview is ready.")
        #expect(revised.currentVersion.source == .voiceRefinement)
        #expect(revised.currentVersion.revisionInstruction == token.instruction)
        #expect(revised.versions.count == 2)
    }

    @Test
    func staleAndWrongBaseCompletionsCannotOverwriteAcceptedDraft() throws {
        let store = ScribeDraftRevisionStore()
        let origin = makeOrigin()
        let session = store.start(origin: origin, originalSpokenRequest: "Original", initialDraft: "First")
        let first = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "First revision")
        let late = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "Late revision")
        let accepted = try store.completeRevision(first, refinedDraft: "Second")

        #expect(throws: ScribeDraftRevisionError.staleCompletion) {
            try store.completeRevision(late, refinedDraft: "Must not win")
        }
        #expect(try store.session(id: session.id, origin: origin).currentVersion == accepted.currentVersion)
        #expect(throws: ScribeDraftRevisionError.wrongBaseVersion) {
            try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "Old base")
        }
    }

    @Test
    func cancellationAndFailureDiscardOnlyPendingRevision() throws {
        let store = ScribeDraftRevisionStore()
        let origin = makeOrigin()
        let session = store.start(origin: origin, originalSpokenRequest: "Original", initialDraft: "Usable draft")
        let token = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "Make warmer")

        let retained = try store.cancelRevision(token)
        #expect(retained.currentVersion.text == "Usable draft")
        #expect(retained.versions.count == 1)
        #expect(throws: ScribeDraftRevisionError.unknownRevision) {
            try store.completeRevision(token, refinedDraft: "Late output")
        }

        let failureToken = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: retained.currentVersion.id, revisionUtterance: "Try again")
        #expect(try store.failRevision(failureToken).currentVersion.text == "Usable draft")
    }

    @Test
    func undoSupportsMultipleVersionsAndNewRevisionDropsAbandonedFuture() throws {
        let store = ScribeDraftRevisionStore(maximumVersionsPerSession: 4)
        let origin = makeOrigin()
        var session = store.start(origin: origin, originalSpokenRequest: "Original", initialDraft: "v0")
        let first = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "v1")
        session = try store.completeRevision(first, refinedDraft: "v1")
        let second = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "v2")
        session = try store.completeRevision(second, refinedDraft: "v2")

        session = try store.undo(sessionID: session.id, origin: origin)
        session = try store.undo(sessionID: session.id, origin: origin)
        #expect(session.currentVersion.text == "v0")
        let branch = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "branch")
        session = try store.completeRevision(branch, refinedDraft: "branch")
        #expect(session.versions.map(\.text) == ["v0", "branch"])
        #expect(session.currentVersion.text == "branch")
    }

    @Test
    func boundedHistoryDropsOldestVersionsWithoutChangingCurrentDraft() throws {
        let store = ScribeDraftRevisionStore(maximumVersionsPerSession: 2)
        let origin = makeOrigin()
        var session = store.start(origin: origin, originalSpokenRequest: "Original", initialDraft: "v0")
        for value in ["v1", "v2"] {
            let token = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: value)
            session = try store.completeRevision(token, refinedDraft: value)
        }
        #expect(session.versions.map(\.text) == ["v1", "v2"])
        #expect(session.currentVersion.text == "v2")
    }

    @Test
    func captureTargetAndProviderChangesCannotAccessOrRefineSession() throws {
        let store = ScribeDraftRevisionStore()
        let origin = makeOrigin()
        let session = store.start(origin: origin, originalSpokenRequest: "Original", initialDraft: "Draft")
        let changedCapture = ScribeDraftRevisionOrigin(actionID: origin.actionID, captureID: UUID(), target: origin.target, providerActionIdentity: origin.providerActionIdentity)
        let changedTarget = ScribeDraftRevisionOrigin(actionID: origin.actionID, captureID: origin.captureID, target: .init(processIdentifier: 9, bundleIdentifier: "other.app"), providerActionIdentity: origin.providerActionIdentity)
        let changedProvider = ScribeDraftRevisionOrigin(actionID: origin.actionID, captureID: origin.captureID, target: origin.target, providerActionIdentity: .init(configurationID: UUID(), libraryRevision: 2, selectedModelID: "other"))

        for mismatched in [changedCapture, changedTarget, changedProvider] {
            #expect(throws: ScribeDraftRevisionError.originMismatch) {
                try store.beginRevision(sessionID: session.id, origin: mismatched, baseVersionID: session.currentVersion.id, revisionUtterance: "Change")
            }
        }
    }

    private func makeOrigin() -> ScribeDraftRevisionOrigin {
        .init(
            actionID: UUID(), captureID: UUID(),
            target: .init(processIdentifier: 7, bundleIdentifier: "com.example.Editor"),
            providerActionIdentity: .init(configurationID: UUID(), libraryRevision: 1, selectedModelID: "model-a")
        )
    }
}
