import Foundation
import Testing
@testable import Cadence

struct ScribeDraftRefinementPolicyTests {
    @Test
    func shortNamedWarmthCueExcludesProtectedOrNegativeDrafts() throws {
        let cue = "open with Hi and the existing recipient name"
        for (instruction, draft) in [
            ("Make it warmer, and keep it brief.", "Maya, the preview is ready for review."),
            ("Make this message warmer. Keep the quoted phrase unchanged.",
             "Alex, please include the phrase \"Make it shorter\" in the review note.")
        ] {
            let input = try ScribeDraftRefinementPolicy.providerSafeInput(
                for: makeRequest(instruction: instruction, draft: draft), destination: .legacyLocal
            )
            #expect(input.systemMessage.contains(cue))
            #expect(input.userMessage.contains(draft))
        }
        for (instruction, draft) in [
            ("Make it shorter.", "Maya, the preview is ready for review."),
            ("Make it warmer.", "Maya, I cannot attend."),
            ("Make it warmer.", "Hi Maya, the preview is ready."),
            ("Make it warmer without a greeting.", "Maya, the preview is ready."),
            ("Make it warmer, but do not add a greeting.", "Maya, the preview is ready."),
            ("Make it warmer.", "Hi, the preview is ready."),
            ("Make it warmer.", "The preview is ready for Maya."),
            ("Make it warmer.", "Maya, the preview is ready.\nReview it today.")
        ] {
            let input = try ScribeDraftRefinementPolicy.providerSafeInput(
                for: makeRequest(instruction: instruction, draft: draft), destination: .legacyLocal
            )
            #expect(!input.systemMessage.contains(cue))
        }
        let protected = try ScribeDraftRefinementPolicy.providerSafeInput(
            for: makeRequest(instruction: "Make it warmer.",
                             draft: "Maya, the preview is ready for review.",
                             protected: ["Maya, the preview is ready for review."]),
            destination: .legacyLocal
        )
        #expect(!protected.systemMessage.contains(cue))
    }

    @Test
    func compilerOnlyAcceptsExactLocalDestinationAndDoesNotSerializeOrigin() throws {
        let request = makeRequest()
        let input = try ScribeDraftRefinementPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(input.userMessage.contains(request.baseDraft))
        #expect(input.userMessage.contains("Edit request: " + request.token.instruction.utterance))
        #expect(input.userMessage.contains("Message to edit:\n" + request.baseDraft))
        #expect(!input.userMessage.contains(request.token.origin.captureID.uuidString))
        #expect(!input.userMessage.contains("com.example.private-target"))
        let rejected: [ScribeEgressDestination] = [
            .openAIDirect, .openRouter, .deepSeek,
            .init(providerKind: .legacyLocal, recipientOrigin: "https://example.test", disclosureVersion: ScribeProviderDisclosure.currentVersion, isRemote: true),
            .init(providerKind: .legacyLocal, recipientOrigin: "local://this-mac", disclosureVersion: 0, isRemote: false)
        ]
        for destination in rejected {
            #expect(throws: ScribeDraftRefinementError.localProviderRequired) {
                try ScribeDraftRefinementPolicy.providerSafeInput(for: request, destination: destination)
            }
        }
    }

    @Test
    func actualEvaluatedRevisionLeakIsRejectedWithoutStrippingSourceQuotes() throws {
        let base = "Alex, please include the phrase \"Make it shorter\" in the review note."
        let request = makeRequest(
            instruction: "Make this message warmer. Keep the quoted phrase unchanged.",
            draft: base,
            literals: [.init(id: 0, value: "Make it shorter", source: .alreadyExact)]
        )
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeDraftRefinementPolicy.validateOutput(base + "\n\nMake this message warmer.", for: request)
        }
        let valid = "Hi Alex, please include \"Make it shorter\" in the review note."
        #expect(try ScribeDraftRefinementPolicy.validateOutput(valid, for: request) == valid)
        let literalSource = makeRequest(instruction: "Make it warmer.", draft: "The phrase is Make it warmer.")
        #expect(try ScribeDraftRefinementPolicy.validateOutput("Hi, the phrase is Make it warmer.", for: literalSource) == "Hi, the phrase is Make it warmer.")
    }

    @Test
    func sampledNearBareLiteralCannotReplaceSubstantiveReviewedMessage() throws {
        let base = "Alex, please include the phrase \"Make it shorter\" in the review note."
        let request = makeRequest(
            instruction: "Make this message warmer. Keep the quoted phrase unchanged.",
            draft: base,
            literals: [.init(id: 0, value: "Make it shorter", source: .alreadyExact)]
        )
        // An actual local-model sample retained the literal but dropped the
        // instruction to include it in the review note.
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeDraftRefinementPolicy.validateOutput("Hi Alex,\n\nMake it shorter.", for: request)
        }
        let safe = "Hi Alex, please include \"Make it shorter\" in the review note."
        #expect(try ScribeDraftRefinementPolicy.validateOutput(safe, for: request) == safe)

        let bareBase = makeRequest(
            instruction: "Keep the quoted phrase.", draft: "\"Make it shorter\"",
            literals: [.init(id: 0, value: "Make it shorter", source: .alreadyExact)]
        )
        #expect(try ScribeDraftRefinementPolicy.validateOutput("Make it shorter", for: bareBase) == "Make it shorter")
    }

    @Test
    func protectedFirstSentenceMustSurviveByteForByte() throws {
        let request = makeRequest(instruction: "Keep the first sentence. Make the rest warmer.", draft: "The cafe\u{301} is ready. Please review it.", protected: ["The cafe\u{301} is ready."])
        #expect(try ScribeDraftRefinementPolicy.validateOutput("The cafe\u{301} is ready. Please have a look when you can.", for: request).contains("cafe\u{301}"))
        #expect(throws: ScribeDraftRefinementError.protectedTextChanged) {
            try ScribeDraftRefinementPolicy.validateOutput("The café is ready. Please have a look when you can.", for: request)
        }
    }

    @Test
    func revisionCannotDropRecipientRestrictionsOrLeakCompilerLabels() throws {
        let request = makeRequest(restrictions: [.noChanges])
        #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noChanges)) {
            try ScribeDraftRefinementPolicy.validateOutput("Inspect the issue.", for: request)
        }
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeDraftRefinementPolicy.validateOutput("Current draft for revision: Inspect it. Do not make any changes.", for: request)
        }
    }

    @Test
    func exactLiteralsStillApplyToVoiceRevisions() throws {
        let request = makeRequest(literals: [.init(id: 0, value: "build_flag_v2", source: .alreadyExact)])
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeDraftRefinementPolicy.validateOutput("Please check the build flag.", for: request)
        }
        #expect(try ScribeDraftRefinementPolicy.validateOutput("Please check build_flag_v2.", for: request) == "Please check build_flag_v2.")
    }

    @Test
    func sourceDraftCannotAuthorizeLiteralMutationDuringRefinement() throws {
        let literal = ScribeExactLiteral(id: 0, value: "--verbose", source: .alreadyExact)
        let request = makeRequest(instruction: "Make that warmer.", draft: "Remove --verbose from the command.", literals: [literal])
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeDraftRefinementPolicy.validateOutput("Please remove the verbosity flag from the command.", for: request)
        }
        let authorized = makeRequest(instruction: "Remove --verbose from this draft.", draft: "Run --verbose to inspect the output.", literals: [literal])
        #expect(try ScribeDraftRefinementPolicy.validateOutput("Inspect the output.", for: authorized) == "Inspect the output.")
    }

    @MainActor @Test
    func builderBindsExactBaseVersionAndDerivesFirstSentenceProtection() throws {
        let origin = makeOrigin()
        let store = ScribeDraftRevisionStore()
        let session = store.start(origin: origin, originalSpokenRequest: "Inspect the issue. Do not make any changes.", initialDraft: "Inspect the issue. Do not make any changes.")
        let token = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: "Keep the first sentence. Make that warmer.")
        let original = ScribeRequest.directDictation(id: origin.actionID, processedDictation: session.originalSpokenRequest)
        let request = try ScribeDraftRefinementPolicy.request(token: token, session: session, originalRequest: original)
        #expect(request.baseDraft == session.currentVersion.text)
        #expect(request.protectedText == ["Inspect the issue."])
        #expect(request.recipientRestrictions == [.noChanges])
        let revised = try store.completeRevision(token, refinedDraft: "Please inspect the issue. Do not make any changes.")
        #expect(throws: ScribeDraftRefinementError.invalidOrigin) {
            try ScribeDraftRefinementPolicy.request(token: token, session: revised, originalRequest: original)
        }
    }

    @Test
    func undoRecognitionIsBoundedAndDoesNotConsumeRecipientInstructions() {
        #expect(ScribeDraftRefinementPolicy.isUndoInstruction("Undo that change."))
        #expect(ScribeDraftRefinementPolicy.isUndoInstruction("Undo the last change!"))
        #expect(!ScribeDraftRefinementPolicy.isUndoInstruction("Tell Maya to undo that change."))
        #expect(!ScribeDraftRefinementPolicy.isUndoInstruction("Undo that change and make it warmer."))
        #expect(!ScribeDraftRefinementPolicy.isUndoInstruction("Write the words undo that change."))
    }

    private func makeOrigin() -> ScribeDraftRevisionOrigin {
        .init(actionID: UUID(), captureID: UUID(), target: .init(processIdentifier: 42, bundleIdentifier: "com.example.private-target"), providerActionIdentity: nil)
    }

    private func makeRequest(
        instruction: String = "Make that shorter.", draft: String = "Inspect the issue. Do not make any changes.",
        protected: [String] = [], restrictions: [ScribeRecipientRestriction] = [], literals: [ScribeExactLiteral] = []
    ) -> ScribeDraftRefinementRequest {
        .init(token: .init(id: UUID(), sessionID: UUID(), baseVersionID: UUID(), origin: makeOrigin(), instruction: .init(id: UUID(), utterance: instruction)), baseDraft: draft, exactLiterals: literals, recipientRestrictions: restrictions, protectedText: protected)
    }
}
