import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeCoordinatorTests {
    @Test
    func durableVoiceFactRequiresVisibleCurrentActionConfirmation() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not generate")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Cadence, remember for later that this project uses SwiftUI.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let review: ComposePersistentMemoryReviewProposal
        guard case let .persistentMemoryProposal(proposal) = fixture.coordinator.state else {
            Issue.record("Expected an exact durable-memory proposal")
            return
        }
        review = proposal
        #expect(review.fact == "this project uses SwiftUI.")
        #expect(memory.microphoneWasLiveAtBegin)
        #expect(memory.prepared?.token.id == review.proposalID)
        #expect(memory.confirmed == nil)
        #expect(await provider.requests.isEmpty)
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(fixture.coordinator.literalRecoveryTranscript == nil)
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == nil)
        #expect(fixture.coordinator.unpolishedHistoryDraft() == nil)
        fixture.coordinator.useLiteralTranscript()
        #expect(fixture.coordinator.state == .persistentMemoryProposal(review))
        await #expect(throws: ScribeCoordinatorError.invalidState) {
            try await fixture.coordinator.insertUnpolishedResult()
        }

        #expect(!fixture.coordinator.confirmPersistentMemoryProposal(id: UUID()))
        #expect(memory.confirmed == nil)
        #expect(fixture.coordinator.confirmPersistentMemoryProposal(id: review.proposalID))
        #expect(memory.confirmed?.token.id == review.proposalID)
        #expect(!fixture.coordinator.confirmPersistentMemoryProposal(id: review.proposalID))
        #expect(memory.confirmationCount == 1)
        guard case let .memoryNotice(notice) = fixture.coordinator.state else {
            Issue.record("Expected a saved-memory notice")
            return
        }
        #expect(notice.requestID == review.requestID)
    }

    @Test
    func cancelledDurableProposalCannotBeSavedLater() async throws {
        let fixture = ScribeCoordinatorFixture(
            engine: StubScribeTranscriptionEngine(text:
                "Cadence, remember for later that the release uses SwiftUI.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        fixture.coordinator.installPersistentMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        guard case let .persistentMemoryProposal(review) = fixture.coordinator.state else {
            Issue.record("Expected durable-memory proposal")
            return
        }
        await fixture.coordinator.cancel()
        #expect(!fixture.coordinator.confirmPersistentMemoryProposal(id: review.proposalID))
        #expect(memory.confirmed == nil)
        #expect(memory.clearedActionIDs.contains(review.requestID))
    }

    @Test
    func revokedDurableProposalFailsWithoutSaving() async throws {
        let fixture = ScribeCoordinatorFixture(
            engine: StubScribeTranscriptionEngine(text:
                "Cadence, remember for later that the release uses SwiftUI.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        fixture.coordinator.installPersistentMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        guard case let .persistentMemoryProposal(review) = fixture.coordinator.state else {
            Issue.record("Expected durable-memory proposal")
            return
        }
        memory.acceptsExplicitSaves = false
        #expect(!fixture.coordinator.confirmPersistentMemoryProposal(id: review.proposalID))
        #expect(memory.confirmed == nil)
        #expect(fixture.coordinator.failure == .persistentMemoryUnavailable)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
    }

    @Test
    func durableInspectShowsCurrentFactsWithoutGenerationOrInsertion() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not generate")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Cadence, what do you remember for this document?")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.seedSavedFact("The release uses SwiftUI.")
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        guard case let .memoryNotice(notice) = fixture.coordinator.state else {
            Issue.record("Expected saved-memory inspection")
            return
        }
        #expect(notice.detail.contains("The release uses SwiftUI."))
        #expect(await provider.requests.isEmpty)
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(fixture.coordinator.literalRecoveryTranscript == nil)
    }

    @Test
    func durableCorrectionReviewsBothFactsAndRequiresCurrentConfirmation() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not generate")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Cadence, correct saved memory the release uses UIKit should be the release uses SwiftUI.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.seedSavedFact("the release uses UIKit")
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        guard case let .persistentMemoryProposal(review) = fixture.coordinator.state else {
            Issue.record("Expected correction review")
            return
        }
        #expect(review.replacingFact == "the release uses UIKit")
        #expect(review.fact == "the release uses SwiftUI.")
        #expect(!fixture.coordinator.confirmPersistentMemoryProposal(id: UUID()))
        #expect(memory.confirmed == nil)
        #expect(fixture.coordinator.confirmPersistentMemoryProposal(id: review.proposalID))
        #expect(memory.confirmed?.record.text == "the release uses SwiftUI.")
        #expect(await provider.requests.isEmpty)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func durableForgetRequiresReviewAndCannotBeConfirmedTwice() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not generate")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Cadence, forget saved facts for this document")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.seedSavedFact("The release uses SwiftUI.")
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        guard case let .persistentMemoryForgetProposal(review) = fixture.coordinator.state else {
            Issue.record("Expected forget review")
            return
        }
        #expect(review.factCount == 1)
        #expect(!fixture.coordinator.confirmPersistentMemoryForgetProposal(id: UUID()))
        #expect(!memory.forgotten)
        #expect(fixture.coordinator.confirmPersistentMemoryForgetProposal(id: review.proposalID))
        #expect(memory.forgotten)
        #expect(!fixture.coordinator.confirmPersistentMemoryForgetProposal(id: review.proposalID))
        #expect(await provider.requests.isEmpty)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func cancelledDurableForgetCannotDeleteLater() async throws {
        let fixture = ScribeCoordinatorFixture(
            engine: StubScribeTranscriptionEngine(text:
                "Cadence, forget saved facts for this document")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.seedSavedFact("The release uses SwiftUI.")
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        guard case let .persistentMemoryForgetProposal(review) = fixture.coordinator.state else {
            Issue.record("Expected forget review")
            return
        }
        await fixture.coordinator.cancel()
        #expect(!fixture.coordinator.confirmPersistentMemoryForgetProposal(id: review.proposalID))
        #expect(!memory.forgotten)
        #expect(memory.savedFacts.count == 1)
    }

    @Test
    func optedInDurableFactInformsOnlyLocalDraftAndIsNotSavedToHistory() async throws {
        let provider = CapturingScribeProvider(resultText: "The SwiftUI project is on track.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Write an update about the SwiftUI project.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("The SwiftUI project is on track.")
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let requests = await provider.requests
        #expect(requests.count == 1)
        #expect(requests.first?.input.userMessage.contains("The SwiftUI project is on track.") == true)
        #expect(memory.microphoneWasLiveAtBegin)
        #expect(fixture.coordinator.reviewedResult?.text == "The SwiftUI project is on track.")
        #expect(fixture.coordinator.sessionFactsReviewSource?.kind == .saved)
        #expect(fixture.coordinator.sessionFactsReviewSource?.facts == ["The SwiftUI project is on track."])
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(!fixture.coordinator.canRefineReviewedDraft)
    }

    @Test
    func optedInDurableFactNeverEntersCloudProviderRequest() async throws {
        let provider = CapturingScribeProvider(resultText: "Here is the project update.")
        let action = ScribeProviderActionSnapshot(provider: provider, destination: .deepSeek)
        let fixture = ScribeCoordinatorFixture(
            providerActionResolver: { action },
            engine: StubScribeTranscriptionEngine(text:
                "Write an update about the SwiftUI project.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("SYNTHETIC PRIVATE CANARY: the SwiftUI project is delayed.")
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let requests = await provider.requests
        #expect(requests.count == 1)
        #expect(requests.first?.input.userMessage.contains("SYNTHETIC PRIVATE CANARY") == false)
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        #expect(fixture.coordinator.reviewedHistoryDraft() != nil)
    }

    @Test
    func forgottenDurableFactInvalidatesAnInFlightDraftBeforeReview() async throws {
        let provider = SuspendedMemoryDraftProvider()
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Ask for an update on the SwiftUI project.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("The SwiftUI project is delayed.")
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        let finishing = Task { await fixture.coordinator.finishRecording() }
        await provider.waitForRequest()
        memory.savedFacts.removeAll()
        await provider.complete()
        await finishing.value

        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func changedDurableFactCannotBeCopiedFromReviewedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "The SwiftUI project is delayed."),
            engine: StubScribeTranscriptionEngine(text:
                "Write a project update about SwiftUI.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("The SwiftUI project is delayed.")
        fixture.coordinator.installPersistentMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult != nil)

        memory.savedFacts.removeAll()
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func changedDurableFactCannotBeInsertedFromReviewedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "The SwiftUI project is delayed."),
            engine: StubScribeTranscriptionEngine(text:
                "Write a project update about SwiftUI.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("The SwiftUI project is delayed.")
        fixture.coordinator.installPersistentMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult != nil)

        memory.savedFacts.removeAll()
        await #expect(throws: ScribeContextError.captureCleared) {
            try await fixture.coordinator.insertReviewedResult()
        }
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func durableMemoryRevocationImmediatelyClearsReviewedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "The SwiftUI project is delayed."),
            engine: StubScribeTranscriptionEngine(text:
                "Write a project update about SwiftUI.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("The SwiftUI project is delayed.")
        fixture.coordinator.installPersistentMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult != nil)

        memory.permitsLocalDraftUse = false
        fixture.coordinator.persistentMemoryDidInvalidate()
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
    }

    @Test
    func individualSavedFactExclusionsAccumulateAndKeepRetryFactFree() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share a project update?")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Ask for an update on SwiftUI and the refund.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("The SwiftUI project is delayed.")
        memory.seedSavedFact("The refund is delayed.")
        fixture.coordinator.installPersistentMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let first = try #require(fixture.coordinator.sessionFactsReviewSource)
        #expect(first.kind == .saved)
        #expect(first.recordIDs.count == 2)
        #expect(await !fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: first.id, recordID: UUID()
        ))
        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: first.id, recordID: first.recordIDs[0]
        ))
        let second = try #require(fixture.coordinator.sessionFactsReviewSource)
        #expect(second.id != first.id)
        #expect(second.recordIDs == [first.recordIDs[1]])
        #expect(await provider.requests.count == 2)
        #expect(await !provider.requests[1].input.userMessage.contains("The SwiftUI project is delayed."))
        #expect(await provider.requests[1].input.userMessage.contains("The refund is delayed."))
        #expect(await !fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: first.id, recordID: first.recordIDs[1]
        ))

        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: second.id, recordID: second.recordIDs[0]
        ))
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        #expect(await provider.requests.count == 3)
        #expect(await !provider.requests[2].input.userMessage.contains("The SwiftUI project is delayed."))
        #expect(await !provider.requests[2].input.userMessage.contains("The refund is delayed."))
        #expect(fixture.coordinator.reviewedHistoryDraft() != nil)
        let readsAfterExclusion = memory.draftFactsCallCount
        await fixture.coordinator.retryGeneration()
        #expect(await provider.requests.count == 4)
        #expect(memory.draftFactsCallCount == readsAfterExclusion)
        #expect(await !provider.requests[3].input.userMessage.contains("The refund is delayed."))
    }

    @Test
    func mixedSessionAndSavedFactsCanBeOmittedIndependently() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share an update?")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Ask for an update on SwiftUI and the refund.")
        )
        let session = SessionMemoryLifecycleSpy(audio: fixture.audio)
        let sessionID = UUID()
        session.draftFactsToReturn = .init(
            recordIDs: [sessionID], texts: ["The SwiftUI project is delayed."]
        )
        let saved = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        saved.permitsLocalDraftUse = true
        saved.seedSavedFact("The refund is delayed.")
        fixture.coordinator.installSessionMemoryContext(session)
        fixture.coordinator.installPersistentMemoryContext(saved)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let first = try #require(fixture.coordinator.sessionFactsReviewSource)
        #expect(first.kind == .mixed)
        #expect(first.recordIDs.count == 2)
        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: first.id, recordID: first.recordIDs[1]
        ))
        let second = try #require(fixture.coordinator.sessionFactsReviewSource)
        #expect(second.kind == .session)
        #expect(second.recordIDs == [sessionID])
        #expect(session.startedActionID == second.id)
        #expect(await provider.requests.count == 2)
        #expect(await provider.requests[1].input.userMessage.contains("The SwiftUI project is delayed."))
        #expect(await !provider.requests[1].input.userMessage.contains("The refund is delayed."))

        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: second.id, recordID: sessionID
        ))
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        #expect(await provider.requests.count == 3)
        #expect(await !provider.requests[2].input.userMessage.contains("The SwiftUI project is delayed."))
        #expect(await !provider.requests[2].input.userMessage.contains("The refund is delayed."))
    }

    @Test
    func savedFactRegenerationAllowsOnlyThePinnedReviewControlFocus() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share a project update?")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Ask for an update on SwiftUI.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("The SwiftUI project is delayed.")
        fixture.coordinator.installPersistentMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let sourceID = try #require(fixture.coordinator.sessionFactsReviewSource?.id)

        fixture.context.shouldVerify = false
        #expect(await !fixture.coordinator.regenerateWithoutSessionFacts(id: sourceID))
        fixture.context.reviewControlFocusAllowed = true
        #expect(await fixture.coordinator.regenerateWithoutSessionFacts(id: sourceID))
        #expect(await provider.requests.count == 2)
        #expect(await !provider.requests[1].input.userMessage.contains("The SwiftUI project is delayed."))
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
    }

    @Test
    func changedSavedFactDuringRegenerationPreventsProviderDispatch() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share a project update?")
        let gate = RefinementDispatchGate()
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            providerDispatchAuthorization: { _ in await gate.authorize() },
            engine: StubScribeTranscriptionEngine(text:
                "Ask for an update on SwiftUI and the refund.")
        )
        let memory = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        memory.permitsLocalDraftUse = true
        memory.seedSavedFact("The SwiftUI project is delayed.")
        memory.seedSavedFact("The refund is delayed.")
        fixture.coordinator.installPersistentMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.sessionFactsReviewSource)

        let regeneration = Task {
            await fixture.coordinator.regenerateWithoutSessionFact(
                sourceID: source.id, recordID: source.recordIDs[1]
            )
        }
        await gate.waitUntilSuspended()
        memory.savedFacts.removeAll()
        memory.seedSavedFact("The SwiftUI project is now on track.")
        memory.seedSavedFact("The refund is delayed.")
        await gate.resume()
        #expect(await regeneration.value)
        #expect(await provider.requests.count == 1)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
    }

    @Test
    func omittingDuplicateFactRemovesBothSessionAndSavedCopies() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share a project update?")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Ask for an update on SwiftUI.")
        )
        let fact = "The SwiftUI project is delayed."
        let session = SessionMemoryLifecycleSpy(audio: fixture.audio)
        session.draftFactsToReturn = .init(recordIDs: [UUID()], texts: [fact])
        let saved = PersistentMemoryLifecycleSpy(audio: fixture.audio)
        saved.permitsLocalDraftUse = true
        saved.seedSavedFact(fact)
        fixture.coordinator.installSessionMemoryContext(session)
        fixture.coordinator.installPersistentMemoryContext(saved)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.sessionFactsReviewSource)
        #expect(source.kind == .mixed)
        #expect(source.facts == [fact, fact])

        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: source.id, recordID: source.recordIDs[0]
        ))
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        #expect(await provider.requests.count == 2)
        #expect(await !provider.requests[1].input.userMessage.contains(fact))
    }

    @Test
    func explicitCorrectionCommandBypassesWritingProviderAndInsertion() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not generate")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text:
                "Cadence, correct memory the refund was approved should be the refund is delayed.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.acceptsExplicitCommands = true
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(memory.performedCommand == .correct(
            oldFact: "the refund was approved", newFact: "the refund is delayed."
        ))
        #expect(await provider.requests.isEmpty)
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func sessionFactRevocationDropsLateGeneratedDraft() async throws {
        let provider = SuspendedMemoryDraftProvider()
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.draftFactsToReturn = .init(
            recordIDs: [UUID()], texts: ["The refund is delayed."]
        )
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        let finishing = Task { await fixture.coordinator.finishRecording() }
        await provider.waitForRequest()
        memory.draftFactsToReturn = nil
        await provider.complete()
        await finishing.value

        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func localDraftUsesFrozenSessionFactsAndRetryRejectsChangedFacts() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share an update on the refund?")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        let fact = ComposeSessionMemoryDraftFacts(
            recordIDs: [UUID()], texts: ["The refund is delayed."]
        )
        memory.draftFactsToReturn = fact
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let requests = await provider.requests
        #expect(requests.count == 1)
        #expect(requests.first?.input.userMessage.contains("The refund is delayed.") == true)
        #expect(fixture.coordinator.reviewedResult != nil)
        #expect(fixture.coordinator.sessionMemoryReviewStatus == "Session facts · This Mac")
        #expect(fixture.coordinator.sessionFactsReviewSource?.id == fixture.coordinator.reviewedResult?.requestID)
        #expect(fixture.coordinator.sessionFactsReviewSource?.facts == ["The refund is delayed."])
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(!fixture.coordinator.canRefineReviewedDraft)

        memory.draftFactsToReturn = .init(
            recordIDs: [UUID()], texts: ["The refund was approved."]
        )
        await fixture.coordinator.retryGeneration()
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        #expect(await provider.requests.count == 1)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.sessionMemoryReviewStatus == nil)
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func explicitRegenerationDiscardsFactDraftAndKeepsNewActionFactFreeOnRetry() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share an update on the refund?")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.draftFactsToReturn = .init(
            recordIDs: [UUID()], texts: ["The refund is delayed."]
        )
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let firstRequestID = try #require(fixture.coordinator.reviewedResult?.requestID)
        #expect(fixture.coordinator.sessionFactsReviewSource?.id == firstRequestID)
        #expect(await provider.requests.count == 1)
        #expect(await provider.requests.first?.input.userMessage.contains("The refund is delayed.") == true)
        #expect(memory.draftFactsCallCount >= 2)

        #expect(await !fixture.coordinator.regenerateWithoutSessionFacts(id: UUID()))
        #expect(fixture.coordinator.reviewedResult?.requestID == firstRequestID)
        fixture.context.shouldVerify = false
        #expect(await !fixture.coordinator.regenerateWithoutSessionFacts(id: firstRequestID))
        #expect(fixture.coordinator.reviewedResult?.requestID == firstRequestID)
        fixture.context.shouldVerify = true

        let readsBeforeRegeneration = memory.draftFactsCallCount
        #expect(await fixture.coordinator.regenerateWithoutSessionFacts(id: firstRequestID))
        let secondRequestID = try #require(fixture.coordinator.reviewedResult?.requestID)
        #expect(secondRequestID != firstRequestID)
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        #expect(memory.clearedActionIDs.contains(firstRequestID))
        #expect(await provider.requests.count == 2)
        #expect(await provider.requests[1].id == secondRequestID)
        #expect(await !provider.requests[1].input.userMessage.contains("The refund is delayed."))
        let readsAfterRegeneration = memory.draftFactsCallCount
        #expect(readsAfterRegeneration > readsBeforeRegeneration)
        #expect(fixture.coordinator.reviewedHistoryDraft() != nil)
        #expect(await !fixture.coordinator.regenerateWithoutSessionFacts(id: firstRequestID))

        await fixture.coordinator.retryGeneration()
        #expect(await provider.requests.count == 3)
        #expect(await !provider.requests[2].input.userMessage.contains("The refund is delayed."))
        #expect(memory.draftFactsCallCount == readsAfterRegeneration)
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func failedFactFreeRegenerationCannotRestoreOldFactBackedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: FailingRetryScribeProvider(),
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.draftFactsToReturn = .init(
            recordIDs: [UUID()], texts: ["The refund is delayed."]
        )
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let firstRequestID = try #require(fixture.coordinator.sessionFactsReviewSource?.id)
        #expect(await fixture.coordinator.regenerateWithoutSessionFacts(id: firstRequestID))
        #expect(fixture.coordinator.failure == .provider(.offline))
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func individualSessionFactExclusionsAccumulateAndRejectChangedSource() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share an update on the refund?")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        let refundID = UUID(), shipmentID = UUID(), updateID = UUID()
        let facts = ComposeSessionMemoryDraftFacts(
            recordIDs: [refundID, shipmentID, updateID],
            texts: ["The refund is delayed.", "The shipment arrived.", "An agent promised an update."]
        )
        memory.draftFactsToReturn = facts
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let firstSource = try #require(fixture.coordinator.sessionFactsReviewSource)
        #expect(firstSource.recordIDs == facts.recordIDs)
        #expect(await !fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: firstSource.id, recordID: UUID()
        ))
        #expect(fixture.coordinator.sessionFactsReviewSource == firstSource)

        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: firstSource.id, recordID: shipmentID
        ))
        let secondSource = try #require(fixture.coordinator.sessionFactsReviewSource)
        #expect(secondSource.id != firstSource.id)
        #expect(secondSource.recordIDs == [refundID, updateID])
        #expect(secondSource.facts == ["The refund is delayed.", "An agent promised an update."])
        #expect(await provider.requests.count == 2)
        #expect(await !provider.requests[1].input.userMessage.contains("The shipment arrived."))
        #expect(await provider.requests[1].input.userMessage.contains("The refund is delayed."))
        #expect(await !fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: firstSource.id, recordID: refundID
        ))

        await fixture.coordinator.retryGeneration()
        #expect(await provider.requests.count == 3)
        #expect(await !provider.requests[2].input.userMessage.contains("The shipment arrived."))

        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: secondSource.id, recordID: refundID
        ))
        let thirdSource = try #require(fixture.coordinator.sessionFactsReviewSource)
        #expect(thirdSource.recordIDs == [updateID])
        #expect(await provider.requests.count == 4)
        #expect(await !provider.requests[3].input.userMessage.contains("The shipment arrived."))
        #expect(await !provider.requests[3].input.userMessage.contains("The refund is delayed."))
        #expect(await provider.requests[3].input.userMessage.contains("An agent promised an update."))

        memory.draftFactsToReturn = .init(
            recordIDs: facts.recordIDs,
            texts: ["The refund is delayed.", "The shipment arrived.", "The agent cancelled the update."],
            localUseRevision: facts.localUseRevision
        )
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        await fixture.coordinator.cancel()
    }

    @Test
    func changedFactDuringIndividualRegenerationPreventsProviderDispatch() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share an update on the refund?")
        let gate = RefinementDispatchGate()
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            providerDispatchAuthorization: { _ in await gate.authorize() },
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        let refundID = UUID(), shipmentID = UUID()
        let original = ComposeSessionMemoryDraftFacts(
            recordIDs: [refundID, shipmentID],
            texts: ["The refund is delayed.", "The shipment arrived."]
        )
        memory.draftFactsToReturn = original
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let sourceID = try #require(fixture.coordinator.sessionFactsReviewSource?.id)
        let regeneration = Task {
            await fixture.coordinator.regenerateWithoutSessionFact(
                sourceID: sourceID, recordID: shipmentID
            )
        }
        await gate.waitUntilSuspended()
        memory.draftFactsToReturn = .init(
            recordIDs: original.recordIDs,
            texts: ["The refund was approved.", "The shipment arrived."],
            localUseRevision: original.localUseRevision
        )
        await gate.resume()
        #expect(await regeneration.value)
        #expect(await provider.requests.count == 1)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func excludingLastIndividualFactBecomesTranscriptOnly() async throws {
        let provider = CapturingScribeProvider(resultText: "Could you share an update on the refund?")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        let firstID = UUID(), secondID = UUID()
        memory.draftFactsToReturn = .init(
            recordIDs: [firstID, secondID],
            texts: ["The refund is delayed.", "The shipment arrived."]
        )
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let originalID = try #require(fixture.coordinator.sessionFactsReviewSource?.id)
        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: originalID, recordID: secondID
        ))
        let remainingID = try #require(fixture.coordinator.sessionFactsReviewSource?.id)
        #expect(await fixture.coordinator.regenerateWithoutSessionFact(
            sourceID: remainingID, recordID: firstID
        ))
        #expect(fixture.coordinator.sessionFactsReviewSource == nil)
        let readsAfterExclusion = memory.draftFactsCallCount
        #expect(await provider.requests.count == 3)
        #expect(await !provider.requests[2].input.userMessage.contains("The refund is delayed."))
        #expect(await !provider.requests[2].input.userMessage.contains("The shipment arrived."))

        await fixture.coordinator.retryGeneration()
        #expect(await provider.requests.count == 4)
        #expect(memory.draftFactsCallCount == readsAfterExclusion)
        await fixture.coordinator.cancel()
    }

    @Test
    func reviewedLocalDraftChoiceIsRecordedOnlyAfterCopyOrConfirmedInsert() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Hello, how are you?"),
            engine: StubScribeTranscriptionEngine(text: "Write a greeting.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        fixture.coordinator.installSessionMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(memory.chosenDraftSelections.isEmpty)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == "Hello, how are you?")
        #expect(memory.chosenDraftSelections.isEmpty)
        fixture.coordinator.noteReviewedDraftCopied()
        #expect(memory.chosenDraftSelections == [.copied])
        try await fixture.coordinator.insertReviewedResult()
        #expect(memory.chosenDraftSelections == [.copied, .inserted])
    }

    @Test
    func forgottenSessionFactCannotBeCopiedFromReviewedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Could you update me on my delayed refund?"),
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.draftFactsToReturn = .init(recordIDs: [UUID()], texts: ["The refund is delayed."])
        fixture.coordinator.installSessionMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.takeReviewedDraftForCopy() != nil)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)

        memory.draftFactsToReturn = nil
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        await fixture.coordinator.cancel()
    }

    @Test
    func forgottenSessionFactCannotBeInsertedFromReviewedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Could you update me on my delayed refund?"),
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.draftFactsToReturn = .init(recordIDs: [UUID()], texts: ["The refund is delayed."])
        fixture.coordinator.installSessionMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        memory.draftFactsToReturn = nil
        do {
            try await fixture.coordinator.insertReviewedResult()
            Issue.record("A draft from forgotten memory must not be inserted")
        } catch ScribeContextError.captureCleared {
        } catch {
            Issue.record("Expected the invalidated capture error")
        }
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedResult == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func factForgottenDuringInsertionPreflightPostsNoText() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Could you update me on my delayed refund?"),
            engine: StubScribeTranscriptionEngine(text: "Ask for an update on the refund.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.draftFactsToReturn = .init(recordIDs: [UUID()], texts: ["The refund is delayed."])
        fixture.coordinator.installSessionMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        fixture.context.beforeSelectedTextPreflight = { memory.draftFactsToReturn = nil }

        do {
            try await fixture.coordinator.insertReviewedResult()
            Issue.record("A revoked fact must stop the insertion preflight")
        } catch ScribeContextError.captureCleared {
        } catch {
            Issue.record("Expected the invalidated capture error")
        }
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        await fixture.coordinator.cancel()
    }

    @Test
    func ambiguousSessionFollowUpAsksForIssueWithoutCallingProvider() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not generate")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "Ask for an update.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.draftFactsError = .ambiguousFollowUp
        fixture.coordinator.installSessionMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.failure == .memoryAmbiguous)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(!fixture.coordinator.canRetryGeneration)
        #expect(fixture.coordinator.literalRecoveryTranscript == "Ask for an update.")
        #expect(await provider.requests.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func ambiguityAfterOneFactInvalidatesItsPreviouslyReviewedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Could you update me on my delayed refund?"),
            engine: StubScribeTranscriptionEngine(text: "Ask for an update.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.draftFactsToReturn = .init(recordIDs: [UUID()], texts: ["The refund is delayed."])
        fixture.coordinator.installSessionMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult != nil)

        memory.draftFactsError = .ambiguousFollowUp
        await fixture.coordinator.retryGeneration()
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .memoryUnavailable)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func explicitMemoryCommandStaysLocalAndDoesNotBecomeADraft() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not generate")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "Remember that this project uses SwiftUI.")
        )
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        memory.acceptsExplicitCommands = true
        fixture.coordinator.installSessionMemoryContext(memory)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        let notice = try #require(memory.performedNotice)
        #expect(memory.performedCommand == .remember(fact: "this project uses SwiftUI."))
        #expect(fixture.coordinator.state == .memoryNotice(notice))
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(await provider.requests.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func sessionMemoryIdentityStartsAfterMicrophoneAndClearsOnCancel() async throws {
        let fixture = ScribeCoordinatorFixture()
        let memory = SessionMemoryLifecycleSpy(audio: fixture.audio)
        fixture.coordinator.installSessionMemoryContext(memory)
        try await fixture.coordinator.beginDirectDictation()
        for _ in 0..<100 where memory.startedActionID == nil { await Task.yield() }
        let actionID = try #require(fixture.coordinator.activeRequestID)
        #expect(memory.startedActionID == actionID)
        #expect(memory.microphoneWasLiveAtBegin)
        await fixture.coordinator.cancel()
        #expect(memory.clearedActionIDs.contains(actionID))
    }

    @Test
    func refreshInvalidatesLateRetryAndKeepsNewSourceAttribution() async throws {
        let reader = SelectedTextRuntimeTestReader(text: "Original source.")
        let controller = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true),
            reader: reader, permissions: { .init(accessibility: true) })
        let provider = SuspendedRefinementProvider()
        let fixture = ScribeCoordinatorFixture(provider: provider,
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let old = try #require(fixture.coordinator.selectedTextReviewSource)
        let retry = Task { await fixture.coordinator.retryGeneration() }
        await provider.waitForSuspendedRequest()
        await reader.setText("New source.")
        let refreshed = await fixture.coordinator.refreshSelectedTextSource(id: old.id)
        #expect(refreshed)
        let currentID = fixture.coordinator.activeRequestID
        await provider.completeSuspendedRequest()
        await retry.value
        #expect(fixture.coordinator.reviewedResult?.text == "Newer accepted draft")
        #expect(fixture.coordinator.reviewedResult?.requestID == currentID)
        #expect(fixture.coordinator.selectedTextReviewSource?.id != old.id)
        #expect(fixture.coordinator.selectedTextReviewSource?.text == "New source.")
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func refreshProviderFailurePublishesEligibleRetry() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let controller = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true),
            reader: reader, permissions: { .init(accessibility: true) })
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("Draft."), .failure(.offline)],
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.selectedTextReviewSource)
        var retryAtFailurePublication = false
        fixture.coordinator.onStateChange = { state in
            if case .failed = state { retryAtFailurePublication = fixture.coordinator.canRetryGeneration }
        }
        let refreshed = await fixture.coordinator.refreshSelectedTextSource(id: source.id)
        #expect(refreshed)
        #expect(fixture.coordinator.failure == .provider(.offline))
        #expect(retryAtFailurePublication)
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == nil)
        fixture.coordinator.onStateChange = nil
        await fixture.coordinator.cancel()
    }

    @Test
    func refreshingSelectionCreatesNewActionWhileRetryKeepsOriginalSnapshot() async throws {
        let reader = SelectedTextRuntimeTestReader(text: "Original selection ready for review.")
        let controller = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true),
            reader: reader, permissions: { .init(accessibility: true) })
        let provider = CapturingScribeProvider(resultText: "Draft for review.")
        let fixture = ScribeCoordinatorFixture(provider: provider,
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: RefinementSequenceEngine(texts: ["Make this shorter."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let old = try #require(fixture.coordinator.selectedTextReviewSource)
        let oldID = fixture.coordinator.activeRequestID
        await reader.setText("Replacement selection ready for review.")
        await fixture.coordinator.retryGeneration()
        #expect(fixture.coordinator.selectedTextReviewSource?.id == old.id)
        #expect(await reader.readCount == 1)
        let didRefresh = await fixture.coordinator.refreshSelectedTextSource(id: old.id)
        #expect(didRefresh)
        #expect(fixture.coordinator.activeRequestID != oldID)
        let fresh = try #require(fixture.coordinator.selectedTextReviewSource)
        #expect(fresh.id != old.id)
        #expect(fresh.text == "Replacement selection ready for review.")
        let requests = await provider.requests
        try #require(requests.count == 3)
        #expect(requests[0].input == requests[1].input)
        #expect(requests[2].id != requests[1].id)
        #expect(requests[2].input.userMessage.contains("Replacement selection"))
        #expect(!requests[2].input.userMessage.contains("Original selection"))
        #expect(!requests[2].input.userMessage.contains("Draft for review."))
        #expect(await reader.readCount == 2)
        #expect(fixture.context.contextRestoreCount == 1)
        #expect(fixture.context.captureCount == 1)
        #expect(fixture.audio.startCount == 1)
        #expect(fixture.coordinator.literalTranscript == "Make this shorter.")
        #expect(fixture.coordinator.literalRecoveryTranscript == nil)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(fixture.context.insertedTexts.isEmpty)
        let stale = await fixture.coordinator.refreshSelectedTextSource(id: old.id)
        #expect(!stale)
        await fixture.coordinator.cancel()
    }

    @Test(arguments: [false, true])
    func cancelledOrRevokedRefreshCannotPublishLateSource(revoke: Bool) async throws {
        let reader = SelectedTextRuntimeTestReader()
        let controller = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true),
            reader: reader, permissions: { .init(accessibility: true) })
        let provider = CapturingScribeProvider(resultText: "Draft.")
        let fixture = ScribeCoordinatorFixture(provider: provider,
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: RefinementSequenceEngine(texts: ["Make this shorter."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.selectedTextReviewSource)
        await reader.suspendNextRead()
        let refresh = Task { await fixture.coordinator.refreshSelectedTextSource(id: source.id) }
        await reader.waitForPendingRead()
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.selectedTextReviewSource == nil)
        #expect(fixture.coordinator.literalRecoveryTranscript == nil)
        #expect(!fixture.coordinator.canRetryGeneration)
        let duplicate = await fixture.coordinator.refreshSelectedTextSource(id: source.id)
        #expect(!duplicate)
        if revoke { controller.updatePreferences(.init()) }
        else { await fixture.coordinator.cancel() }
        await reader.resume()
        _ = await refresh.value
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalTranscript == nil)
        #expect(fixture.coordinator.selectedTextReviewSource == nil)
        #expect(await provider.requests.count == 1)
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test(arguments: [false, true])
    func failedRefreshNeverPromotesEditingInstructionToMessage(targetFails: Bool) async throws {
        let reader = SelectedTextRuntimeTestReader()
        let controller = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true),
            reader: reader, permissions: { .init(accessibility: true) })
        let provider = CapturingScribeProvider(resultText: "Draft.")
        let fixture = ScribeCoordinatorFixture(provider: provider,
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: RefinementSequenceEngine(texts: ["Make this shorter."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.selectedTextReviewSource)
        if targetFails { fixture.context.shouldVerify = false }
        else { await reader.setText("") }
        let started = await fixture.coordinator.refreshSelectedTextSource(id: source.id)
        #expect(started)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == nil)
        #expect(fixture.coordinator.unpolishedHistoryDraft() == nil)
        #expect(!fixture.coordinator.canRetryGeneration)
        #expect(await provider.requests.count == 1)
        #expect(fixture.audio.startCount == 1)
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func excludedSourceReplacementUsesOnlyNewSpeechAndDoesNotChangeCapturePreferences() async throws {
        let sourceText = "EXCLUDED_SOURCE_CANARY for the previous draft."
        let reader = SelectedTextRuntimeTestReader(text: sourceText)
        let preferences = ComposeSelectedTextContextPreferences(isEnabled: true, textEditAllowed: true)
        let controller = ComposeSelectedTextContextController(preferences: preferences, reader: reader, permissions: { .init(accessibility: true) })
        let provider = CapturingScribeProvider(resultText: "Draft for review.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller,
            engine: RefinementSequenceEngine(texts: ["Make this shorter.", "The new message is ready.", "Make this shorter."])
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let oldActionID = try #require(fixture.coordinator.activeRequestID)
        let old = try #require(fixture.coordinator.selectedTextReviewSource)
        fixture.coordinator.excludeSelectedTextSource(id: old.id)
        let excludedRefresh = await fixture.coordinator.refreshSelectedTextSource(id: old.id)
        #expect(!excludedRefresh)
        #expect(await reader.readCount == 1)
        let staleStarted = try await fixture.coordinator.recordReplacementWithoutSelectedSource(id: UUID())
        #expect(!staleStarted)
        #expect(fixture.coordinator.activeRequestID == oldActionID)
        let started = try await fixture.coordinator.recordReplacementWithoutSelectedSource(id: old.id)
        #expect(started)
        #expect(fixture.coordinator.activeRequestID != oldActionID)
        #expect(fixture.coordinator.selectedTextReviewSource == nil)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(await reader.readCount == 1)
        await fixture.coordinator.finishRecording()
        let requests = await provider.requests
        try #require(requests.count == 2)
        #expect(requests[1].input.userMessage.contains("The new message is ready."))
        #expect(!requests[1].input.userMessage.contains(sourceText))
        #expect(!requests[1].input.systemMessage.contains(sourceText))
        #expect(!requests[1].input.userMessage.contains("Draft for review."))
        #expect(fixture.coordinator.literalTranscript == "The new message is ready.")
        #expect(fixture.coordinator.reviewedHistoryDraft()?.originalText == "The new message is ready.")
        #expect(controller.preferences == preferences)
        await fixture.coordinator.cancel()
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(await reader.readCount == 2)
        #expect(fixture.coordinator.usesSelectedTextContext)
        await fixture.coordinator.cancel()
    }

    @Test
    func genericRecordAgainAlsoHonorsExclusionAndMissingSourceStartsNoModelWork() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader,
            permissions: { .init(accessibility: true) }
        )
        let provider = CapturingScribeProvider(resultText: "Old draft.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: RefinementSequenceEngine(texts: ["Make this shorter.", "Make this shorter."])
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.selectedTextReviewSource)
        let notExcluded = try await fixture.coordinator.recordReplacementWithoutSelectedSource(id: source.id)
        #expect(!notExcluded)
        #expect(fixture.coordinator.reviewedResult?.text == "Old draft.")
        fixture.coordinator.excludeSelectedTextSource(id: source.id)
        try await fixture.coordinator.reRecord()
        await fixture.coordinator.finishRecording()
        #expect(await reader.readCount == 1)
        #expect(await provider.requests.count == 1)
        #expect(fixture.coordinator.failure == .missingSource)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.selectedTextReviewSource == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func repeatedReplacementCallbacksCannotCancelOrDuplicateTheNewRecording() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader,
            permissions: { .init(accessibility: true) }
        )
        let engine = RefinementSequenceEngine(texts: ["Make this shorter.", "A complete new message."], suspendsSecondStart: true)
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Draft."),
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: engine
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.selectedTextReviewSource)
        fixture.coordinator.excludeSelectedTextSource(id: source.id)
        let replacement = Task { try await fixture.coordinator.recordReplacementWithoutSelectedSource(id: source.id) }
        await engine.waitUntilStartSuspended()
        let newID = fixture.coordinator.activeRequestID
        let duplicate = try await fixture.coordinator.recordReplacementWithoutSelectedSource(id: source.id)
        #expect(!duplicate)
        try await fixture.coordinator.reRecord()
        #expect(fixture.coordinator.activeRequestID == newID)
        await engine.resumeStart()
        let started = try await replacement.value
        #expect(started)
        #expect(await reader.readCount == 1)
        await fixture.coordinator.finishRecording()
        #expect(fixture.context.captureCount == 2)
        #expect(fixture.coordinator.literalTranscript == "A complete new message.")
        await fixture.coordinator.cancel()
    }

    @Test
    func delayedSourceControlsCannotRewindAnInsertionAlreadyInProgress() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader,
            permissions: { .init(accessibility: true) }
        )
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Approved draft."),
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: StubScribeTranscriptionEngine(text: "Make this shorter.")
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.selectedTextReviewSource)
        let actionID = try #require(fixture.coordinator.activeRequestID)
        await reader.suspendNextRead()
        let insertion = Task { try await fixture.coordinator.insertReviewedResult() }
        await reader.waitForPendingRead()
        #expect(fixture.coordinator.state == .inserting(requestID: actionID))
        fixture.coordinator.excludeSelectedTextSource(id: source.id)
        #expect(!fixture.coordinator.canInspectSelectedTextSource(id: source.id))
        #expect(!fixture.coordinator.isSelectedTextSourceExcluded)
        #expect(fixture.coordinator.state == .inserting(requestID: actionID))
        await reader.resume()
        try await insertion.value
        #expect(fixture.context.insertedTexts == ["Approved draft."])
        #expect(fixture.coordinator.state == .succeeded(requestID: actionID))
        #expect(fixture.coordinator.selectedTextReviewSource == nil)
    }

    @Test
    func excludingSelectedSourceKeepsAttributionButDisablesInsertionAndRetry() async throws {
        let text = "Original selected source with Cafe\u{301}."
        let reader = SelectedTextRuntimeTestReader(text: text)
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader,
            permissions: { .init(accessibility: true) }
        )
        let provider = CapturingScribeProvider(resultText: "Previous draft.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: StubScribeTranscriptionEngine(text: "Make this shorter.")
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.selectedTextReviewSource)
        #expect(Data(source.text.utf8) == Data(text.utf8))
        #expect(source.includedUTF8Bytes == text.utf8.count)
        #expect(fixture.coordinator.canInspectSelectedTextSource(id: source.id))
        fixture.coordinator.excludeSelectedTextSource(id: source.id)
        #expect(fixture.coordinator.isSelectedTextSourceExcluded)
        #expect(fixture.coordinator.selectedTextReviewSource?.text == text)
        #expect(fixture.coordinator.selectedTextContextStatus == "Excluded source · Previous draft")
        #expect(fixture.coordinator.reviewedResult?.text == "Previous draft.")
        #expect(!fixture.coordinator.canRetryGeneration)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == "Previous draft.")
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(fixture.coordinator.literalRecoveryTranscript == nil)
        do {
            try await fixture.coordinator.insertReviewedResult()
            Issue.record("Excluded-source draft must not be inserted")
        } catch { #expect(error as? ScribeCoordinatorError == .invalidState) }
        await fixture.coordinator.retryGeneration()
        #expect(await provider.requests.count == 1)
        #expect(await reader.readCount == 1)
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
        #expect(fixture.coordinator.selectedTextReviewSource == nil)
    }

    @Test
    func sourceExclusionInvalidatesAPendingRetryWithoutRelabelingItsOldDraft() async throws {
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: SelectedTextRuntimeTestReader(),
            permissions: { .init(accessibility: true) }
        )
        let provider = SuspendedRefinementProvider()
        let fixture = ScribeCoordinatorFixture(
            provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: StubScribeTranscriptionEngine(text: "Make this shorter.")
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let source = try #require(fixture.coordinator.selectedTextReviewSource)
        let retry = Task { await fixture.coordinator.retryGeneration() }
        await provider.waitForSuspendedRequest()
        fixture.coordinator.excludeSelectedTextSource(id: source.id)
        await provider.completeSuspendedRequest()
        await retry.value
        #expect(fixture.coordinator.reviewedResult?.text == "Initial draft")
        #expect(fixture.coordinator.selectedTextReviewSource?.id == source.id)
        #expect(fixture.coordinator.selectedTextReviewSource?.isExcluded == true)
        #expect(fixture.coordinator.selectedTextSourceProvenance?.sourceSnapshotID == source.id)
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func exclusionIsActionScopedAndRevocationStillClearsItsPreviousDraft() async throws {
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: SelectedTextRuntimeTestReader(),
            permissions: { .init(accessibility: true) }
        )
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Previous draft."),
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: StubScribeTranscriptionEngine(text: "Make this shorter.")
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let old = try #require(fixture.coordinator.selectedTextReviewSource)
        fixture.coordinator.excludeSelectedTextSource(id: UUID())
        #expect(!fixture.coordinator.isSelectedTextSourceExcluded)
        fixture.coordinator.excludeSelectedTextSource(id: old.id)
        await fixture.coordinator.cancel()
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let current = try #require(fixture.coordinator.selectedTextReviewSource)
        #expect(current.id != old.id)
        #expect(!current.isExcluded)
        #expect(!fixture.coordinator.canInspectSelectedTextSource(id: old.id))
        fixture.coordinator.excludeSelectedTextSource(id: old.id)
        #expect(!fixture.coordinator.isSelectedTextSourceExcluded)
        fixture.coordinator.excludeSelectedTextSource(id: current.id)
        controller.updatePreferences(.init())
        #expect(fixture.coordinator.selectedTextReviewSource == nil)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        #expect(fixture.coordinator.reviewedResult == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func selectedRewritePublishesCompilerProvenanceAndRejectsExpiredCopy() async throws {
        var now = Date()
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: SelectedTextRuntimeTestReader(),
            permissions: { .init(accessibility: true) }, now: { now }
        )
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.success("Shorter draft.")],
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: StubScribeTranscriptionEngine(text: "Make this shorter.")
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let provenance = try #require(fixture.coordinator.selectedTextSourceProvenance)
        #expect(provenance.includedSectionIDs == [1])
        #expect(provenance.omittedSectionIDs.isEmpty)
        #expect(provenance.includedUTF8Bytes == "Selected source".utf8.count)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == "Shorter draft.")
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        now += 121
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalRecoveryTranscript == nil)
        #expect(fixture.coordinator.selectedTextSourceProvenance == nil)
        #expect(fixture.coordinator.failure == .context(.captureCleared))
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func selectedRewriteExpiresDuringProviderWorkAndCannotPublishLateDraft() async throws {
        var now = Date()
        let provider = SuspendedSelectedRewriteProvider()
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: SelectedTextRuntimeTestReader(),
            permissions: { .init(accessibility: true) }, now: { now }
        )
        let fixture = ScribeCoordinatorFixture(
            provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, engine: StubScribeTranscriptionEngine(text: "Make this shorter.")
        )
        try await fixture.coordinator.beginDirectDictation()
        let finish = Task { await fixture.coordinator.finishRecording() }
        await provider.waitForRequest()
        now += 121
        await provider.complete()
        await finish.value
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .context(.captureCleared))
        #expect(!fixture.coordinator.canRetryGeneration)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func expiredSelectedRewriteNeverDispatchesAndOversizedOutputCannotBeReviewed() async throws {
        var now = Date()
        let provider = CapturingScribeProvider(resultText: "Unused")
        let controller = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: SelectedTextRuntimeTestReader(),
            permissions: { .init(accessibility: true) }, now: { now }
        )
        let fixture = ScribeCoordinatorFixture(
            provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: controller, providerDispatchAuthorization: { _ in now += 121; return true },
            engine: StubScribeTranscriptionEngine(text: "Make this shorter.")
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(await provider.requests.isEmpty)
        #expect(fixture.coordinator.failure == .context(.captureCleared))
        await fixture.coordinator.cancel()

        let oversizedController = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: SelectedTextRuntimeTestReader(),
            permissions: { .init(accessibility: true) }
        )
        let oversized = ScribeCoordinatorFixture(
            providerResponses: [.success(String(repeating: "a", count: 16 * 1_024 + 1))],
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: oversizedController, engine: StubScribeTranscriptionEngine(text: "Make this shorter.")
        )
        try await oversized.coordinator.beginDirectDictation()
        await oversized.coordinator.finishRecording()
        #expect(oversized.coordinator.reviewedResult == nil)
        #expect(oversized.coordinator.failure == .provider(.resultTooLarge))
        #expect(oversized.coordinator.literalRecoveryTranscript == nil)
        await oversized.coordinator.cancel()
    }

    @Test
    func savedDefaultsReachSelectedRewriteWithVoicePrecedence() async throws {
        let reader = SelectedTextRuntimeTestReader(text: "Hey, the draft is ready.")
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let provider = CapturingScribeProvider(resultText: "Hello, the draft is ready.")
        let fixture = ScribeCoordinatorFixture(provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, globalWritingDefaults: { .init(isEnabled: true, tone: .warm, preferConcise: true) }, engine: StubScribeTranscriptionEngine(text: "Write this formally."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let input = try #require(await provider.requests.first?.input)
        #expect(input.systemMessage.contains(ScribeWritingDirection.tone(.formal).instruction))
        #expect(input.systemMessage.contains(ScribeWritingDirection.concise.instruction))
        #expect(!input.systemMessage.contains(ScribeWritingDirection.tone(.warm).instruction))
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        await fixture.coordinator.cancel()
    }

    @Test
    func refinementVoiceOverridesPinnedGlobalTone() async throws {
        let provider = RefinementSequenceProvider(outputs: ["Hi Maya, the draft is ready.", "Maya, the draft is ready for your review."])
        let fixture = ScribeCoordinatorFixture(provider: provider, globalWritingDefaults: { .init(isEnabled: true, tone: .warm, preferConcise: true) }, engine: RefinementSequenceEngine(texts: ["Tell Maya the draft is ready.", "Write this formally."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        let requests = await provider.requests
        try #require(requests.count == 2)
        #expect(!requests[1].input.systemMessage.contains(ScribeWritingDirection.tone(.warm).instruction))
        #expect(requests[1].input.systemMessage.contains(ScribeWritingDirection.concise.instruction))
        #expect(requests[1].input.userMessage.contains("Write this formally."))
        #expect(fixture.coordinator.literalTranscript == "Tell Maya the draft is ready.")
        await fixture.coordinator.cancel()
    }

    @Test
    func globalDefaultsPinAtRecordingStartAndRefreshOnlyForNewAction() async throws {
        var defaults = ComposeGlobalWritingDefaults(isEnabled: true, tone: .warm, preferConcise: true)
        let provider = RefinementSequenceProvider(outputs: ["Draft", "Retried draft", "Next draft"])
        let fixture = ScribeCoordinatorFixture(provider: provider, globalWritingDefaults: { defaults })
        try await fixture.coordinator.beginDirectDictation()
        defaults.tone = .formal
        await fixture.coordinator.finishRecording()
        await fixture.coordinator.retryGeneration()
        let first = await provider.requests
        #expect(first.count == 2)
        #expect(first.allSatisfy { $0.input.userMessage.contains(ScribeWritingDirection.tone(.warm).instruction) })
        #expect(first.allSatisfy { !$0.input.userMessage.contains(ScribeWritingDirection.tone(.formal).instruction) })
        #expect(fixture.coordinator.literalTranscript == "Spoken request")
        await fixture.coordinator.cancel()
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let latest = try #require(await provider.requests.last)
        #expect(latest.input.userMessage.contains(ScribeWritingDirection.tone(.formal).instruction))
        await fixture.coordinator.cancel()
    }

    @Test
    func applicationDefaultsLoadAfterAudioStartsAndPinForTheRecording() async throws {
        var appValues: [ComposeWritingPreferenceValue] = [.tone(.formal)]
        var audioAtLookup: StubAudioCaptureService?
        var lookupSawLiveAudio = false
        let provider = CapturingScribeProvider(resultText: "The draft is ready.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            globalWritingDefaults: {
                .init(isEnabled: true, tone: .warm, preferConcise: true)
            },
            applicationWritingDefaults: { _ in
                lookupSawLiveAudio = audioAtLookup?.isCapturing == true
                return appValues
            }
        )
        audioAtLookup = fixture.audio
        try await fixture.coordinator.beginDirectDictation()
        #expect(lookupSawLiveAudio)
        appValues = [.tone(.polite)]
        await fixture.coordinator.finishRecording()
        let first = try #require(await provider.requests.first?.input)
        #expect(first.userMessage.contains(ScribeWritingDirection.tone(.formal).instruction))
        #expect(first.userMessage.contains(ScribeWritingDirection.concise.instruction))
        #expect(!first.userMessage.contains(ScribeWritingDirection.tone(.warm).instruction))
        #expect(!first.userMessage.contains(ScribeWritingDirection.tone(.polite).instruction))
        await fixture.coordinator.cancel()
    }
    @Test
    func selectedRewriteRequiresItsOwnPinnedCapabilityBeforeDispatch() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let provider = CapturingScribeProvider(resultText: "Never generated")
        let action = ScribeProviderActionSnapshot(provider: provider, destination: .legacyLocal, capabilityProfile: .init(supportedTaskRequirements: [.directDraft], maximumCompiledRequestUTF8Bytes: 12 * 1_024))
        let fixture = ScribeCoordinatorFixture(providerActionResolver: { action }, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .capability(.unsupportedTask(.selectedTextRewrite)))
        #expect(await provider.requests.isEmpty)
        #expect(fixture.coordinator.literalRecoveryTranscript == nil)
        #expect(!fixture.coordinator.canRetryGeneration)
        await fixture.coordinator.cancel()
    }

    @Test
    func unchangedSelectionRemainsReviewableWithHonestNotice() async throws {
        let source = "Maya, the preview is ready for review."
        let reader = SelectedTextRuntimeTestReader(text: source)
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("  " + source + "\n")], recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == source)
        #expect(fixture.coordinator.failure == .selectedTextUnchanged)
        #expect(fixture.coordinator.selectedTextReviewSource?.isUnchanged == true)
        #expect(fixture.coordinator.providerFailure == nil)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == source)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        await #expect(throws: ScribeCoordinatorError.invalidState) {
            try await fixture.coordinator.insertReviewedResult()
        }
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func unchangedWarmSelectionPublishesAReviewableLocalEdit() async throws {
        let source = "Maya, the preview is ready for review."
        let reader = SelectedTextRuntimeTestReader(text: source)
        let context = ComposeSelectedTextContextController(
            preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader,
            permissions: { .init(accessibility: true) }
        )
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.success(source)],
            recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []),
            selectedTextContext: context,
            engine: StubScribeTranscriptionEngine(text: "Make this warmer.")
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == "Hi Maya, the preview is ready for review.")
        #expect(fixture.coordinator.failure == nil)
        #expect(fixture.coordinator.selectedTextReviewSource?.isUnchanged == false)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(fixture.context.insertedTexts.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test
    func actualQuotedSelectionFailureCannotPromoteVoiceInstructionToDraft() async throws {
        // Frozen U9 selected-rewrite baseline: the model returned only the
        // quoted phrase and lost the surrounding request and quote marks.
        let source = "Please include the phrase \"Make it shorter\" in the review note."
        let reader = SelectedTextRuntimeTestReader(text: source)
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let provider = RefinementSequenceProvider(outputs: ["Make it shorter", "Please include \"Make it shorter\" in the review note. Thanks!"])
        let fixture = ScribeCoordinatorFixture(provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this warmer."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .provider(.invalidResult))
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalTranscript == "Make this warmer.")
        #expect(fixture.coordinator.literalRecoveryTranscript == nil)
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == nil)
        #expect(fixture.coordinator.unpolishedHistoryDraft() == nil)
        let failedState = fixture.coordinator.state
        fixture.coordinator.useLiteralTranscript()
        #expect(fixture.coordinator.state == failedState)
        #expect(fixture.coordinator.reviewedResult == nil)
        await #expect(throws: ScribeCoordinatorError.invalidState) {
            try await fixture.coordinator.insertUnpolishedResult()
        }
        #expect(fixture.context.insertedTexts.isEmpty)
        let presentation = ScribeNotchPresentation.project(state: failedState, literalTranscript: fixture.coordinator.literalRecoveryTranscript, failureMessage: nil, canRetryGeneration: fixture.coordinator.canRetryGeneration)
        guard case let .failure(_, literal, recovery) = presentation.content else {
            Issue.record("Expected selected rewrite failure recovery")
            return
        }
        #expect(literal == nil)
        #expect(recovery == .retryGeneration)
        await fixture.coordinator.retryGeneration()
        #expect(fixture.coordinator.reviewedResult?.text == "Please include \"Make it shorter\" in the review note. Thanks!")
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == nil)
        await #expect(throws: ScribeCoordinatorError.invalidState) {
            try await fixture.coordinator.insertUnpolishedResult()
        }
        try await fixture.coordinator.insertReviewedResult()
        #expect(fixture.context.insertedTexts == ["Please include \"Make it shorter\" in the review note. Thanks!"])
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
    }

    @Test
    func ordinaryComposeFailureStillOffersExplicitLiteralRecovery() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.failure(.invalidResult)])
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.literalRecoveryTranscript == "Spoken request")
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == "Spoken request")
        fixture.coordinator.useLiteralTranscript()
        #expect(fixture.coordinator.reviewedResult?.text == "Spoken request")
        try await fixture.coordinator.insertReviewedResult()
        #expect(fixture.context.insertedTexts == ["Spoken request"])
    }

    @Test
    func contextualInsertDoesNotCreateRetainedHistoryBeforeOrAfterInsertion() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let fixture = ScribeCoordinatorFixture(recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult != nil)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        try await fixture.coordinator.insertReviewedResult()
        #expect(fixture.context.insertedTexts == ["Draft"])
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(!fixture.coordinator.usesSelectedTextContext)
    }

    @Test
    func contextCancellationClearsCaptureBeforeSuspendedEngineTeardown() async throws {
        let reader = SelectedTextRuntimeTestReader(suspend: true)
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let engine = ControllableScribeEngine(suspendsCancel: true)
        let fixture = ScribeCoordinatorFixture(recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: engine)
        try await fixture.coordinator.beginDirectDictation()
        let actionID = try #require(fixture.coordinator.activeRequestID)
        await reader.waitForRead()
        let cancellation = Task { await fixture.coordinator.cancel() }
        await engine.waitForCancel()
        await reader.resume()
        #expect(await context.selectedText(for: actionID) == nil)
        #expect(!fixture.audio.isCapturing)
        await engine.resumeCancel()
        await cancellation.value
    }

    @Test
    func revokedActionsLateAuthorizationDenialCannotMutateNewerDraft() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let authorization = SuspendedDispatchAuthorization(result: false)
        var dispatchCount = 0
        let provider = CapturingScribeProvider(resultText: "Maya, the newer draft is ready.")
        let fixture = ScribeCoordinatorFixture(provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, providerDispatchAuthorization: { _ in
            dispatchCount += 1
            return dispatchCount == 1 ? await authorization.authorize() : true
        }, engine: RefinementSequenceEngine(texts: ["Make this shorter.", "Tell Maya the preview is ready."]))
        try await fixture.coordinator.beginDirectDictation()
        let older = Task { await fixture.coordinator.finishRecording() }
        await authorization.waitUntilEntered()
        context.updatePreferences(.init())
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let newerID = try #require(fixture.coordinator.activeRequestID)
        await authorization.resume()
        await older.value
        #expect(fixture.coordinator.reviewedResult?.text == "Maya, the newer draft is ready.")
        #expect(fixture.coordinator.reviewedResult?.requestID == newerID)
        #expect(fixture.coordinator.failure == nil)
        #expect(await provider.requests.count == 1)
        await fixture.coordinator.cancel()
    }
    @Test
    func selectedTextCaptureDoesNotDelayMicrophoneAndUsesOnlyLocalPinnedSource() async throws {
        let reader = SelectedTextRuntimeTestReader(text: "Selected source with extra words.", suspend: true)
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let provider = CapturingScribeProvider(resultText: "Selected source.")
        let fixture = ScribeCoordinatorFixture(provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        #expect(fixture.audio.isCapturing)
        #expect(fixture.coordinator.state == .listening(requestID: fixture.coordinator.activeRequestID!))
        await reader.waitForRead()
        await reader.resume()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == "Selected source.")
        #expect(fixture.coordinator.usesSelectedTextContext)
        #expect(fixture.coordinator.selectedTextContextStatus == "Selected text · This Mac")
        #expect(!fixture.coordinator.canRefineReviewedDraft)
        #expect(fixture.coordinator.refinementUnavailableReason != nil)
        #expect(fixture.coordinator.literalTranscript == "Make this shorter.")
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == "Selected source.")
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        let input = try #require(await provider.requests.first?.input)
        #expect(input.userMessage.contains("Selected source with extra words."))
        #expect(!input.systemMessage.contains("Selected source with extra words."))
        #expect(fixture.context.captureCount == 1)
        await fixture.coordinator.cancel()
    }

    @Test
    func approvedCloudSpeechCannotReadOrDispatchMissingSelectedSource() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let provider = CapturingScribeProvider(resultText: "Never dispatch")
        let action = ScribeProviderActionSnapshot(provider: provider, destination: .deepSeek)
        let fixture = ScribeCoordinatorFixture(providerActionResolver: { action }, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .missingSource)
        #expect(await reader.readCount == 0)
        #expect(await provider.requests.isEmpty)
        #expect(!fixture.coordinator.usesSelectedTextContext)
        await fixture.coordinator.cancel()
    }

    @Test
    func selectedTextRevocationClearsReviewedDraftAndEveryRevision() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let fixture = ScribeCoordinatorFixture(recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult != nil)
        #expect(fixture.coordinator.draftRevisionSession != nil)
        context.updatePreferences(.init())
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.draftRevisionSession == nil)
        #expect(fixture.coordinator.literalTranscript == nil)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == nil)
        #expect(fixture.coordinator.reviewedHistoryDraft() == nil)
        #expect(!fixture.coordinator.canRetryGeneration)
        #expect(!fixture.coordinator.usesSelectedTextContext)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func selectedTextRevocationSuppressesUncooperativeLateGeneration() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let provider = CrossActionLateCompletionProvider()
        let fixture = ScribeCoordinatorFixture(provider: provider, recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        let finish = Task { await fixture.coordinator.finishRecording() }
        await provider.waitForFirstRequest()
        context.updatePreferences(.init())
        await provider.completeFirstRequest()
        await finish.value
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.draftRevisionSession == nil)
        #expect(!fixture.coordinator.usesSelectedTextContext)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func editedSelectionBlocksReplacementButKeepsExplicitCopyRecovery() async throws {
        let reader = SelectedTextRuntimeTestReader()
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let fixture = ScribeCoordinatorFixture(recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        await reader.setText("New user typing")
        await #expect(throws: ScribeContextError.selectionChanged) { try await fixture.coordinator.insertReviewedResult() }
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == "Draft")
        #expect(fixture.context.captureCount == 1)
        await fixture.coordinator.cancel()
    }

    @Test
    func selectedSourceDoesNotAuthorizeRemovalOfItsOwnLiteral() async throws {
        let reader = SelectedTextRuntimeTestReader(text: "Remove --verbose from the command in the example.")
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("Remove the flag from the example.")], recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.failure == .provider(.invalidResult))
        await fixture.coordinator.cancel()
    }

    @Test
    func selectedSourceCanQuoteInternalMarkerWithoutFalseLeakRejection() async throws {
        let source = "Investigate why Spoken writing request: appears in the output."
        let reader = SelectedTextRuntimeTestReader(text: source)
        let context = ComposeSelectedTextContextController(preferences: .init(isEnabled: true, textEditAllowed: true), reader: reader, permissions: { .init(accessibility: true) })
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success(source)], recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: []), selectedTextContext: context, engine: StubScribeTranscriptionEngine(text: "Make this shorter."))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == source)
        await fixture.coordinator.cancel()
    }

    @Test(arguments: [ScribeProviderError.inputTooLarge, .unsupportedLanguage, .requestDeclined])
    func providerInputProblemsDoNotOfferOrPerformUnchangedRetry(_ error: ScribeProviderError) async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.failure(error), .success("Should not retry")])
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(!fixture.coordinator.canRetryGeneration)
        await fixture.coordinator.retryGeneration()
        #expect(fixture.coordinator.failure == .provider(error))
        #expect(fixture.coordinator.reviewedResult == nil)
        await fixture.coordinator.cancel()
    }
    @Test
    func voiceRefinementUsesPinnedVersionAndKeepsOriginalSpeechInHistory() async throws {
        let provider = RefinementSequenceProvider(outputs: ["Maya, the preview is ready.", "Hi Maya, the preview is ready whenever you have a moment."])
        let engine = RefinementSequenceEngine(texts: ["Tell Maya the preview is ready.", "Make that warmer."])
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: engine)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let initial = try #require(fixture.coordinator.draftRevisionSession)
        try await fixture.coordinator.beginRefinement()
        #expect(fixture.coordinator.isRefining)
        #expect(fixture.arbiter.activeKind == .scribe)
        await fixture.coordinator.finishRecording()
        let revised = try #require(fixture.coordinator.draftRevisionSession)
        #expect(revised.origin == initial.origin)
        #expect(revised.versions.count == 2)
        #expect(revised.currentVersion.revisionInstruction?.utterance == "Make that warmer.")
        #expect(fixture.context.captureCount == 1)
        #expect(fixture.context.clearedCaptureIDs.isEmpty)
        #expect(fixture.coordinator.literalTranscript == "Tell Maya the preview is ready.")
        #expect(fixture.coordinator.reviewedHistoryDraft()?.originalText == "Tell Maya the preview is ready.")
        #expect(fixture.coordinator.reviewedHistoryDraft()?.requestID == initial.origin.actionID)
        #expect(!fixture.coordinator.isRefining)
        #expect(fixture.arbiter.activeKind == nil)
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[1].id != requests[0].id)
        #expect(requests[1].input.userMessage.contains("Message to edit:\nMaya, the preview is ready."))
        #expect(!requests[1].input.userMessage.contains(initial.origin.captureID.uuidString))
        #expect(!requests[1].input.systemMessage.contains("no screen, selected text, conversation history, or previous draft"))
        try await fixture.coordinator.insertReviewedResult()
        #expect(fixture.context.insertedTexts == ["Hi Maya, the preview is ready whenever you have a moment."])
        #expect(fixture.coordinator.draftRevisionSession == nil)
    }

    @Test
    func buttonAndSpokenUndoRestoreExactVersionsWithoutGeneration() async throws {
        let first = "Maya, café e\u{301}.\nKeep the spacing."
        let provider = RefinementSequenceProvider(outputs: [first, "Maya, the draft is ready.", "Hello Maya, the draft is ready."])
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: RefinementSequenceEngine(texts: ["Tell Maya the draft is ready.", "Make that shorter.", "Make it warmer.", "Undo that change."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        fixture.coordinator.undoRefinement()
        #expect(Array(fixture.coordinator.reviewedResult!.text.utf8) == Array(first.utf8))
        #expect(await provider.requests.count == 2)
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        #expect(Array(fixture.coordinator.reviewedResult!.text.utf8) == Array(first.utf8))
        #expect(await provider.requests.count == 3)
        #expect(!fixture.coordinator.canUndoRefinement)
    }

    @Test
    func unchangedRefinementPreservesInitialReviewAndAllowsAnotherRefinement() async throws {
        let originalSpeech = "Tell Maya the café draft is ready."
        let base = "Maya, the café draft is ready.\nPlease review it."
        let changed = "Hi Maya, the café draft is ready. Please review it when you have a moment."
        let provider = RefinementSequenceProvider(outputs: [base, " \n" + base + "\n ", changed])
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: RefinementSequenceEngine(texts: [originalSpeech, "Make it warmer. Do not edit files.", "Make it more welcoming."])
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let initial = try #require(fixture.coordinator.reviewedResult)
        let session = try #require(fixture.coordinator.draftRevisionSession)
        let literals = fixture.coordinator.exactLiterals

        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.state == .reviewing(initial))
        #expect(fixture.coordinator.reviewedResult == initial)
        #expect(fixture.coordinator.draftRevisionSession == session)
        #expect(fixture.coordinator.exactLiterals == literals)
        #expect(fixture.coordinator.failure == .refinementUnchanged)
        #expect(fixture.coordinator.providerFailure == nil)
        #expect(fixture.coordinator.literalTranscript == originalSpeech)
        #expect(fixture.coordinator.lastRefinementInstruction == "Make it warmer. Do not edit files.")
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == base)
        #expect(fixture.coordinator.reviewedHistoryDraft()?.composedText == base)
        #expect(!fixture.coordinator.canUndoRefinement)
        #expect(fixture.coordinator.canRefineReviewedDraft)
        #expect(!fixture.coordinator.isRefining)
        #expect(fixture.arbiter.activeKind == nil)

        // A no-op discards its pending token, so the next explicit refinement
        // can create the first real revision against the same accepted draft.
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == changed)
        #expect(fixture.coordinator.draftRevisionSession?.versions.count == 2)
        #expect(fixture.coordinator.failure == nil)
        #expect(fixture.coordinator.canUndoRefinement)
        #expect(await provider.requests.count == 3)
    }

    @Test
    func unchangedTimedStatusRefinementPublishesTheBoundedEdit() async throws {
        let speech = "Tell Sam the build is ready and testing starts Tuesday. We will share the test results after testing."
        let base = "Sam, the build is ready, and testing starts Tuesday. We will share the test results after testing."
        let revised = "Sam, the build is ready. Testing starts Tuesday; we'll share results after testing."
        let provider = RefinementSequenceProvider(outputs: [base, base])
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: RefinementSequenceEngine(texts: [speech, "Make it more concise. Keep all the timing."])
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == base)
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == revised)
        #expect(fixture.coordinator.draftRevisionSession?.versions.count == 2)
        #expect(fixture.coordinator.failure == nil)
        #expect(await provider.requests.count == 2)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func unchangedRefinementPreservesExistingUndoWithoutAddingDuplicateVersion() async throws {
        let base = "Maya, the draft is ready."
        let revised = "Hi Maya, the draft is ready when you have a moment."
        let provider = RefinementSequenceProvider(outputs: [base, revised, revised])
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: RefinementSequenceEngine(texts: ["Tell Maya the draft is ready.", "Make it warmer.", "Make it friendlier."])
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        let accepted = try #require(fixture.coordinator.reviewedResult)
        let session = try #require(fixture.coordinator.draftRevisionSession)
        #expect(session.versions.count == 2)
        #expect(fixture.coordinator.canUndoRefinement)

        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.reviewedResult == accepted)
        #expect(fixture.coordinator.draftRevisionSession == session)
        #expect(fixture.coordinator.failure == .refinementUnchanged)
        #expect(fixture.coordinator.canUndoRefinement)
        #expect(fixture.coordinator.canRefineReviewedDraft)
        fixture.coordinator.undoRefinement()
        #expect(fixture.coordinator.reviewedResult?.text == base)
        #expect(!fixture.coordinator.canUndoRefinement)
        #expect(await provider.requests.count == 3)
    }

    @Test
    func failedRefinementRetainsDraftInstructionAndOriginalRecovery() async throws {
        let provider = RefinementSequenceProvider(outputs: ["Inspect the issue. Do not make any changes.", "Inspect the issue."])
        let original = "Inspect the issue. Do not make any changes."
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: RefinementSequenceEngine(texts: [original, "Make that shorter."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let baseVersion = fixture.coordinator.draftRevisionSession?.currentVersion
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .recipientRestriction)
        #expect(fixture.coordinator.reviewedResult?.text == original)
        #expect(fixture.coordinator.draftRevisionSession?.currentVersion == baseVersion)
        #expect(fixture.coordinator.lastRefinementInstruction == "Make that shorter.")
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == original)
        #expect(!fixture.coordinator.canRetryGeneration)
        await fixture.coordinator.retryGeneration()
        #expect(await provider.requests.count == 2)
        #expect(fixture.coordinator.canRefineReviewedDraft)
    }

    @Test
    func cancellingRefinementRecordingPreservesReviewAndReleasesVoiceLease() async throws {
        let fixture = ScribeCoordinatorFixture()
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let initial = fixture.coordinator.reviewedResult
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.cancelRefinement()
        #expect(fixture.coordinator.reviewedResult == initial)
        #expect(!fixture.coordinator.isRefining)
        #expect(fixture.coordinator.canRefineReviewedDraft)
        #expect(!fixture.audio.isCapturing)
        #expect(fixture.context.captureCount == 1)
        #expect(fixture.context.clearedCaptureIDs.isEmpty)
        let dictationLease = try fixture.arbiter.acquire(for: .dictation)
        fixture.arbiter.release(dictationLease)
    }

    @Test
    func refinementOwnershipIsPublishedBeforeSlowMicrophoneStartup() async throws {
        let engine = RefinementSequenceEngine(texts: ["The preview is ready."], suspendsSecondStart: true)
        let fixture = ScribeCoordinatorFixture(engine: engine)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        var sawRefinementOwnership = false
        fixture.coordinator.onStateChange = { _ in
            sawRefinementOwnership = sawRefinementOwnership || fixture.coordinator.isRefining
        }
        let start = Task { try await fixture.coordinator.beginRefinement() }
        await engine.waitUntilStartSuspended()
        #expect(sawRefinementOwnership)
        #expect(!fixture.audio.isCapturing)
        await fixture.coordinator.cancelRefinement()
        await engine.resumeStart()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
        #expect(fixture.coordinator.canRefineReviewedDraft)
        #expect(!fixture.audio.isCapturing)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func silentRefinementRestoresPreviousDraftWithoutProviderCall() async throws {
        let provider = RefinementSequenceProvider(outputs: ["Original accepted draft"])
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: RefinementSequenceEngine(texts: ["The preview is ready.", "   "]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .transcriptionEmpty)
        #expect(fixture.coordinator.reviewedResult?.text == "Original accepted draft")
        #expect(fixture.coordinator.literalTranscript == "The preview is ready.")
        #expect(await provider.requests.count == 1)
        #expect(fixture.coordinator.canRefineReviewedDraft)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func cloudDraftCannotEnterRefinementOrSendPriorDraft() async throws {
        let provider = RefinementSequenceProvider(outputs: ["Cloud draft"])
        let action = ScribeProviderActionSnapshot(provider: provider, destination: .openAIDirect)
        let fixture = ScribeCoordinatorFixture(providerActionResolver: { action })
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(!fixture.coordinator.canRefineReviewedDraft)
        #expect(fixture.coordinator.refinementUnavailableReason?.contains("Cloud") == true)
        await #expect(throws: ScribeCoordinatorError.invalidState) { try await fixture.coordinator.beginRefinement() }
        #expect(await provider.requests.count == 1)
        #expect(fixture.context.captureCount == 1)
        #expect(!fixture.audio.isCapturing)
    }

    @Test
    func targetChangeBlocksRefinementWithoutCapturingNewTarget() async throws {
        let fixture = ScribeCoordinatorFixture()
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        fixture.context.shouldVerify = false
        await #expect(throws: ScribeContextError.targetChanged) { try await fixture.coordinator.beginRefinement() }
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
        #expect(fixture.context.captureCount == 1)
        #expect(fixture.coordinator.failure == .context(.targetChanged))
        #expect(!fixture.coordinator.isRefining)
    }

    @Test
    func targetChangeDuringRefinementAuthorizationPreventsDispatch() async throws {
        let provider = RefinementSequenceProvider(outputs: ["Initial draft", "Must not dispatch"])
        let gate = RefinementDispatchGate()
        let fixture = ScribeCoordinatorFixture(
            provider: provider, providerDispatchAuthorization: { _ in await gate.authorize() },
            engine: RefinementSequenceEngine(texts: ["The preview is ready.", "Make that warmer."])
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.beginRefinement()
        let finish = Task { await fixture.coordinator.finishRecording() }
        await gate.waitUntilSuspended()
        fixture.context.shouldVerify = false
        await gate.resume()
        await finish.value
        #expect(await provider.requests.count == 1)
        #expect(fixture.coordinator.reviewedResult?.text == "Initial draft")
        #expect(fixture.coordinator.failure == .context(.targetChanged))
    }

    @Test
    func oversizedRefinementKeepsDraftWithoutGenerationFlash() async throws {
        let provider = RefinementSequenceProvider(outputs: ["Initial draft", "Must not dispatch"])
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: RefinementSequenceEngine(texts: ["The preview is ready.", String(repeating: "Make this warmer. ", count: 1000)]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        var states: [ScribeSessionState] = []
        fixture.coordinator.onStateChange = { states.append($0) }
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        #expect(await provider.requests.count == 1)
        #expect(fixture.coordinator.reviewedResult?.text == "Initial draft")
        guard case .capability(.inputTooLarge) = fixture.coordinator.failure else {
            Issue.record("Expected bounded compiled refinement input")
            return
        }
        #expect(!states.contains { if case .generating = $0 { return true }; return false })
    }

    @Test
    func refinementRespectsExistingVoiceLeaseWithoutLosingReview() async throws {
        let fixture = ScribeCoordinatorFixture()
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let lease = try fixture.arbiter.acquire(for: .dictation)
        await #expect(throws: VoiceSessionArbiterError.busy(.dictation)) { try await fixture.coordinator.beginRefinement() }
        #expect(fixture.arbiter.activeKind == .dictation)
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
        #expect(fixture.coordinator.failure == .voiceSessionBusy(.dictation))
        #expect(fixture.coordinator.canRefineReviewedDraft)
        fixture.arbiter.release(lease)
    }

    @Test
    func lateRefinementCannotOverwriteNewerAcceptedVersion() async throws {
        let provider = SuspendedRefinementProvider()
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: RefinementSequenceEngine(texts: ["The preview is ready.", "Make that warmer.", "Make that shorter."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.beginRefinement()
        let oldFinish = Task { await fixture.coordinator.finishRecording() }
        await provider.waitForSuspendedRequest()
        await fixture.coordinator.cancelRefinement()
        try await fixture.coordinator.beginRefinement()
        await fixture.coordinator.finishRecording()
        let acceptedVersion = fixture.coordinator.draftRevisionSession?.currentVersion
        await provider.completeSuspendedRequest()
        await oldFinish.value
        #expect(fixture.coordinator.reviewedResult?.text == "Newer accepted draft")
        #expect(fixture.coordinator.draftRevisionSession?.currentVersion == acceptedVersion)
        #expect(fixture.context.captureCount == 1)
    }

    @Test
    func synchronousDictationInterruptionFenceRejectsCompletionBeforeCleanup() async throws {
        let provider = SuspendedRefinementProvider()
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: RefinementSequenceEngine(texts: ["The preview is ready.", "Make that warmer."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.beginRefinement()
        let finish = Task { await fixture.coordinator.finishRecording() }
        await provider.waitForSuspendedRequest()
        let dictationLease = try fixture.arbiter.acquire(for: .dictation)
        fixture.coordinator.invalidateRefinementCompletion()
        await provider.completeSuspendedRequest()
        await finish.value
        #expect(fixture.coordinator.reviewedResult?.text == "Initial draft")
        await fixture.coordinator.cancelRefinement()
        #expect(fixture.coordinator.reviewedResult?.text == "Initial draft")
        #expect(fixture.coordinator.lastRefinementInstruction == "Make that warmer.")
        #expect(fixture.arbiter.activeKind == .dictation)
        fixture.arbiter.release(dictationLease)
    }

    @Test
    func newDictationActionCannotInheritPendingRefinement() async throws {
        let provider = SuspendedRefinementProvider()
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: RefinementSequenceEngine(texts: ["The preview is ready.", "Make that warmer.", "The report is ready."]))
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let oldOrigin = try #require(fixture.coordinator.draftRevisionSession?.origin)
        try await fixture.coordinator.beginRefinement()
        let oldFinish = Task { await fixture.coordinator.finishRecording() }
        await provider.waitForSuspendedRequest()
        await fixture.coordinator.cancel()
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        await provider.completeSuspendedRequest()
        await oldFinish.value
        #expect(fixture.coordinator.reviewedResult?.text == "Newer accepted draft")
        #expect(fixture.coordinator.draftRevisionSession?.origin != oldOrigin)
        #expect(fixture.coordinator.draftRevisionSession?.versions.count == 1)
        #expect(fixture.coordinator.literalTranscript == "The report is ready.")
        #expect(fixture.context.captureCount == 2)
        #expect(fixture.coordinator.lastRefinementInstruction == nil)
    }

    @Test
    func droppedRecipientRestrictionCannotBecomeAnInsertionReadyDraft() async throws {
        let spoken = "Ask the coding agent why the login fails. Do not make any changes."
        let provider = CapturingScribeProvider(resultText: "Ask the coding agent why the login fails.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider, engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .recipientRestriction)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalTranscript == spoken)
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == spoken)
        #expect(fixture.context.insertedTexts.isEmpty)
        await #expect(throws: ScribeCoordinatorError.invalidState) {
            try await fixture.coordinator.insertReviewedResult()
        }
    }

    @Test
    func droppedNamedRecipientCannotBecomeAnInsertionReadyDraft() async throws {
        let spoken = "Make this upbeat and brief. Tell Nora the rehearsal starts at nine."
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: "Rehearsal starts at nine."),
            engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .provider(.invalidResult))
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalTranscript == spoken)
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == spoken)
        #expect(fixture.context.insertedTexts.isEmpty)
        await #expect(throws: ScribeCoordinatorError.invalidState) {
            try await fixture.coordinator.insertReviewedResult()
        }
    }

    @Test
    func supportedRestrictionParaphraseRemainsReviewable() async throws {
        let spoken = "Ask the coding agent why the login fails. Do not make any changes."
        let draft = "Investigate why the login fails. Make no changes."
        let fixture = ScribeCoordinatorFixture(
            provider: CapturingScribeProvider(resultText: draft),
            engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == draft)
        #expect(fixture.coordinator.failure == nil)
    }

    @Test
    func performanceRecorderCapturesLifecycleWithoutContent() async throws {
        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: CoordinatorPerformanceClock(), sink: sink)
        let fixture = ScribeCoordinatorFixture(performanceRecorder: recorder)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.insertReviewedResult()

        #expect(sink.samples.count == 1)
        let sample = try #require(sink.samples.first)
        #expect(sample.terminalOutcome == .completed)
        #expect(sample.stages.map(\.stage) == [
            .targetPinned, .listening, .firstAudioFrame, .transcriptionFinished,
            .generationStarted, .reviewReady, .insertionAttempted
        ])
    }

    @Test
    func externallyStartedPerformanceActionIncludesCoordinatorAcquisition() async throws {
        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: CoordinatorPerformanceClock(), sink: sink)
        let fixture = ScribeCoordinatorFixture(performanceRecorder: recorder)
        let actionID = UUID()
        recorder.begin(actionID: actionID)
        recorder.mark(.permissionsChecked, actionID: actionID)
        recorder.mark(.providerPreflightCompleted, actionID: actionID)
        recorder.mark(.transcriptionConfigured, actionID: actionID)

        try await fixture.coordinator.beginDirectDictation(actionID: actionID)
        await fixture.coordinator.finishRecording()
        await fixture.coordinator.cancel()

        let sample = try #require(sink.samples.first)
        #expect(sample.actionID == actionID)
        #expect(sample.stages.prefix(5).map(\.stage) == [
            .permissionsChecked, .providerPreflightCompleted, .transcriptionConfigured,
            .targetPinned, .listening
        ])
    }

    @Test
    func missingSourceFailsBeforeGenerationPerformanceStage() async throws {
        let sink = ScribePerformanceSampleBuffer()
        let recorder = ScribePerformanceRecorder(clock: CoordinatorPerformanceClock(), sink: sink)
        let fixture = ScribeCoordinatorFixture(
            engine: StubScribeTranscriptionEngine(text: "Make this shorter."),
            performanceRecorder: recorder
        )

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(sink.samples.count == 1)
        let sample = try #require(sink.samples.first)
        #expect(sample.terminalOutcome == .failed)
        #expect(!sample.stages.contains { $0.stage == .generationStarted })
    }

    @Test
    func sourceFreeSummaryDoesNotDispatchOrReviewTheCommand() async throws {
        let provider = CapturingScribeProvider(resultText: "Summarize this in one sentence.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "Summarize this in one sentence.")
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .missingSource)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(await provider.requests.isEmpty)
        await fixture.coordinator.cancel()
    }

    @Test(arguments: [
        "Please include https://status.example.org/incidents/9 in the update.",
        "Use the exact phrase \"waiting for verification\" in the update."
    ])
    func sourceFreeLiteralUpdateModifierDoesNotDispatchOrReview(speech: String) async throws {
        let provider = CapturingScribeProvider(resultText: "A bare string must not be reviewed")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: speech)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .missingSource)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(await provider.requests.isEmpty)
        await fixture.coordinator.cancel()
    }
    @Test
    func oversizedRequestRetainsSpeechAndNeverDispatchesOrFlashesGenerating() async throws {
        let spoken = "Tell Alex " + String(repeating: "synthetic detail ", count: 900) + "end."
        let provider = CapturingScribeProvider(resultText: "Unexpected generation")
        let fixture = ScribeCoordinatorFixture(
            provider: provider, engine: StubScribeTranscriptionEngine(text: spoken)
        )
        var states: [ScribeSessionState] = []
        fixture.coordinator.onStateChange = { states.append($0) }
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        guard case .capability(.inputTooLarge) = fixture.coordinator.failure else {
            Issue.record("Expected an explicit request-size recovery outcome")
            return
        }
        #expect(fixture.coordinator.literalTranscript == spoken)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(await provider.requests.isEmpty)
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(!fixture.coordinator.canRetryGeneration)
        #expect(!states.contains { if case .generating = $0 { return true }; return false })
    }

    @Test
    func actionCapabilityOverrideBlocksBeforeProviderDispatch() async throws {
        let provider = CapturingScribeProvider(resultText: "Unexpected generation")
        let action = ScribeProviderActionSnapshot(
            provider: provider, destination: .legacyLocal,
            capabilityProfile: .init(availability: .unavailable, maximumCompiledRequestUTF8Bytes: 12_288)
        )
        let fixture = ScribeCoordinatorFixture(providerActionResolver: { action })
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .capability(.unavailable))
        #expect(fixture.coordinator.literalTranscript == "Spoken request")
        #expect(await provider.requests.isEmpty)
    }

    @Test(arguments: ["Make this shorter.", "Please rewrite this formally.", "Make this friendlier.", "Keep it brief.", "Could you make this more formal?", "Turn this into two bullet points.", "Turn this into bullet points."])
    func sourceDependentDirectionKeepsSpeechAndMakesNoProviderCall(spoken: String) async throws {
        let provider = CapturingScribeProvider(resultText: "Invented source")
        let fixture = ScribeCoordinatorFixture(
            provider: provider, engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .missingSource)
        #expect(fixture.coordinator.literalTranscript == spoken)
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(!fixture.coordinator.canRetryGeneration)
        #expect(await provider.requests.isEmpty)
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.takeUnpolishedDraftForCopy() == spoken)
        await fixture.coordinator.retryGeneration()
        #expect(await provider.requests.isEmpty)
        try await fixture.coordinator.beginDirectDictation()
        if case .listening = fixture.coordinator.state {} else {
            Issue.record("Missing source must allow a new recording")
        }
        await fixture.coordinator.cancel()
    }

    @Test
    func recipientRewriteRequestDoesNotRequireComposeSource() async throws {
        let spoken = "Ask Alex to make this shorter."
        let provider = CapturingScribeProvider(resultText: "Alex, please make this shorter.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider, engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(await provider.requests.count == 1)
        #expect(fixture.coordinator.reviewedResult != nil)
        #expect(fixture.coordinator.failure == nil)
    }

    @Test
    func spokenWritingDirectionsReachProviderAndReviewWithoutAutoInsertion() async throws {
        let spoken = "Tell Alex I will be ten minutes late. Keep it casual."
        let draft = "Hey Alex, I'll be ten minutes late."
        let provider = CapturingScribeProvider(resultText: draft)
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        let first = try #require(await provider.requests.first)
        #expect(first.input.systemMessage.contains("Rewrite the spoken message"))
        #expect(first.input.userMessage.contains("Spoken message:\nAlex, I will be ten minutes late."))
        #expect(first.input.systemMessage.contains("Use casual, natural wording."))
        #expect(fixture.coordinator.literalTranscript == spoken)
        #expect(fixture.coordinator.reviewedResult?.text == draft)
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedHistoryDraft()?.originalText == spoken)
        #expect(fixture.coordinator.reviewedHistoryDraft()?.composedText == draft)

        try await fixture.coordinator.insertReviewedResult()
        #expect(fixture.context.insertedTexts == [draft])
    }

    @Test(arguments: [0, 1, 2])
    func emptyRecordingGivesBriefFeedbackThenReturnsToIdleWithoutGenerating(outcome: Int) async throws {
        let provider = CapturingScribeProvider(resultText: "Should not generate")
        let error: WhisperEngineError? = outcome == 1 ? .emptyAudio : outcome == 2 ? .noTranscript : nil
        let fixture = ScribeCoordinatorFixture(provider: provider, engine: StubScribeTranscriptionEngine(text: "  ", failure: error), noSpeechFeedbackDuration: .zero)
        var sawNoSpeech = false
        fixture.coordinator.onStateChange = { state in
            if case .failed(_, .emptyResult) = state { sawNoSpeech = true }
        }
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(sawNoSpeech)
        #expect(fixture.coordinator.state == .idle)
        #expect(fixture.coordinator.activeRequestID == nil)
        #expect(fixture.coordinator.failure == nil)
        #expect(await provider.requests.isEmpty)
        try await fixture.coordinator.beginDirectDictation()
        if case .listening = fixture.coordinator.state {} else { Issue.record("A new recording must work immediately") }
        await fixture.coordinator.cancel()
    }

    @Test
    func noSpeechExpiryCannotDismissANewerRecording() async throws {
        let fixture = ScribeCoordinatorFixture(engine: StubScribeTranscriptionEngine(text: ""))
        try await fixture.coordinator.beginDirectDictation()
        let finishing = Task { await fixture.coordinator.finishRecording() }
        while fixture.coordinator.failure != .transcriptionEmpty { await Task.yield() }
        try await fixture.coordinator.beginDirectDictation()
        let newID = fixture.coordinator.activeRequestID
        await finishing.value
        #expect(fixture.coordinator.activeRequestID == newID)
        if case .listening = fixture.coordinator.state {} else { Issue.record("Old feedback dismissed the new recording") }
        await fixture.coordinator.cancel()
    }

    @Test
    func modelFailureRemainsRecoverableInsteadOfBeingDismissedAsSilence() async throws {
        let fixture = ScribeCoordinatorFixture(engine: StubScribeTranscriptionEngine(text: "", failure: .contextInitializationFailed), noSpeechFeedbackDuration: .zero)
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .transcription)
        if case .failed = fixture.coordinator.state {} else { Issue.record("Real model errors must remain available") }
    }
    @Test
    func v2ControllerRevocationBetweenSnapshotAndDispatchMakesZeroTransportRequests() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library,
            legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(),
            vault: vault
        )
        let receipt = ScribeProviderConsentIssuer.issue(
            providerKind: .openAIDirect,
            recipientOrigin: "https://api.openai.com",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled,
            dataPolicy: .providerPolicyApplies,
            disclosureRevision: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let reference = ScribeStoredCredentialReference(
            domain: .candidate, opaqueReference: .init(rawValue: "coordinator-v2")
        )
        let configuration = try U5Fixtures.configuration(
            kind: .openAIDirect, model: "gpt-test", receipt: receipt, reference: reference
        )
        let configured = ScribeProviderLibrary(
            revision: 2, configurations: [configuration], activeConfigurationID: configuration.id
        )
        library.result = .valid(configured)
        await vault.insert(reference)
        await authority.bootstrap(from: configured)
        let transport = U4RecordingTransport(results: [])
        let controller = ScribeProviderV2Controller(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            transport: transport
        )
        let fixture = ScribeCoordinatorFixture(
            providerActionResolver: { try await controller.actionForNewRequest() },
            providerDispatchAuthorization: { action in
                await controller.authorizeDispatch(action.actionIdentity)
            }
        )

        try await fixture.coordinator.beginDirectDictation()
        await authority.revoke(receipt.id)
        await fixture.coordinator.finishRecording()

        #expect(await transport.requests.isEmpty)
        if case .failed = fixture.coordinator.state {
            // Expected exact V2 checkpoint rejection before transport.
        } else {
            Issue.record("Expected fail-closed recovery after consent revocation")
        }
    }

    @Test
    func defaultsNotificationInvalidationCancelsActiveCoordinatorAndStopsProvider() async throws {
        let runtime = try AdaptiveRuntimeFixture()
        defer { runtime.cleanUp() }
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            providerDispatchAuthorization: { _ in runtime.monitor.authorizeProviderDispatch() }
        )
        var cancellation: Task<Void, Never>?
        runtime.monitor.onInvalidation = {
            fixture.coordinator.invalidateProviderWork()
            cancellation = Task { @MainActor in await fixture.coordinator.cancel() }
        }
        runtime.monitor.start()
        #expect(runtime.monitor.revalidate())
        try await fixture.coordinator.beginDirectDictation()

        try runtime.gateStore.save(.allDisabled)
        runtime.notificationCenter.post(
            name: UserDefaults.didChangeNotification,
            object: runtime.defaults
        )
        for _ in 0..<1_000 where cancellation == nil { await Task.yield() }
        await cancellation?.value
        await fixture.coordinator.finishRecording()

        if case .cancelled = fixture.coordinator.state {
            // Expected invalidation cleanup.
        } else {
            Issue.record("Expected notification-triggered cancellation")
        }
        #expect(await provider.requests.isEmpty)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func preDispatchCheckpointRejectsGateMutationWithoutWaitingForNotification() async throws {
        let runtime = try AdaptiveRuntimeFixture()
        defer { runtime.cleanUp() }
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            providerDispatchAuthorization: { _ in runtime.monitor.authorizeProviderDispatch() }
        )
        try await fixture.coordinator.beginDirectDictation()
        try runtime.gateStore.save(.allDisabled)

        await fixture.coordinator.finishRecording()

        #expect(await provider.requests.isEmpty)
        if case .failed = fixture.coordinator.state {
            // Checkpoint cancelled before provider dispatch.
        } else {
            Issue.record("Expected checkpoint recovery")
        }
    }

    @Test
    func appModelGateInvalidationCancelsReachableCoordinatorBeforeRemoteWork() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let fixture = ScribeCoordinatorFixture(provider: provider)
        try await fixture.coordinator.beginDirectDictation()
        var cancellation: Task<Void, Never>?
        var setupPresented = false

        let allowed = AppModel.enforceAdaptiveScribeEntry(
            availability: .setupRequired,
            cancelActiveCoordinator: {
                cancellation = Task { @MainActor in
                    await fixture.coordinator.cancel()
                }
            },
            presentSetup: { setupPresented = true }
        )
        await cancellation?.value

        #expect(!allowed)
        #expect(setupPresented)
        if case .cancelled = fixture.coordinator.state {
            // Expected terminal cancellation before generation.
        } else {
            Issue.record("Expected coordinator cancellation")
        }
        #expect(await provider.requests.isEmpty)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func voiceSessionArbiterRejectsOverlappingPipelines() throws {
        let arbiter = VoiceSessionArbiter()
        let dictation = try arbiter.acquire(for: .dictation)

        #expect(arbiter.activeKind == .dictation)
        #expect(throws: VoiceSessionArbiterError.busy(.dictation)) {
            try arbiter.acquire(for: .scribe)
        }

        arbiter.release(dictation)
        #expect(arbiter.activeKind == nil)
        #expect(try arbiter.acquire(for: .meeting).kind == .meeting)
    }

    @Test
    func voiceSessionKindsKeepInternalScribeIdentityOutOfUserFacingErrors() {
        #expect(VoiceSessionKind.dictation.displayName == "dictation")
        #expect(VoiceSessionKind.scribe.displayName == "Compose")
        #expect(VoiceSessionKind.meeting.displayName == "meeting")
        #expect(VoiceSessionKind.microphoneCheck.displayName == "microphone check")
    }

    @Test
    func composeRunsThroughReviewAndInsertsExactlyOnce() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("A polished update.")])

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.reviewedResult?.text == "A polished update.")
        #expect(fixture.coordinator.reviewedHistoryDraft()?.originalText == "Spoken request")
        #expect(fixture.coordinator.reviewedHistoryDraft()?.composedText == "A polished update.")
        #expect(fixture.arbiter.activeKind == nil)

        try await fixture.coordinator.insertReviewedResult()
        #expect(fixture.context.insertedTexts == ["A polished update."])
        #expect(fixture.context.clearedCaptureIDs.count == 1)

        await #expect(throws: ScribeCoordinatorError.insertionAlreadyCompleted) {
            try await fixture.coordinator.insertReviewedResult()
        }
    }

    @Test
    func simultaneousInsertActionsPostOnlyOneDraft() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("A polished update.")])
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        fixture.context.suspendInsertion = true

        let firstInsertion = Task { try await fixture.coordinator.insertReviewedResult() }
        await fixture.context.waitForInsertionStart()
        await #expect(throws: ScribeCoordinatorError.insertionAlreadyCompleted) {
            try await fixture.coordinator.insertReviewedResult()
        }
        await #expect(throws: ScribeCoordinatorError.insertionAlreadyCompleted) {
            try await fixture.coordinator.insertUnpolishedResult()
        }

        fixture.context.resumeInsertion()
        try await firstInsertion.value
        #expect(fixture.context.insertedTexts == ["A polished update."])
    }

    @Test
    func eventEmitterFailureRetainsReviewedDraftAndExplainsUncertainInsertion() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("A polished update.")])
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        let result = try #require(fixture.coordinator.reviewedResult)
        fixture.context.insertionError = GuardedTextInsertionError.uncertainPartialInsertion

        await #expect(throws: ScribeContextError.insertionUnconfirmed) {
            try await fixture.coordinator.insertReviewedResult()
        }
        #expect(fixture.coordinator.state == .insertionRecovery(result))
        #expect(fixture.coordinator.failure == .context(.insertionUnconfirmed))
        #expect(fixture.coordinator.insertionOutcomeUncertain)
        #expect(!fixture.coordinator.canRetryGeneration)
        #expect(!fixture.coordinator.canRefineReviewedDraft)
        #expect(fixture.coordinator.takeReviewedDraftForCopy() == result.text)
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(ScribeContextError.insertionUnconfirmed.userMessage.contains("Check the original app"))
        await #expect(throws: ScribeCoordinatorError.insertionAlreadyCompleted) {
            try await fixture.coordinator.insertReviewedResult()
        }
        await #expect(throws: ScribeCoordinatorError.insertionAlreadyCompleted) {
            try await fixture.coordinator.insertUnpolishedResult()
        }
    }

    @Test
    func copiedFormalDirectionCannotBecomeAReviewedDraft() async throws {
        let spoken = "Hey, how's it going? Write this formally."
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.success("Hello, how are you? Write this formally.")],
            engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .provider(.invalidResult))
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalRecoveryTranscript == spoken)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func codingAgentCompletionClaimStaysOutOfReviewAndInsertion() async throws {
        let spoken = "Ask Codex to investigate the crash without changing code."
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.success("I fixed the crash.")],
            engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.failure == .provider(.invalidResult))
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalRecoveryTranscript == spoken)
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test(arguments: [
        ("Inspect src/Auth.swift.bak with --no-cache without editing files.", false),
        ("Inspect src/Auth.swift without editing files.", false),
        ("Inspect src/Auth.swift with --no-cache without editing files.", true)
    ])
    func codingAgentPromptKeepsWrittenTargetAndFlagBeforeReview(
        draft: String, accepted: Bool
    ) async throws {
        let spoken = "Ask Codex to inspect `src/Auth.swift` with --no-cache without editing files."
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.success(draft)],
            engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.exactLiterals.map(\.value) == ["src/Auth.swift", "--no-cache"])
        if accepted {
            #expect(fixture.coordinator.reviewedResult?.text == draft)
        } else {
            #expect(fixture.coordinator.failure == .provider(.invalidResult))
            #expect(fixture.coordinator.reviewedResult == nil)
            #expect(fixture.coordinator.literalRecoveryTranscript == spoken)
        }
    }

    @Test(arguments: [
        ("The draft is ready.", false),
        ("I believe the draft is ready.", true)
    ])
    func formalUncertaintyIsCheckedBeforeReviewAndInsertion(draft: String, accepted: Bool) async throws {
        let spoken = "I think the draft is ready. Write this formally."
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.success(draft)],
            engine: StubScribeTranscriptionEngine(text: spoken)
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.context.insertedTexts.isEmpty)
        if accepted {
            #expect(fixture.coordinator.reviewedResult?.text == draft)
            try await fixture.coordinator.insertReviewedResult()
            #expect(fixture.context.insertedTexts == [draft])
        } else {
            #expect(fixture.coordinator.failure == .provider(.invalidResult))
            #expect(fixture.coordinator.reviewedResult == nil)
            #expect(fixture.coordinator.literalRecoveryTranscript == spoken)
            await #expect(throws: ScribeCoordinatorError.invalidState) {
                try await fixture.coordinator.insertReviewedResult()
            }
            #expect(fixture.context.insertedTexts.isEmpty)
        }
    }

    @Test
    func directDictationNeverReadsOrSendsSelectedText() async throws {
        let provider = CapturingScribeProvider(resultText: "A reviewed draft")
        let fixture = ScribeCoordinatorFixture(provider: provider, selectedText: "private selected content")

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        let request = try #require(await provider.requests.first)
        #expect(!request.input.userMessage.contains("private selected content"))
        #expect(!request.input.userMessage.contains("com.apple.TextEdit"))
        #expect(request.resultBinding != nil)
    }

    @Test
    func mismatchedAttemptBindingCannotReplaceReviewedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(provider: MismatchedBindingScribeProvider())
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.failure == .provider(.invalidResult))
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalTranscript == "Spoken request")
    }

    @Test
    func directDictationNeverSendsSelectedTextToProvider() async throws {
        let provider = CapturingScribeProvider(resultText: "Result")
        let fixture = ScribeCoordinatorFixture(provider: provider, selectedText: "Selected context")

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        let request = await provider.requests.first
        #expect(request?.input.userMessage.contains("Selected context") == false)
        #expect(request?.input.userMessage.contains("com.apple.TextEdit") == false)
    }

    @Test
    func requestAppliesLocalShortcutButDoesNotMapLegacyStyleIntoEnvironment() async throws {
        let suiteName = "ScribePersonalization.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationStore(defaults: defaults)
        try store.save(PersonalizationLibrary(
            shortcuts: [PersonalShortcut(trigger: "Spoken request", template: "Expanded locally")],
            styleProfiles: [WritingStyleProfile(
                name: "TextEdit profile",
                appBundleIdentifier: "com.apple.TextEdit",
                tone: .direct,
                length: .concise,
                punctuation: .minimal,
                formatting: .plainText
            )]
        ))
        let provider = CapturingScribeProvider(resultText: "Result")
        let fixture = ScribeCoordinatorFixture(provider: provider, personalizationStore: store)

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        let request = await provider.requests.first
        #expect(request?.input.userMessage.contains("Expanded locally") == true)
        #expect(request?.input.userMessage.contains("Write a clear, concise draft") == true)
        #expect(request?.input.userMessage.contains("TextEdit profile") == false)
    }

    @Test
    func providerTimeoutRetainsLiteralTranscriptForRetryAndFallback() async throws {
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [
                .delayedSuccess("Too late", .seconds(10)),
                .success("Recovered draft")
            ],
            generationTimeout: .milliseconds(10)
        )

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.literalTranscript == "Spoken request")
        #expect(fixture.coordinator.failure == .provider(.timedOut))
        let timedOutAttempt = fixture.coordinator.activeAttemptID

        await fixture.coordinator.retryGeneration()
        #expect(fixture.coordinator.reviewedResult?.text == "Recovered draft")
        #expect(fixture.coordinator.activeAttemptID != timedOutAttempt)
    }

    @Test
    func providerAuthorizationPrecedesSelectionCapture() async {
        let fixture = ScribeCoordinatorFixture(
            providerActionResolver: {
                throw ScribeProviderFailure(
                    phase: .generation,
                    category: .configurationInvalid,
                    retryDisposition: .reconnect
                )
            }
        )

        await #expect(throws: ScribeProviderFailure.self) {
            try await fixture.coordinator.beginDirectDictation()
        }
        #expect(fixture.context.captureCount == 0)
    }

    @Test
    func actionResolvedAtBeginPinsRecipientAndProviderUntilTheSessionEnds() async throws {
        let firstProvider = CapturingScribeProvider(resultText: "First result")
        let replacementProvider = CapturingScribeProvider(resultText: "Replacement result")
        var selectedAction = ScribeProviderActionSnapshot(
            provider: firstProvider,
            destination: .deepSeek
        )
        let fixture = ScribeCoordinatorFixture(
            provider: firstProvider,
            providerActionResolver: { selectedAction }
        )

        try await fixture.coordinator.prepareTarget()
        selectedAction = ScribeProviderActionSnapshot(
            provider: replacementProvider,
            destination: .advanced(
                origin: "https://replacement.example",
                disclosureVersion: ScribeProviderDisclosure.currentVersion
            )
        )
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(await firstProvider.requests.isEmpty)
        #expect(await replacementProvider.requests.count == 1)
        #expect(fixture.coordinator.reviewedResult?.text == "Replacement result")
    }

    @Test
    func targetChangeBeforeEgressMakesZeroProviderCalls() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let fixture = ScribeCoordinatorFixture(provider: provider)
        try await fixture.coordinator.beginDirectDictation()
        fixture.context.shouldVerify = false

        await fixture.coordinator.finishRecording()

        #expect(await provider.requests.isEmpty)
        #expect(fixture.coordinator.failure == .context(.targetChanged))
        #expect(fixture.coordinator.literalTranscript == "Spoken request")
    }

    @Test
    func slowGenerationMovesToCalmSoftWaitBeforeTheHardDeadline() async throws {
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.delayedSuccess("Draft", .milliseconds(100))],
            generationTimeout: .seconds(1),
            generationSoftWait: .milliseconds(5)
        )
        try await fixture.coordinator.beginDirectDictation()

        let finishing = Task { await fixture.coordinator.finishRecording() }
        for _ in 0..<1_000 {
            if case .generatingSlow = fixture.coordinator.state { break }
            await Task.yield()
        }

        if case .generatingSlow = fixture.coordinator.state {
            // Expected calm soft-wait state.
        } else {
            Issue.record("Expected generation to enter the soft-wait state")
        }
        await finishing.value
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
    }

    @Test
    func targetChangePreventsInsertionAndKeepsDraftAvailable() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("Draft")])
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        fixture.context.shouldVerify = false

        await #expect(throws: ScribeContextError.targetChanged) {
            try await fixture.coordinator.insertReviewedResult()
        }

        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
    }

    @Test
    func unpolishedInsertionNeverOverwritesTheRetainedPolishedDraft() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("Polished draft")])
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        fixture.context.shouldVerify = false

        await #expect(throws: ScribeContextError.targetChanged) {
            try await fixture.coordinator.insertUnpolishedResult()
        }

        #expect(fixture.coordinator.reviewedResult?.text == "Polished draft")
        #expect(fixture.coordinator.literalTranscript == "Spoken request")
        #expect(fixture.context.insertedTexts.isEmpty)
    }

    @Test
    func copyRoutesReturnTheirOwnBytesWithoutClosingTheReview() async throws {
        let polished = ScribeCoordinatorFixture(providerResponses: [.success("Polished draft")])
        try await polished.coordinator.beginDirectDictation()
        await polished.coordinator.finishRecording()
        #expect(polished.coordinator.takeReviewedDraftForCopy() == "Polished draft")
        #expect(polished.coordinator.reviewedHistoryDraft()?.originalText == "Spoken request")
        #expect(polished.coordinator.reviewedHistoryDraft()?.composedText == "Polished draft")
        #expect(polished.coordinator.reviewedResult?.text == "Polished draft")
        #expect(polished.coordinator.literalTranscript == "Spoken request")
        if case .reviewing = polished.coordinator.state {} else {
            Issue.record("Copy must keep the polished review visible")
        }

        let unpolished = ScribeCoordinatorFixture(providerResponses: [.failure(.offline)])
        try await unpolished.coordinator.beginDirectDictation()
        await unpolished.coordinator.finishRecording()
        #expect(unpolished.coordinator.takeUnpolishedDraftForCopy() == "Spoken request")
        #expect(unpolished.coordinator.unpolishedHistoryDraft()?.originalText == "Spoken request")
        #expect(unpolished.coordinator.unpolishedHistoryDraft()?.composedText == nil)
        #expect(unpolished.coordinator.unpolishedHistoryDraft()?.finalText == "Spoken request")
        #expect(unpolished.coordinator.literalTranscript == "Spoken request")
        if case .failed = unpolished.coordinator.state {} else {
            Issue.record("Copy must keep the recovery review visible")
        }
    }

    @Test
    func failedRetryKeepsPriorPolishedDraftVisibleWithRetryAvailable() async throws {
        let fixture = ScribeCoordinatorFixture(provider: FailingRetryScribeProvider())
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        #expect(fixture.coordinator.reviewedResult?.text == "Initial polished draft")

        await fixture.coordinator.retryGeneration()

        #expect(fixture.coordinator.reviewedResult?.text == "Initial polished draft")
        #expect(fixture.coordinator.failure == .provider(.offline))
        #expect(fixture.coordinator.canRetryGeneration)
        if case .reviewing = fixture.coordinator.state {} else {
            Issue.record("A failed retry must retain a visible reviewing state")
        }
    }

    @Test
    func requestCarriesImmutableResolvedEnvironmentAndProtectedLiterals() async throws {
        let casual = WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .casual,
            definitionVersion: 1
        )
        let provider = CapturingScribeProvider(resultText: "Update `parseID`.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            writingEnvironmentPreferences: { .valid([casual]) },
            engine: StubScribeTranscriptionEngine(
                text: "literal camel case parse capital I capital D end literal"
            )
        )

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        let request = try #require(await provider.requests.first)
        #expect(request.input.userMessage.contains("Use relaxed, direct wording") == true)
        #expect(request.input.userMessage.contains("parseID") == true)
        #expect(request.input.userMessage.contains("Slack · Casual") == false)
    }

    @Test
    func malformedLiteralStopsBeforeProviderDispatch() async throws {
        let provider = CapturingScribeProvider(resultText: "Should not run")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "literal camel case parse I D")
        )

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.failure == .literalRepair)
        #expect(await provider.requests.isEmpty)
    }

    @Test
    func targetChangeDuringSuspendedDispatchAuthorizationMakesZeroProviderCalls() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let authorization = SuspendedDispatchAuthorization()
        var fixture: ScribeCoordinatorFixture!
        fixture = ScribeCoordinatorFixture(
            provider: provider,
            providerDispatchAuthorization: { _ in
                await authorization.authorize()
            }
        )
        try await fixture.coordinator.beginDirectDictation()

        let finish = Task { @MainActor in
            await fixture.coordinator.finishRecording()
        }
        await authorization.waitUntilEntered()

        // The authorization closure is an async egress boundary. A target
        // mutation while it is suspended must be caught by the production
        // checkpoint immediately after authorization resumes.
        fixture.context.shouldVerify = false
        await authorization.resume()
        await finish.value

        #expect(await provider.requests.isEmpty)
        #expect(fixture.coordinator.failure == .context(.targetChanged))
        #expect(fixture.coordinator.literalTranscript == "Spoken request")
    }

    @Test
    func coordinatorRejectsWrongRemoteAuthorityAndUnexpectedCancellation() async throws {
        let wrongIdentity = ScribeCoordinatorFixture(provider: WrongIdentityScribeProvider())
        try await wrongIdentity.coordinator.beginDirectDictation()
        await wrongIdentity.coordinator.finishRecording()
        #expect(wrongIdentity.coordinator.failure == .provider(.invalidResult))

        let unexpectedCancellation = ScribeCoordinatorFixture(
            provider: UnexpectedCancellationScribeProvider()
        )
        try await unexpectedCancellation.coordinator.beginDirectDictation()
        await unexpectedCancellation.coordinator.finishRecording()
        #expect(unexpectedCancellation.coordinator.providerFailure?.category == .transportUnavailable)
        #expect(unexpectedCancellation.coordinator.failure == .provider(.offline))
    }

    @Test
    func hardDeadlineReturnsEvenWhenProviderIgnoresCancellation() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: NonCooperativeScribeProvider(),
            generationTimeout: .milliseconds(10)
        )

        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.failure == .provider(.timedOut))
        #expect(fixture.coordinator.state == .failed(
            requestID: fixture.coordinator.activeRequestID,
            error: .timedOut
        ))
    }

    @Test
    func confirmedInsertionClearsAllSessionContent() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("Draft")])
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.insertReviewedResult()

        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalTranscript == nil)
        #expect(fixture.coordinator.activeRequestID == nil)
        #expect(fixture.coordinator.resolvedEnvironment == nil)
        #expect(fixture.coordinator.exactLiterals.isEmpty)
    }

    @Test
    func fiftyInjectedProviderCyclesLeaveNoContentBearingSessionState() async throws {
        let fixture = ScribeCoordinatorFixture()

        for _ in 0..<50 {
            try await fixture.coordinator.beginDirectDictation()
            await fixture.coordinator.finishRecording()
            try await fixture.coordinator.insertReviewedResult()

            #expect(fixture.coordinator.activeRequestID == nil)
            #expect(fixture.coordinator.reviewedResult == nil)
            #expect(fixture.coordinator.literalTranscript == nil)
            #expect(fixture.coordinator.exactLiterals.isEmpty)
        }

        #expect(fixture.context.clearedCaptureIDs.count == 50)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func cancellationDuringGenerationIgnoresLateCompletionAndClearsTransientState() async throws {
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.delayedSuccess("Late", .seconds(10))],
            generationTimeout: .seconds(20)
        )
        try await fixture.coordinator.beginDirectDictation()

        let finishing = Task { await fixture.coordinator.finishRecording() }
        await Task.yield()
        await fixture.coordinator.cancel()
        await finishing.value

        if case .cancelled = fixture.coordinator.state {
            // Expected terminal state.
        } else {
            Issue.record("Expected cancellation to remain terminal")
        }
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.context.clearedCaptureIDs.count == 1)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func lateCompletionFromPriorActionCannotReplaceNewActionReview() async throws {
        let provider = CrossActionLateCompletionProvider()
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            generationTimeout: .seconds(20)
        )

        try await fixture.coordinator.beginDirectDictation()
        let firstFinish = Task { @MainActor in
            await fixture.coordinator.finishRecording()
        }
        await provider.waitForFirstRequest()

        // Cancelling action N and recording action N+1 must create a fresh
        // binding. A non-cooperative transport can still finish action N
        // afterwards, but it has no authority over the new review state.
        await fixture.coordinator.cancel()
        await firstFinish.value
        try await fixture.coordinator.beginDirectDictation()
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.reviewedResult?.text == "New action draft")
        await provider.completeFirstRequest()
        for _ in 0..<20 { await Task.yield() }

        #expect(fixture.coordinator.reviewedResult?.text == "New action draft")
        if case let .reviewing(result) = fixture.coordinator.state {
            #expect(result.text == "New action draft")
        } else {
            Issue.record("A late prior-action completion must not leave review")
        }
    }

    @Test
    func concurrentBeginIsRejectedWhileEngineIsStarting() async throws {
        let engine = ControllableScribeEngine(suspendsStart: true)
        let fixture = ScribeCoordinatorFixture(engine: engine)
        let firstBegin = Task { try await fixture.coordinator.beginDirectDictation() }
        await engine.waitForStartCount(1)

        await #expect(throws: ScribeCoordinatorError.invalidState) {
            try await fixture.coordinator.beginDirectDictation()
        }

        await engine.resumeStart()
        try await firstBegin.value
        await fixture.coordinator.cancel()
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func repeatedStopRunsOnlyOneFinalTranscription() async throws {
        let engine = ControllableScribeEngine(suspendsFinish: true)
        let fixture = ScribeCoordinatorFixture(engine: engine)
        try await fixture.coordinator.beginDirectDictation()

        let firstStop = Task { await fixture.coordinator.finishRecording() }
        await engine.waitForFinishCount(1)
        await fixture.coordinator.finishRecording()

        let finishCount = await engine.finishCount
        #expect(finishCount == 1)
        await engine.resumeFinish()
        await firstStop.value
    }

    @Test
    func cancellingIntentPickerDiscardsPinnedTarget() async throws {
        let fixture = ScribeCoordinatorFixture()
        try await fixture.coordinator.prepareTarget()

        await fixture.coordinator.cancel()

        #expect(fixture.context.discardPreparedTargetCount == 1)
    }

    @Test
    func runtimeTargetPinsOnCaptureAndCancelClearsExactCaptureToken() async throws {
        let process = ApplicationProcessIdentity(
            processIdentifier: 42, bundleIdentifier: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"), incarnation: UUID()
        )
        let target = ApplicationTargetCapture(
            process: process, identityRevision: 1, captureRevision: 1,
            source: .scribeAccessibility, displayName: "Codex"
        )
        let fixture = ScribeCoordinatorFixture(applicationTarget: target)
        var pins: [UUID] = []
        var clears: [UUID] = []
        fixture.coordinator.onTargetPin = { capture, _ in pins.append(capture.id) }
        fixture.coordinator.onTargetClear = { clears.append($0) }

        try await fixture.coordinator.beginDirectDictation()
        #expect(pins == [target.id])
        await fixture.coordinator.cancel()
        #expect(clears == [target.id])
    }

    @Test
    func panelCloseAwaitsCoordinatorCleanupBeforeReturningToIdle() async throws {
        let process = ApplicationProcessIdentity(
            processIdentifier: 43,
            bundleIdentifier: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            incarnation: UUID(),
            launchDate: Date(timeIntervalSince1970: 2)
        )
        let target = ApplicationTargetCapture(
            process: process,
            identityRevision: 1,
            captureRevision: 1,
            source: .scribeAccessibility,
            displayName: "Codex"
        )
        let fixture = ScribeCoordinatorFixture(applicationTarget: target)
        var clears: [UUID] = []
        fixture.coordinator.onTargetClear = { clears.append($0) }
        try await fixture.coordinator.beginDirectDictation()

        await fixture.coordinator.dismissPanel()

        #expect(fixture.coordinator.state == .idle)
        #expect(clears == [target.id])
        #expect(fixture.context.clearedCaptureIDs.count == 1)
    }
}

@MainActor
private final class PersistentMemoryLifecycleSpy: ComposePersistentMemoryContextServing {
    private let audio: StubAudioCaptureService
    var acceptsExplicitSaves = true
    private(set) var microphoneWasLiveAtBegin = false
    private(set) var prepared: ScribePersistentMemorySaveProposal?
    private(set) var confirmed: ScribePersistentMemorySaveProposal?
    private(set) var confirmationCount = 0
    private(set) var clearedActionIDs: [UUID] = []
    private(set) var forgotten = false
    var savedFacts: [ScribeSessionMemoryRecord] = []
    var permitsLocalDraftUse = false
    private let localUseRevision = UUID()
    private(set) var draftFactsCallCount = 0
    private(set) var boundActionID: UUID?

    init(audio: StubAudioCaptureService) { self.audio = audio }

    func seedSavedFact(_ text: String) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        savedFacts.append(.init(
            id: UUID(), scopeKey: ScribeConversationMemoryKey(opaqueValue: "synthetic-memory-scope"),
            text: text, topics: ["general"], provenance: .explicitUser(statementID: UUID()),
            origin: .init(actionID: UUID(), captureID: UUID()),
            createdAt: now, expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
            supersedesRecordID: nil
        ))
    }

    func begin(actionID: UUID, capture: ScribeContextSnapshot) -> Bool {
        microphoneWasLiveAtBegin = audio.startCount > 0
        if acceptsExplicitSaves { boundActionID = actionID }
        return acceptsExplicitSaves
    }

    func rebindAction(
        from oldActionID: UUID, to newActionID: UUID,
        capture: ScribeContextSnapshot
    ) -> Bool {
        guard acceptsExplicitSaves, boundActionID == oldActionID else { return false }
        boundActionID = newActionID
        return true
    }

    func prepareSaveExplicitFact(
        _ text: String, actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> ScribePersistentMemorySaveProposal {
        guard acceptsExplicitSaves else { throw ComposePersistentMemoryRuntimeError.unavailable }
        let scopeKey = ScribeConversationMemoryKey(opaqueValue: "synthetic-memory-scope")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let proposal = ScribePersistentMemorySaveProposal(
            token: .init(id: UUID(), storeID: UUID(), storeIncarnation: UUID(),
                         revision: 0, scopeKey: scopeKey),
            record: .init(
                id: UUID(), scopeKey: scopeKey, text: text, topics: ["general"],
                provenance: .explicitUser(statementID: UUID()),
                origin: .init(actionID: actionID, captureID: capture.id),
                createdAt: now, expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60),
                supersedesRecordID: nil
            )
        )
        prepared = proposal
        return proposal
    }

    func completeSave(
        _ proposal: ScribePersistentMemorySaveProposal,
        decision: ScribePersistentMemorySaveDecision,
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws {
        guard acceptsExplicitSaves, decision == .confirmedByUser,
              prepared == proposal,
              proposal.record.origin.actionID == actionID,
              proposal.record.origin.captureID == capture.id else {
            throw ComposePersistentMemoryRuntimeError.noCurrentAction
        }
        confirmed = proposal
        confirmationCount += 1
    }

    func prepareCorrection(
        oldFact: String, newFact: String, actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> (previous: ScribeSessionMemoryRecord, proposal: ScribePersistentMemorySaveProposal) {
        guard let previous = savedFacts.first(where: { $0.text == oldFact }) else {
            throw ScribePersistentMemoryError.invalidCorrection
        }
        let proposal = try prepareSaveExplicitFact(newFact, actionID: actionID, capture: capture)
        return (previous, proposal)
    }

    func inspect(actionID: UUID, capture: ScribeContextSnapshot) throws -> [ScribeSessionMemoryRecord] {
        guard acceptsExplicitSaves else { throw ComposePersistentMemoryRuntimeError.unavailable }
        return savedFacts
    }

    func draftFacts(
        for spokenRequest: String, actionID: UUID, capture: ScribeContextSnapshot,
        destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryDraftFacts? {
        draftFactsCallCount += 1
        guard acceptsExplicitSaves, permitsLocalDraftUse,
              destination == .legacyLocal else { return nil }
        let relevant = ComposeSessionMemoryRelevance.select(savedFacts, for: spokenRequest)
        guard !relevant.isEmpty else { return nil }
        return .init(recordIDs: relevant.map(\.id), texts: relevant.map(\.text),
                     localUseRevision: localUseRevision)
    }

    func prepareForgetCurrentDocument(
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws -> ScribePersistentMemoryForgetProposal {
        guard acceptsExplicitSaves else { throw ComposePersistentMemoryRuntimeError.unavailable }
        return .init(token: .init(
            id: UUID(), storeID: UUID(), storeIncarnation: UUID(), revision: 0,
            scopeKey: ScribeConversationMemoryKey(opaqueValue: "synthetic-memory-scope")
        ), activeFactCount: savedFacts.count)
    }

    func confirmForgetCurrentDocument(
        _ proposal: ScribePersistentMemoryForgetProposal,
        actionID: UUID, capture: ScribeContextSnapshot
    ) throws {
        guard acceptsExplicitSaves else { throw ComposePersistentMemoryRuntimeError.unavailable }
        savedFacts.removeAll()
        forgotten = true
    }

    func clear(actionID: UUID?) {
        if let actionID { clearedActionIDs.append(actionID) }
        if actionID == nil || actionID == boundActionID { boundActionID = nil }
        prepared = nil
    }
}

@MainActor
private final class SessionMemoryLifecycleSpy: ComposeSessionMemoryContextServing {
    private let audio: StubAudioCaptureService
    private(set) var startedActionID: UUID?
    private(set) var microphoneWasLiveAtBegin = false
    private(set) var clearedActionIDs: [UUID] = []
    var acceptsExplicitCommands = false
    var draftFactsToReturn: ComposeSessionMemoryDraftFacts?
    var draftFactsError: ComposeSessionMemoryContextError?
    private(set) var draftFactsCallCount = 0
    private(set) var performedCommand: ComposeSessionMemoryCommand?
    private(set) var performedNotice: ComposeSessionMemoryNotice?
    private(set) var chosenDraftSelections: [ScribeSessionMemoryDraftSelection] = []

    init(audio: StubAudioCaptureService) { self.audio = audio }

    func begin(actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination) {
        startedActionID = actionID
        microphoneWasLiveAtBegin = audio.startCount > 0
    }

    func rebindAction(
        from oldActionID: UUID, to newActionID: UUID,
        capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) -> Bool {
        guard destination == .legacyLocal, startedActionID == oldActionID else { return false }
        startedActionID = newActionID
        return true
    }

    func draftFacts(
        for spokenRequest: String, actionID: UUID, capture: ScribeContextSnapshot,
        destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryDraftFacts? {
        draftFactsCallCount += 1
        if let draftFactsError { throw draftFactsError }
        return destination == .legacyLocal ? draftFactsToReturn : nil
    }

    func clear(actionID: UUID?) {
        if let actionID { clearedActionIDs.append(actionID) }
    }

    func rememberChosenDraft(
        _ text: String, draftID: UUID, selection: ScribeSessionMemoryDraftSelection,
        actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) -> Bool {
        chosenDraftSelections.append(selection)
        return true
    }

    func perform(
        _ command: ComposeSessionMemoryCommand, actionID: UUID,
        capture: ScribeContextSnapshot, destination: ScribeEgressDestination
    ) throws -> ComposeSessionMemoryNotice {
        guard acceptsExplicitCommands, destination == .legacyLocal else {
            throw ComposeSessionMemoryContextError.unavailable
        }
        performedCommand = command
        let notice = ComposeSessionMemoryNotice(
            requestID: actionID, title: "Remembered for this session", detail: "Saved locally"
        )
        performedNotice = notice
        return notice
    }
}

@MainActor
private final class ScribeCoordinatorFixture {
    let arbiter = VoiceSessionArbiter()
    let context: StubScribeContextService
    let audio = StubAudioCaptureService()
    let engine: any TranscriptionEngine
    let coordinator: ScribeCoordinator

    init(
        providerResponses: [MockScribeProvider.Response] = [.success("Draft")],
        provider: (any ScribeProvider)? = nil,
        providerActionResolver: (@MainActor () async throws -> ScribeProviderActionSnapshot)? = nil,
        selectedText: String = "Selected context",
        bundleIdentifier: String = "com.apple.TextEdit",
        recognitionSignature: TargetRecognitionSignature? = nil,
        selectedTextContext: (any ComposeSelectedTextContextServing)? = nil,
        personalizationStore: PersonalizationStore = PersonalizationStore(),
        environmentRecognizer: WritingEnvironmentRecognizer = WritingEnvironmentRecognizer(),
        writingEnvironmentPreferences: @escaping () -> WritingEnvironmentPreferenceLoadResult = { .absent },
        globalWritingDefaults: @escaping () -> ComposeGlobalWritingDefaults = { .init() },
        applicationWritingDefaults: @escaping @MainActor (ApplicationTargetCapture) -> [ComposeWritingPreferenceValue] = { _ in [] },
        providerDispatchAuthorization: @escaping @MainActor (ScribeProviderActionSnapshot) async -> Bool = { _ in true },
        engine: (any TranscriptionEngine)? = nil,
        generationTimeout: Duration = .seconds(5),
        generationSoftWait: Duration = .seconds(8),
        applicationTarget: ApplicationTargetCapture? = nil,
        performanceRecorder: ScribePerformanceRecorder? = nil,
        noSpeechFeedbackDuration: Duration = .milliseconds(1500)
    ) {
        context = StubScribeContextService(
            selectedText: selectedText,
            bundleIdentifier: bundleIdentifier,
            recognitionSignature: recognitionSignature,
            applicationTarget: applicationTarget
        )
        self.engine = engine ?? StubScribeTranscriptionEngine(text: "Spoken request")
        coordinator = ScribeCoordinator(
            audioCaptureService: audio,
            transcriptionEngine: self.engine,
            provider: provider ?? MockScribeProvider(responses: providerResponses),
            providerActionResolver: providerActionResolver,
            contextService: context,
            sessionArbiter: arbiter,
            selectedTextContext: selectedTextContext,
            personalizationStore: personalizationStore,
            environmentRecognizer: environmentRecognizer,
            writingEnvironmentPreferences: writingEnvironmentPreferences,
            globalWritingDefaults: globalWritingDefaults,
            applicationWritingDefaults: applicationWritingDefaults,
            providerDispatchAuthorization: providerDispatchAuthorization,
            performanceRecorder: performanceRecorder,
            generationTimeout: generationTimeout,
            generationSoftWait: generationSoftWait,
            noSpeechFeedbackDuration: noSpeechFeedbackDuration
        )
    }
}

private struct CoordinatorPerformanceClock: ScribePerformanceClock {
    func nowNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

@MainActor
private final class AdaptiveRuntimeFixture {
    let suite: String
    let defaults: UserDefaults
    let notificationCenter = NotificationCenter()
    let gateStore: AdaptiveScribeFeatureGateStore
    let monitor: AdaptiveScribeReaderMonitor

    init() throws {
        suite = "CadenceTests.AdaptiveRuntime.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        let providerStore = ScribeProviderLibraryStore(defaults: defaults, key: "provider")
        let appStore = ApplicationConfigurationStore(defaults: defaults, key: "apps")
        let presetStore = ScribePresetCatalogStateStore(defaults: defaults, key: "presets")
        let settingsStore = SettingsPresentationStore(defaults: defaults, key: "settings")
        gateStore = AdaptiveScribeFeatureGateStore(defaults: defaults, key: "gates")
        let markers = AdaptiveScribeMigrationMarkerStore(defaults: defaults, keyPrefix: "markers")
        let configuration = try ScribeProviderLibraryConfiguration(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .openAIDirect,
            displayName: "OpenAI",
            normalizedOrigin: "https://api.openai.com",
            baseURL: URL(string: "https://api.openai.com")!,
            requestURL: URL(string: "https://api.openai.com/v1/responses")!,
            selectedModelID: "gpt-test",
            catalogID: nil,
            disclosureVersion: 2,
            acceptedAt: Date(timeIntervalSince1970: 10),
            lastValidatedAt: Date(timeIntervalSince1970: 20),
            credentialReference: .init(rawValue: "credential"),
            isEnabled: true
        )
        try providerStore.save(.init(
            revision: 1,
            configurations: [configuration],
            activeConfigurationID: configuration.id
        ))
        try appStore.save(.init(revision: 1, configurations: []))
        try presetStore.save(.generalNeutral)
        try settingsStore.save(.init(selectedCategory: .general, isAdvancedExpanded: false))
        try gateStore.save(.allEnabled)
        for domain in AdaptiveScribeMigrationDomain.allCases { try markers.markComplete(domain) }
        monitor = AdaptiveScribeReaderMonitor(
            defaults: defaults,
            notificationCenter: notificationCenter,
            readerService: AdaptiveScribeLiveReaderService(
                providerStore: providerStore,
                applicationStore: appStore,
                presetStore: presetStore,
                settingsStore: settingsStore,
                featureGateStore: gateStore,
                markerStore: markers,
                polishedDictationRuntimeAvailable: true
            )
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private actor ControllableScribeEngine: TranscriptionEngine {
    private let suspendsStart: Bool
    private let suspendsFinish: Bool
    private let suspendsCancel: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var cancelContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var finishCount = 0

    init(suspendsStart: Bool = false, suspendsFinish: Bool = false, suspendsCancel: Bool = false) {
        self.suspendsStart = suspendsStart
        self.suspendsFinish = suspendsFinish
        self.suspendsCancel = suspendsCancel
    }

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}
    func isPrepared() async -> Bool { true }
    func prepare() async throws {}
    func startSession() async throws {
        startCount += 1
        if suspendsStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
    }
    func appendAudio(_ chunk: AudioChunk) async {}
    func previewTranscript() async -> PreviewTranscript? { nil }
    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        finishCount += 1
        if suspendsFinish {
            await withCheckedContinuation { finishContinuation = $0 }
        }
        return FinalTranscript(rawText: "Spoken request", cleanedText: "Spoken request", duration: metrics.duration)
    }
    func cancelSession() async {
        if suspendsCancel { await withCheckedContinuation { cancelContinuation = $0 } }
    }
    func statusSummary() async -> String { "Ready" }

    func waitForStartCount(_ expected: Int) async {
        while startCount < expected { await Task.yield() }
    }

    func waitForFinishCount(_ expected: Int) async {
        while finishCount < expected { await Task.yield() }
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resumeFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func waitForCancel() async { while cancelContinuation == nil { await Task.yield() } }
    func resumeCancel() { cancelContinuation?.resume(); cancelContinuation = nil }
}

@MainActor
private final class StubScribeContextService: ScribeContextServing {
    private let selectedText: String
    private let bundleIdentifier: String
    private let recognitionSignature: TargetRecognitionSignature?
    private let applicationTarget: ApplicationTargetCapture
    var shouldVerify = true
    var reviewControlFocusAllowed = false
    var insertionError: Error?
    var beforeSelectedTextPreflight: (() -> Void)?
    var suspendInsertion = false
    private var insertionStartContinuation: CheckedContinuation<Void, Never>?
    private var insertionGate: CheckedContinuation<Void, Never>?
    private(set) var clearedCaptureIDs: [UUID] = []
    private(set) var insertedTexts: [String] = []
    private(set) var discardPreparedTargetCount = 0
    private(set) var captureCount = 0
    private(set) var verificationCount = 0
    private(set) var contextRestoreCount = 0

    init(
        selectedText: String,
        bundleIdentifier: String,
        recognitionSignature: TargetRecognitionSignature?,
        applicationTarget: ApplicationTargetCapture? = nil
    ) {
        self.selectedText = selectedText
        self.bundleIdentifier = bundleIdentifier
        self.recognitionSignature = recognitionSignature
        self.applicationTarget = applicationTarget ?? ApplicationTargetCapture(
            process: ApplicationProcessIdentity(
                processIdentifier: 42,
                bundleIdentifier: bundleIdentifier,
                bundleURL: bundleIdentifier == ComposeTextEditApplicationIdentity.bundleIdentifier
                    ? ComposeTextEditApplicationIdentity.bundleURL
                    : URL(fileURLWithPath: "/Applications/Test.app"),
                incarnation: UUID(),
                launchDate: Date(timeIntervalSince1970: 1)
            ),
            identityRevision: 1,
            captureRevision: 1,
            source: .scribeAccessibility,
            displayName: "Test"
        )
    }

    func prepareTarget() async throws {}

    func capture() throws -> ScribeContextSnapshot {
        captureCount += 1
        return ScribeContextSnapshot(
            target: ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: bundleIdentifier),
            scope: .none,
            selectedText: "",
            verificationToken: "window-a",
            recognitionSignature: recognitionSignature,
            applicationTarget: applicationTarget
        )
    }

    func restoreTargetForContextRefresh(_ capture: ScribeContextSnapshot) async throws {
        contextRestoreCount += 1
        guard shouldVerify else { throw ScribeContextError.targetChanged }
    }

    func verifyTarget(for capture: ScribeContextSnapshot) throws -> Bool {
        verificationCount += 1
        guard shouldVerify else { throw ScribeContextError.targetChanged }
        return true
    }

    func verifyTargetAllowingComposeReviewFocus(for capture: ScribeContextSnapshot) throws -> Bool {
        verificationCount += 1
        guard shouldVerify || reviewControlFocusAllowed else {
            throw ScribeContextError.targetChanged
        }
        return true
    }

    func insert(_ text: String, for capture: ScribeContextSnapshot) async throws -> Bool {
        guard try verifyTarget(for: capture) else { return false }
        if suspendInsertion {
            await withCheckedContinuation { continuation in
                insertionGate = continuation
                insertionStartContinuation?.resume()
                insertionStartContinuation = nil
            }
        }
        if let insertionError { throw insertionError }
        insertedTexts.append(text)
        return true
    }

    func waitForInsertionStart() async {
        if insertionGate != nil { return }
        await withCheckedContinuation { insertionStartContinuation = $0 }
    }

    func resumeInsertion() {
        insertionGate?.resume()
        insertionGate = nil
    }

    func insert(_ text: String, for capture: ScribeContextSnapshot, selectedTextPreflight: @escaping @MainActor () async -> Bool) async throws -> Bool {
        guard try verifyTarget(for: capture) else { return false }
        beforeSelectedTextPreflight?()
        guard await selectedTextPreflight() else { throw ScribeContextError.selectionChanged }
        return try await insert(text, for: capture)
    }

    func clear(_ capture: ScribeContextSnapshot) {
        clearedCaptureIDs.append(capture.id)
    }

    func discardPreparedTarget() { discardPreparedTargetCount += 1 }
}

private final class StubAudioCaptureService: AudioCaptureServing {
    private(set) var isCapturing = false
    private(set) var startCount = 0

    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) throws {
        startCount += 1
        isCapturing = true
        chunkHandler(AudioChunk(samples: [0.1], frameCount: 1, sampleRate: 16_000), 0.1)
    }

    func stopCapture() -> AudioCaptureSessionMetrics {
        isCapturing = false
        return AudioCaptureSessionMetrics(
            duration: 1,
            frameCount: 16_000,
            sampleRate: 16_000,
            speechDetected: true,
            speechFrameCount: 16_000,
            peakLevel: 0.5
        )
    }
}

private actor StubScribeTranscriptionEngine: TranscriptionEngine {
    let text: String
    let failure: WhisperEngineError?

    init(text: String, failure: WhisperEngineError? = nil) {
        self.text = text
        self.failure = failure
    }
    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}
    func isPrepared() async -> Bool { true }
    func prepare() async throws {}
    func startSession() async throws {}
    func appendAudio(_ chunk: AudioChunk) async {}
    func previewTranscript() async -> PreviewTranscript? { nil }
    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        if let failure { throw failure }
        return FinalTranscript(rawText: text, cleanedText: text, duration: metrics.duration)
    }
    func cancelSession() async {}
    func statusSummary() async -> String { "Ready" }
}

private actor SuspendedDispatchAuthorization {
    private let result: Bool
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(result: Bool = true) { self.result = result }

    func authorize() async -> Bool {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
        return result
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor SuspendedSelectedRewriteProvider: ScribeProvider {
    nonisolated let capabilities = ScribeProviderCapabilities.mock
    private var pending: (ScribeProviderRequest, CheckedContinuation<ScribeResult, Never>)?
    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        await withCheckedContinuation { pending = (request, $0) }
    }
    func waitForRequest() async { while pending == nil { await Task.yield() } }
    func complete() {
        guard let (request, continuation) = pending else { return }
        pending = nil
        continuation.resume(returning: .init(requestID: request.id, text: "Shorter draft.", binding: request.resultBinding))
    }
}

private actor CapturingScribeProvider: ScribeProvider {
    nonisolated let capabilities = ScribeProviderCapabilities.mock
    private(set) var requests: [ScribeProviderRequest] = []
    let resultText: String

    init(resultText: String) { self.resultText = resultText }

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        requests.append(request)
        return ScribeResult(requestID: request.id, text: resultText, binding: request.resultBinding)
    }
}

private struct WrongIdentityScribeProvider: ScribeProvider {
    let capabilities = ScribeProviderCapabilities.mock

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        ScribeResult(requestID: UUID(), text: "Wrong authority")
    }
}

private struct MismatchedBindingScribeProvider: ScribeProvider {
    let capabilities = ScribeProviderCapabilities.mock

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        let expected = try #require(request.resultBinding)
        return ScribeResult(
            requestID: request.id,
            text: "Wrong attempt",
            binding: .init(
                requestID: expected.requestID,
                actionRevision: expected.actionRevision,
                attemptRevision: expected.attemptRevision + 1,
                providerKind: expected.providerKind,
                modelID: expected.modelID
            )
        )
    }
}

private struct UnexpectedCancellationScribeProvider: ScribeProvider {
    let capabilities = ScribeProviderCapabilities.mock

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        throw CancellationError()
    }
}

private struct NonCooperativeScribeProvider: ScribeProvider {
    let capabilities = ScribeProviderCapabilities.mock

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                continuation.resume(returning: ScribeResult(
                    requestID: request.id,
                    text: "Late ignored result",
                    binding: request.resultBinding
                ))
            }
        }
    }
}

private actor CrossActionLateCompletionProvider: ScribeProvider {
    nonisolated let capabilities = ScribeProviderCapabilities.mock
    private var requestCount = 0
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstResultContinuation: CheckedContinuation<ScribeResult, Never>?

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        requestCount += 1
        guard requestCount == 1 else {
            return ScribeResult(
                requestID: request.id,
                text: "New action draft",
                binding: request.resultBinding
            )
        }

        let waiters = firstRequestWaiters
        firstRequestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            firstResultContinuation = continuation
        }
    }

    func waitForFirstRequest() async {
        guard requestCount == 0 else { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    func completeFirstRequest() {
        guard let firstResultContinuation else { return }
        firstResultContinuation.resume(returning: ScribeResult(
            requestID: UUID(),
            text: "Late old action draft"
        ))
        self.firstResultContinuation = nil
    }
}

private actor FailingRetryScribeProvider: ScribeProvider {
    nonisolated let capabilities = ScribeProviderCapabilities.mock
    private var attempts = 0

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        attempts += 1
        guard attempts == 1 else { throw ScribeProviderError.offline }
        return ScribeResult(
            requestID: request.id,
            text: "Initial polished draft",
            binding: request.resultBinding
        )
    }
}

private actor RefinementSequenceEngine: TranscriptionEngine {
    private var texts: [String]
    private let suspendsSecondStart: Bool
    private var startCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    init(texts: [String], suspendsSecondStart: Bool = false) {
        self.texts = texts
        self.suspendsSecondStart = suspendsSecondStart
    }
    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}
    func isPrepared() async -> Bool { true }
    func prepare() async throws {}
    func startSession() async throws {
        startCount += 1
        if suspendsSecondStart && startCount == 2 {
            await withCheckedContinuation { startContinuation = $0 }
        }
    }
    func appendAudio(_ chunk: AudioChunk) async {}
    func previewTranscript() async -> PreviewTranscript? { nil }
    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        let text = texts.isEmpty ? "" : texts.removeFirst()
        return FinalTranscript(rawText: text, cleanedText: text, duration: metrics.duration)
    }
    func cancelSession() async {}
    func statusSummary() async -> String { "Ready" }
    func waitUntilStartSuspended() async {
        while startContinuation == nil { await Task.yield() }
    }
    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}

private actor RefinementSequenceProvider: ScribeProvider {
    nonisolated let capabilities = ScribeProviderCapabilities.mock
    private var outputs: [String]
    private(set) var requests: [ScribeProviderRequest] = []
    init(outputs: [String]) { self.outputs = outputs }
    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        requests.append(request)
        guard !outputs.isEmpty else { throw ScribeProviderError.offline }
        return ScribeResult(requestID: request.id, text: outputs.removeFirst(), binding: request.resultBinding)
    }
}

private actor SuspendedRefinementProvider: ScribeProvider {
    nonisolated let capabilities = ScribeProviderCapabilities.mock
    private var count = 0
    private var pending: (ScribeProviderRequest, CheckedContinuation<ScribeResult, Never>)?
    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        count += 1
        if count == 2 {
            return await withCheckedContinuation { pending = (request, $0) }
        }
        return ScribeResult(requestID: request.id, text: count == 1 ? "Initial draft" : "Newer accepted draft", binding: request.resultBinding)
    }
    func waitForSuspendedRequest() async {
        while pending == nil { await Task.yield() }
    }
    func completeSuspendedRequest() {
        guard let (request, continuation) = pending else { return }
        pending = nil
        continuation.resume(returning: .init(requestID: request.id, text: "Stale refinement", binding: request.resultBinding))
    }
}

private actor SuspendedMemoryDraftProvider: ScribeProvider {
    nonisolated let capabilities = ScribeProviderCapabilities.mock
    private var pending: (ScribeProviderRequest, CheckedContinuation<ScribeResult, Never>)?

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        await withCheckedContinuation { pending = (request, $0) }
    }

    func waitForRequest() async {
        while pending == nil { await Task.yield() }
    }

    func complete() {
        guard let (request, continuation) = pending else { return }
        pending = nil
        continuation.resume(returning: .init(
            requestID: request.id, text: "Could you share an update on the refund?",
            binding: request.resultBinding
        ))
    }
}

private actor RefinementDispatchGate {
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func authorize() async -> Bool {
        count += 1
        if count == 2 { await withCheckedContinuation { continuation = $0 } }
        return true
    }
    func waitUntilSuspended() async {
        while continuation == nil { await Task.yield() }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
