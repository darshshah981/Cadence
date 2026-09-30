import Foundation
import Testing
@testable import Cadence

struct ScribeWritingRequestTests {
    @Test
    func generatedBudgetDraftCannotDropAnExplicitNegatedBound() throws {
        let spoken = "Tell Elena the budget is at least $1,200, not at most $1,200."
        // Actual Apple Intelligence output from the exposed fifth reserve.
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "Elena, the budget is at least $1,200.",
                requiredLiterals: [], spokenRequest: spoken
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "Elena, the budget is at least $1,200, not at most $1,200.",
            requiredLiterals: [], spokenRequest: spoken
        ) == "Elena, the budget is at least $1,200, not at most $1,200.")
        #expect(try ScribeRequestPolicy.validateOutput(
            "Elena, the budget is at least $1,200.",
            requiredLiterals: [], spokenRequest: "Tell Elena the budget is at least $1,200."
        ) == "Elena, the budget is at least $1,200.")
    }

    @Test
    func generatedDraftCannotReturnNamedWhetherFrameAsMessage() throws {
        let spoken = "Ask Farah whether we can deploy only after both legal and security approve."
        // Actual Apple Intelligence output from the exposed sixth reserve.
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                spoken, requiredLiterals: [], spokenRequest: spoken
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "Farah, can we deploy only after both legal and security approve?",
            requiredLiterals: [], spokenRequest: spoken
        ) == "Farah, can we deploy only after both legal and security approve?")
        let omar = "Ask Omar whether review can begin only after the logs finish uploading."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "Can you please ask Omar whether review can begin only after the logs finish uploading?",
                requiredLiterals: [], spokenRequest: omar
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "Omar, can review begin only after the logs finish uploading?",
            requiredLiterals: [], spokenRequest: omar
        ) == "Omar, can review begin only after the logs finish uploading?")
    }

    @Test
    func generatedPriceDraftCannotDropTheExplicitPeriodContrast() throws {
        let spoken = "The price is $149 per year, not $149 per month. Make this concise."
        // Actual Apple Intelligence output from the exposed sixth reserve.
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "The price is $149 per year.", requiredLiterals: [], spokenRequest: spoken
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "The price is $149 per year, not $149 per month.",
            requiredLiterals: [], spokenRequest: spoken
        ) == "The price is $149 per year, not $149 per month.")
        #expect(try ScribeRequestPolicy.validateOutput(
            "The price is $149 per year, not per month.",
            requiredLiterals: [], spokenRequest: spoken
        ) == "The price is $149 per year, not per month.")
    }

    @Test
    func generatedTaxAndPercentDraftsCannotLoseOrInvertExplicitContrasts() throws {
        let tax = "Tell Leo the total is $1,045.50 including tax, not before tax."
        let percent = "The fee increased by 4%, not by 4 percentage points. Make this concise."
        // Actual Apple Intelligence drafts from the exposed seventh reserve.
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "Leo, the total is $1,045.50 including tax.",
                requiredLiterals: [], spokenRequest: tax
            )
        }
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "The fee increased by 4 percentage points, not by 4%.",
                requiredLiterals: [], spokenRequest: percent
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "Leo, the total is $1,045.50 including tax, not before tax.",
            requiredLiterals: [], spokenRequest: tax
        ) == "Leo, the total is $1,045.50 including tax, not before tax.")
        #expect(try ScribeRequestPolicy.validateOutput(
            "The fee increased by 4%, not by 4 percentage points.",
            requiredLiterals: [], spokenRequest: percent
        ) == "The fee increased by 4%, not by 4 percentage points.")
        let rate = "The rate rose by 6%, not by 6 percentage points. Make this concise."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "The rate rose by 6 percentage points, not by 6%.",
                requiredLiterals: [], spokenRequest: rate
            )
        }
        try ScribeRequestPolicy.validateOutput(
            "The rate rose by 6%, not by 6 percentage points.",
            requiredLiterals: [], spokenRequest: rate
        )
    }

    @Test
    func quotedIdentifierDraftCannotDropItsNamedRecipient() throws {
        let spoken = "Tell Jo to include the exact identifier \"CASE_17B\" in the update and not rename it."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                "Include the identifier \"CASE_17B\" in the update and do not rename it.",
                spokenRequest: spoken, protectedValues: ["CASE_17B"]
            )
        }
        try ScribeRequestPolicy.validateDirectDraftRecipient(
            "Jo, include the exact identifier \"CASE_17B\" in the update and do not rename it.",
            spokenRequest: spoken, protectedValues: ["CASE_17B"]
        )
    }

    @Test
    func generatedQuestionMustKeepExplicitAlternativeAndNumericContrast() throws {
        let booking = "Ask Blair if the booking is confirmed for April 7 or only requested."
        let limit = "Tell Dana the limit is under $600, not exactly $600."
        // Both are actual unsafe READY drafts from the ninth reserve.
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "Blair, is the booking confirmed for April 7?",
                requiredLiterals: [], spokenRequest: booking
            )
        }
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "Dana, the limit is under $600.",
                requiredLiterals: [], spokenRequest: limit
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "Blair, is the booking confirmed for April 7 or only requested?",
            requiredLiterals: [], spokenRequest: booking
        ) == "Blair, is the booking confirmed for April 7 or only requested?")
        #expect(try ScribeRequestPolicy.validateOutput(
            "Dana, the limit is under $600, not exactly $600.",
            requiredLiterals: [], spokenRequest: limit
        ) == "Dana, the limit is under $600, not exactly $600.")
    }

    @Test
    func quotedPhraseSummaryCannotReturnTheWriterFrame() throws {
        let spoken = "Tell Mira to include the exact phrase \"pending verification\" in the summary and not claim approval."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                spoken, spokenRequest: spoken, protectedValues: ["pending verification"]
            )
        }
        try ScribeRequestPolicy.validateDirectDraftRecipient(
            "Mira, include the exact phrase \"pending verification\" in the summary and do not claim approval.",
            spokenRequest: spoken, protectedValues: ["pending verification"]
        )
    }

    @Test
    func exactPhraseUpdateMustAddressTheNamedRecipient() throws {
        let speech = "Tell Farah to use the exact phrase \"awaiting final review\" in the update and not imply approval."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                "Please use the exact phrase \"awaiting final review\" in the update and do not imply approval.",
                spokenRequest: speech, protectedValues: ["awaiting final review"]
            )
        }
        try ScribeRequestPolicy.validateDirectDraftRecipient(
            "Farah, use the exact phrase \"awaiting final review\" in the update and do not imply approval.",
            spokenRequest: speech, protectedValues: ["awaiting final review"]
        )
        let payment = "Tell Talia to include the exact phrase \"approval still pending\" in the note and not claim payment."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                payment, spokenRequest: payment, protectedValues: ["approval still pending"]
            )
        }
    }

    @Test(arguments: [
        "Please include https://status.example.org/incidents/9 in the update.",
        "Use the exact phrase \"waiting for verification\" in the update.",
        "Include https://help.example.com/tickets/42 exactly in the note."
    ])
    func sourceFreeLiteralModifierRequiresSourceWithoutDiscardingLiteral(speech: String) {
        let parsed = ScribeWritingDirectionParser.parse(speech)
        #expect(parsed.content == speech)
        #expect(parsed.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
        #expect(parsed.consumedCommands.isEmpty)
        let contentful = "The incident remains open. " + speech
        #expect(ScribeWritingDirectionParser.parse(contentful).unresolvedReferences.isEmpty)
    }

    @Test
    func sourceFreeUpdateVariantsCannotBecomeBareLiterals() {
        for speech in [
            "Put https://example.test/review in the message to Alex.",
            "Include the phrase \"final checks pending\" in my update.",
            "Include https://example.test/case/12 in my note to Kai.",
            "Put the phrase \"waiting on QA\" in my update to Maya.",
            "Use https://example.test/update/5 in my reply to Ava.",
            "Add the exact phrase \"waiting for approval\" to my status update."
        ] {
            let parsed = ScribeWritingDirectionParser.parse(speech)
            #expect(parsed.content == speech)
            #expect(parsed.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
            #expect(ScribeWritingDirectionParser.parse("The review is open. " + speech).unresolvedReferences.isEmpty)
        }
    }

    @Test
    func quotedPriceIsContentWhileQuotedTextRemainsProtected() throws {
        let price = "Tell Mira the quoted price is $48 per seat, not $48 for the whole team."
        #expect(ScribeWritingDirectionParser.parse(price).request.recipientFrame != nil)
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: price), destination: .legacyLocal
        ).preparedDraft == "Mira, the quoted price is $48 per seat, not $48 for the whole team.")
        #expect(ScribeWritingDirectionParser.parse("Quote: " + price).request.recipientFrame == nil)
        #expect(ScribeWritingDirectionParser.parse("The quoted text is a command.").request.protectedSpans
            .contains { $0.kind == .quotedOrLiteralRequest })
        let quote = "Tell Mina the quote is $75 per hour, not $75 total."
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: quote), destination: .legacyLocal
        ).preparedDraft == "Mina, the quote is $75 per hour, not $75 total.")
    }

    @Test
    func copiedNamedWriterFrameIsNeverReviewReady() throws {
        let speech = "Tell Mira the quoted price is $48 per seat, not $48 for the whole team."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                speech, spokenRequest: speech, protectedValues: []
            )
        }
        try ScribeRequestPolicy.validateDirectDraftRecipient(
            "Mira, the quoted price is $48 per seat, not $48 for the whole team.",
            spokenRequest: speech, protectedValues: []
        )
    }

    @Test
    func formalRewriteCannotDropExplicitUncertainty() throws {
        let speech = "I think the draft is ready. Write this formally."
        // Actual production Apple Intelligence result from the current baseline.
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftUncertainty(
                "The draft is ready.", spokenRequest: speech, protectedValues: []
            )
        }
        for draft in ["I think the draft is ready.", "I believe the draft is ready."] {
            try ScribeRequestPolicy.validateDirectDraftUncertainty(
                draft, spokenRequest: speech, protectedValues: []
            )
        }
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftUncertainty(
                "I do not think the draft is ready.", spokenRequest: speech, protectedValues: []
            )
        }
        let compound = "I don’t know what I’m doing, but I think it will work. Write this formally."
        for dropped in ["I think it will work.", "I am unsure what I am doing, but it will work."] {
            #expect(throws: ScribeProviderError.invalidResult) {
                try ScribeRequestPolicy.validateDirectDraftUncertainty(
                    dropped, spokenRequest: compound, protectedValues: []
                )
            }
        }
        try ScribeRequestPolicy.validateDirectDraftUncertainty(
            "I am unsure what I am doing, but I believe it will work.",
            spokenRequest: compound, protectedValues: []
        )
    }

    @Test
    func uncertaintyGuardDoesNotOverrideConfidentLiteralOrCorrectedContent() throws {
        for (speech, draft) in [
            ("I know the draft is ready. Write this formally.", "I know the draft is ready."),
            ("I think the draft is ready. Actually, I know it is ready. Write this formally.", "I know the draft is ready."),
            ("Include the exact phrase “I think”. Write this formally.", "I think"),
            ("Tell Alex to check whether the draft is ready. Write this formally.", "Alex, please check whether the draft is ready.")
        ] {
            try ScribeRequestPolicy.validateDirectDraftUncertainty(
                draft, spokenRequest: speech, protectedValues: []
            )
        }
    }

    @Test
    func directDraftMustKeepExplicitNamedAddressee() throws {
        let spoken = "Make this upbeat and brief. Tell Nora the rehearsal starts at nine."
        // Exact generated result from the exposed U2 cold holdout.
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                "Rehearsal starts at nine.", spokenRequest: spoken, protectedValues: []
            )
        }
        for draft in ["Nora, rehearsal starts at nine.", "Hi Nora! Rehearsal starts at nine."] {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                draft, spokenRequest: spoken, protectedValues: []
            )
        }
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                "Norah, rehearsal starts at nine.", spokenRequest: spoken, protectedValues: []
            )
        }
        try ScribeRequestPolicy.validateDirectDraftRecipient(
            "Zoë, the review starts now.",
            spokenRequest: "Tell Zoë the review starts now.", protectedValues: []
        )
        // Only a recognized addressee is mandatory. Quoted wording and
        // ambiguous multiword names stay on their existing model path.
        try ScribeRequestPolicy.validateDirectDraftRecipient(
            "Please tell Alex to write this formally.",
            spokenRequest: "Include the exact sentence \"Tell Alex to write this formally\".",
            protectedValues: []
        )
        try ScribeRequestPolicy.validateDirectDraftRecipient(
            "The review starts now.",
            spokenRequest: "Tell Alex Chen the review starts now.", protectedValues: []
        )
    }

    @Test
    func directDraftRejectsCopiedWriterCommandButKeepsLiteralAndRecipientCommands() throws {
        let spoken = "Hey, how's it going? Write this formally."
        let parsed = ScribeWritingDirectionParser.parse(spoken)
        #expect(parsed.content == "Hey, how's it going?")
        #expect(parsed.consumedCommands == ["Write this formally"])
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                "Hello, how are you? Write this formally.", spokenRequest: spoken, protectedValues: []
            )
        }
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "Hello, how are you?", spokenRequest: spoken, protectedValues: []
        )
        let literal = "Include the phrase “Write this formally” in the note."
        #expect(ScribeWritingDirectionParser.parse(literal).consumedCommands.isEmpty)
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "Please include “Write this formally” in the note.", spokenRequest: literal, protectedValues: []
        )
        let recipient = "Tell Alex to write this formally."
        #expect(ScribeWritingDirectionParser.parse(recipient).consumedCommands.isEmpty)
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "Alex, please write this formally.", spokenRequest: recipient, protectedValues: []
        )
        let unpunctuated = "Hey how’s it going write this formally"
        #expect(ScribeWritingDirectionParser.parse(unpunctuated).content == "Hey how’s it going")
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                unpunctuated, spokenRequest: unpunctuated, protectedValues: []
            )
        }
        for speech in ["Tell Alex how it’s going write this formally", "We should write this formally"] {
            #expect(ScribeWritingDirectionParser.parse(speech).consumedCommands.isEmpty)
        }
        #expect(ScribeWritingDirectionParser.parse(unpunctuated, protectedValues: ["write this formally"]).consumedCommands.isEmpty)
    }

    @Test
    func directDraftRejectsCopiedEmbeddedWriterDirections() throws {
        let decline = "Tell Ellis I cannot attend the review, and keep the reason private."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                "Ellis, I cannot attend the review, and I will keep the reason private.",
                spokenRequest: decline, protectedValues: []
            )
        }
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "Ellis, I cannot attend the review.", spokenRequest: decline, protectedValues: []
        )
        let polite = "Ask Omar to send the notes by Friday, and make the request polite."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                "Omar, please send the notes by Friday. Make the request polite.",
                spokenRequest: polite, protectedValues: []
            )
        }
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                "Ask Omar to send the notes by Friday.", spokenRequest: polite, protectedValues: []
            )
        }
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "Omar, could you please send the notes by Friday?", spokenRequest: polite, protectedValues: []
        )
    }

    @Test
    func formalGreetingRejectsAnInventedFirstPersonAnswer() throws {
        let spoken = "Hi, how are you doing? Please make it formal."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                "Hello, I am doing well.", spokenRequest: spoken, protectedValues: []
            )
        }
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "Hello, how are you?", spokenRequest: spoken, protectedValues: []
        )
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "Hello, I am doing well.", spokenRequest: "Please write: I am doing well.", protectedValues: []
        )
    }

    @Test
    func trailingClarityCommandKeepsSourceAndCannotReplaceTheDraft() throws {
        let speech = "We need at least two reviewers and no more than four. Write this clearly."
        let parsed = ScribeWritingDirectionParser.parse(speech)
        #expect(parsed.content == "We need at least two reviewers and no more than four.")
        #expect(parsed.consumedCommands == ["Write this clearly"])
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .legacyLocal
        )
        #expect(input.userMessage.contains("Spoken message:\nWe need at least two reviewers and no more than four."))
        #expect(!input.userMessage.contains("Write this clearly"))
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                "Write this clearly.", spokenRequest: speech, protectedValues: []
            )
        }
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "We need at least two reviewers and no more than four.",
            spokenRequest: speech, protectedValues: []
        )
        #expect(ScribeWritingDirectionParser.parse("Write this clearly.").unresolvedReferences.count == 1)
        #expect(ScribeWritingDirectionParser.parse(
            "Include the exact phrase \"Write this clearly\" in the note."
        ).consumedCommands.isEmpty)
        #expect(ScribeWritingDirectionParser.parse("Tell Evan to write this clearly.").consumedCommands.isEmpty)
    }

    @Test(arguments: [
        "Sure, here's a formal version:",
        "Certainly, here is a more formal version of your greeting:",
        "Here’s your formal rewrite:"
    ])
    func formalRewriteIntroductionsAreRejectedWithoutRemovingLiteralContent(preface: String) throws {
        let spoken = "Hey, how’s it going? Write this formally"
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                preface + "\nHello, how are you?", spokenRequest: spoken, protectedValues: []
            )
        }
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            "Hello, how are you?", spokenRequest: spoken, protectedValues: []
        )
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            preface, spokenRequest: "Include the exact phrase “" + preface + "”", protectedValues: []
        )
    }

    @Test
    func newCommandFormsCannotConsumeAnExactLiteral() {
        let speech = "Turn this into two bullet points."
        let protected = ScribeWritingDirectionParser.parse(speech, protectedValues: [speech])
        #expect(protected.content == speech)
        #expect(protected.request.writingDirections.isEmpty)
        #expect(protected.unresolvedReferences.isEmpty)
        let quoted = "Include the phrase “Could you make this more formal?” in the note."
        #expect(ScribeWritingDirectionParser.parse(quoted).content == quoted)
        #expect(ScribeWritingDirectionParser.parse(quoted).request.writingDirections.isEmpty)
    }

    @Test(arguments: ["Turn this into two bullets.", "Could you turn this into two bullet points?",
                      "Please format that as 2 bullet points.", "Would you put it in two bullets please?"])
    func naturalBulletCommandsRequireSource(_ speech: String) {
        let result = ScribeWritingDirectionParser.parse(speech)
        #expect(result.request.writingDirections == [.bullets(count: 2)])
        #expect(result.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
        #expect(result.request.originalTranscript == speech)
        #expect(result.instructions.isEmpty)
    }

    @Test(arguments: ["Turn this into bullet points.", "Put that in bullets.", "Please format it as bullet points."])
    func uncountedBulletCommandsRequireSource(_ speech: String) {
        let parsed = ScribeWritingDirectionParser.parse(speech)
        #expect(parsed.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
        #expect(parsed.request.message == speech)
        #expect(parsed.request.originalTranscript == speech)
    }

    @Test
    func uncountedBulletCommandInsideLiteralIsNotConsumed() {
        let speech = "Include the exact sentence \"Turn this into bullet points\" in the note."
        #expect(ScribeWritingDirectionParser.parse(speech).unresolvedReferences.isEmpty)
    }

    @Test(arguments: ["Could you make this more formal?", "Can you please rewrite this formally?", "Would you keep it formal please?"])
    func politeStyleCommandsRequireSource(_ speech: String) {
        let result = ScribeWritingDirectionParser.parse(speech)
        #expect(result.request.writingDirections == [.tone(.formal)])
        #expect(result.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
    }

    @Test
    func naturalFormattingCommandsSeparateSuppliedMessageAtRequestEdges() {
        let leading = ScribeWritingDirectionParser.parse("Could you format this as two bullet points: The build is ready. Testing starts Tuesday.")
        #expect(leading.content == "The build is ready. Testing starts Tuesday.")
        #expect(leading.request.writingDirections == [.bullets(count: 2)])
        #expect(leading.unresolvedReferences.isEmpty)
        let trailing = ScribeWritingDirectionParser.parse("The build is ready. Testing starts Tuesday. Turn this into two bullet points.")
        #expect(trailing.content == leading.content)
        #expect(trailing.request.writingDirections == leading.request.writingDirections)
        let formal = ScribeWritingDirectionParser.parse("Hello Alex. Could you make this more formal?")
        #expect(formal.content == "Hello Alex.")
        #expect(formal.request.writingDirections == [.tone(.formal)])
    }

    @Test(arguments: ["Ask Alex to turn this into two bullets.", "Could you make the document more formal?",
                      "Tell Maya to format that as two bullet points.", "Turn this into two bullets and email it to Maya.",
                      "Turn this into a table.", "Format this as four bullet points.",
                      "Turn this into two bullets the build is ready.", "Include the exact phrase Could you make this more formal."])
    func recipientTasksAndUnsupportedFormattingRemainMessageContent(_ speech: String) {
        let result = ScribeWritingDirectionParser.parse(speech)
        #expect(result.content == speech)
        #expect(result.request.writingDirections.isEmpty)
        #expect(result.unresolvedReferences.isEmpty)
    }

    @Test(arguments: ["Make this friendlier.", "Make that warmer.", "Keep it brief.", "Make this more polished.", "Make this upbeat and brief."])
    func additionalStandaloneStyleWordsRequireSource(_ speech: String) {
        let result = ScribeWritingDirectionParser.parse(speech)
        #expect(result.request.originalTranscript == speech)
        #expect(result.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
        #expect(!result.request.writingDirections.isEmpty)
        #expect(result.instructions.isEmpty)
    }

    @Test
    func friendlyAndPolishedDirectionsStaySeparateFromRecipientContentAndQuotes() {
        let speech = "Tell Leena the sample arrived. Make this friendlier and brief."
        let result = ScribeWritingDirectionParser.parse(speech)
        #expect(result.content == "Tell Leena the sample arrived.")
        #expect(result.request.writingDirections == [.tone(.warm), .concise])
        let recipient = ScribeWritingDirectionParser.parse("Tell Priya to make the status note friendlier.")
        #expect(recipient.request.writingDirections.isEmpty)
        #expect(recipient.unresolvedReferences.isEmpty)
        let literal = "Write the exact phrase \"Make this friendlier\"."
        #expect(ScribeWritingDirectionParser.parse(literal).content == literal)
        #expect(ScribeWritingDirectionParser.parse(literal).unresolvedReferences.isEmpty)
    }

    @Test
    func observedLeadingUpbeatDirectionKeepsNamedRecipient() {
        let result = ScribeWritingDirectionParser.parse("Make this upbeat and brief. Tell Nora the rehearsal starts at nine.")
        #expect(result.request.writingDirections == [.tone(.upbeat), .concise])
        #expect(result.request.message == "Tell Nora the rehearsal starts at nine.")
        #expect(result.request.preparedMessage == "Nora, the rehearsal starts at nine.")
        #expect(result.unresolvedReferences.isEmpty)
        let recipientTask = ScribeWritingDirectionParser.parse("Tell Nora to make this upbeat and brief.")
        #expect(recipientTask.request.writingDirections.isEmpty)
        #expect(recipientTask.unresolvedReferences.isEmpty)
        let quoted = "Include the exact sentence \"Make this upbeat and brief\"."
        #expect(ScribeWritingDirectionParser.parse(quoted).content == quoted)
    }

    @Test
    func recognizesWarmAndShortLeadingDirection() {
        let speech = "Keep this warm and short. Tell Maya the preview is ready for review."
        let result = ScribeWritingDirectionParser.parse(speech)

        #expect(result.content == "Tell Maya the preview is ready for review.")
        #expect(result.request.writingDirections == [.tone(.warm), .concise])
        #expect(result.instructions == [
            "Use warm, natural wording.",
            "Keep the draft concise without dropping facts or recipient restrictions."
        ])
        #expect(result.unresolvedReferences.isEmpty)
    }

    @Test
    func recognizesExplicitLeadingBulletCount() {
        let result = ScribeWritingDirectionParser.parse(
            "Put this in two bullets: the build is ready and testing starts Tuesday."
        )

        #expect(result.content == "the build is ready and testing starts Tuesday.")
        #expect(result.request.writingDirections == [.bullets(count: 2)])
        #expect(result.instructions == ["Present the message as exactly 2 bullet points."])
    }

    @Test
    func bulletWordsWithoutColonRemainMessageContent() {
        let speech = "Put this in two bullets the build is ready and testing starts Tuesday."
        let result = ScribeWritingDirectionParser.parse(speech)

        #expect(result.content == speech)
        #expect(result.request.writingDirections.isEmpty)
    }

    @Test
    func consumesPromptLengthButProtectsRecipientRestriction() {
        let result = ScribeWritingDirectionParser.parse(
            "Ask Codex to investigate the crash without changing code. Keep the prompt short."
        )

        #expect(result.content == "Ask Codex to investigate the crash without changing code.")
        #expect(result.request.writingDirections == [.concise])
        #expect(result.request.protectedSpans.contains {
            $0.kind == .recipientInstruction && $0.value == result.content
        })
    }

    @Test
    func consumesCompoundPolitenessAndNoReasonDirection() {
        let result = ScribeWritingDirectionParser.parse(
            "Tell Jo I cannot attend. Keep it polite and do not give a reason."
        )

        #expect(result.content == "Tell Jo I cannot attend.")
        #expect(result.request.writingDirections == [.tone(.polite), .avoidGivingReason])
    }

    @Test
    func recipientFacingInstructionIsNeverConsumedAsWritingDirection() {
        let speech = "Tell Alex to keep the announcement casual."
        let result = ScribeWritingDirectionParser.parse(speech)

        #expect(result.content == speech)
        #expect(result.instructions.isEmpty)
        #expect(result.unresolvedReferences.isEmpty)
        #expect(result.request.protectedSpans.contains {
            $0.kind == .recipientInstruction && $0.value == speech
        })
    }

    @Test
    func lastToneWinsWhileLengthDirectionRemains() {
        let result = ScribeWritingDirectionParser.parse(
            "Write this formally. Hello there. Keep this warm and short."
        )

        #expect(result.content == "Hello there.")
        #expect(result.request.writingDirections == [.tone(.warm), .concise])
    }

    @Test
    func trailingCommandsUseSpokenOrderAndLastToneWins() {
        let result = ScribeWritingDirectionParser.parse(
            "Hello there. Keep this casual. Write this formally."
        )

        #expect(result.content == "Hello there.")
        #expect(result.request.writingDirections == [.tone(.formal)])
    }

    @Test
    func compoundToneUsesTheLastSpokenTone() {
        let result = ScribeWritingDirectionParser.parse(
            "Hello there. Keep this warm and formal."
        )

        #expect(result.content == "Hello there.")
        #expect(result.request.writingDirections == [.tone(.formal)])
    }

    @Test
    func commandOnlyTransformNeedsSourceWithoutChangingTranscript() {
        let speech = "Make this shorter."
        let result = ScribeWritingDirectionParser.parse(speech)

        #expect(result.request.originalTranscript == speech)
        #expect(result.content == speech)
        #expect(result.request.writingDirections == [.concise])
        #expect(result.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
    }

    @Test
    func recipientCommandWithSourceLikeWordsDoesNotNeedSource() {
        let speech = "Ask Alex to make this shorter."
        let result = ScribeWritingDirectionParser.parse(speech)

        #expect(result.content == speech)
        #expect(result.unresolvedReferences.isEmpty)
        #expect(result.instructions.isEmpty)
    }

    @Test
    func quotedUnicodeSourceAndExactLiteralArePreservedByteForByte() {
        let speech = "Include the exact sentence “Keep it casual” for José."
        let result = ScribeWritingDirectionParser.parse(speech, protectedValues: ["José"])

        #expect(result.request.originalTranscript == speech)
        #expect(result.content == speech)
        #expect(result.instructions.isEmpty)
        #expect(result.request.protectedSpans.contains {
            $0.kind == .exactLiteral && $0.value == "José"
        })
        #expect(result.request.protectedSpans.contains {
            $0.kind == .quotedOrLiteralRequest && $0.value == speech
                && $0.utf16Range == 0..<(speech as NSString).length
        })
    }

    @Test
    func preparesUnambiguousNamedTellWithoutChangingMessage() {
        let speech = "Tell Zoë I will be late. Keep it casual."
        let result = ScribeWritingDirectionParser.parse(speech)

        #expect(result.content == "Tell Zoë I will be late.")
        #expect(result.request.originalTranscript == speech)
        #expect(result.request.writingDirections == [.tone(.casual)])
        #expect(result.request.recipientFrame == .init(
            kind: .tell,
            recipient: .named("Zoë"),
            body: "I will be late."
        ))
        #expect(result.request.preparedMessage == "Zoë, I will be late.")
    }

    @Test
    func preparesNamedAskAndRetainsRecipientRestriction() {
        let speech = "Ask Codex to investigate the crash without changing code. Make this a concise prompt."
        let result = ScribeWritingDirectionParser.parse(speech)

        #expect(result.content == "Ask Codex to investigate the crash without changing code.")
        #expect(result.request.writingDirections == [.concise])
        #expect(result.request.preparedMessage == "Codex, please investigate the crash without changing code.")
        #expect(result.request.protectedSpans.contains {
            $0.kind == .recipientInstruction && $0.value == result.content
        })
    }

    @Test
    func preparesCodingAgentPromptDirectly() {
        let result = ScribeWritingDirectionParser.parse(
            "Ask the coding agent why the login flow fails. Keep the prompt short."
        )

        #expect(result.content == "Ask the coding agent why the login flow fails.")
        #expect(result.request.recipientFrame == .init(
            kind: .ask,
            recipient: .codingAgent,
            body: "why the login flow fails."
        ))
        #expect(result.request.preparedMessage == "why the login flow fails.")
    }

    @Test
    func rejectsAmbiguousOrPossessiveRecipientNames() {
        let multiword = ScribeWritingDirectionParser.parse("Tell Alex Chen to make this shorter.")
        let possessive = ScribeWritingDirectionParser.parse("Tell Alex's manager to make this shorter.")

        #expect(multiword.request.recipientFrame == nil)
        #expect(multiword.request.preparedMessage == nil)
        #expect(possessive.request.recipientFrame == nil)
        #expect(possessive.request.preparedMessage == nil)
    }

    @Test
    func quotedRecipientInstructionIsNeverPrepared() {
        let speech = "Include the exact phrase “Tell Maya to make this concise”."
        let result = ScribeWritingDirectionParser.parse(speech)

        #expect(result.content == speech)
        #expect(result.request.recipientFrame == nil)
        #expect(result.request.preparedMessage == nil)
    }

    @Test
    func removesOnlyLeadingConversationalSetupBeforeSupportedDirection() {
        let result = ScribeWritingDirectionParser.parse(
            "Okay, can you help me with this? The build is ready. Write this formally."
        )

        #expect(result.content == "The build is ready.")
        #expect(result.request.writingDirections == [.tone(.formal)])
    }

    @Test
    func preservesConversationalSetupWithoutDirectionOrBeforeRecipient() {
        let soleQuestion = "Okay, can you help with this?"
        let recipient = "Okay, can you help with this? Tell Maya I will be late. Keep it casual."

        #expect(ScribeWritingDirectionParser.parse(soleQuestion).content == soleQuestion)
        #expect(ScribeWritingDirectionParser.parse(recipient).content ==
            "Okay, can you help with this? Tell Maya I will be late.")
    }

    @Test
    func upbeatCorrectedDayCueIsLimitedToPositiveNamedRecipientAnnouncement() throws {
        let included = "Tell Ava the launch is Thursday, actually Friday. Keep it upbeat."
        let request = ScribeRequest.directDictation(processedDictation: included)
        let local = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        let cue = "This is a positive announcement with an explicitly corrected day."
        #expect(local.systemMessage.contains(cue))
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: request, destination: .deepSeek
        ).systemMessage.contains(cue) == false)
        for excluded in [
            "Tell Ava the launch is canceled Thursday, actually Friday. Keep it upbeat.",
            "Tell Ava the launch might be Thursday, actually Friday. Keep it upbeat.",
            "Tell Ava the launch is Thursday, actually Friday. Keep it formal.",
            "Tell Ava the launch is Thursday, actually Friday. Also mention testing. Keep it upbeat.",
            "The launch is Thursday, actually Friday. Keep it upbeat."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: excluded), destination: .legacyLocal
            )
            #expect(!input.systemMessage.contains(cue))
        }
    }

    @Test
    func explicitStatusAndMessageFramesKeepTheirNamedRecipient() throws {
        for (speech, message) in [
            ("Tell Leo ticket AB-1042 is still open.", "Leo, ticket AB-1042 is still open."),
            ("Tell Ana do not send the proposal unless legal approves it.", "Ana, do not send the proposal unless legal approves it."),
            ("Tell Devon not to merge the branch unless the tests pass.", "Devon, do not merge the branch unless the tests pass."),
            ("Draft a message to Pat saying I will send the files tomorrow.", "Pat, I will send the files tomorrow."),
            ("Draft a note to Luis saying the invitation was sent yesterday, but acceptance is still pending.",
             "Luis, the invitation was sent yesterday, but acceptance is still pending.")
        ] {
            let parsed = ScribeWritingDirectionParser.parse(speech)
            #expect(parsed.request.preparedMessage == message)
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            )
            #expect(input.userMessage.contains("Spoken message:\n" + message))
            #expect(throws: ScribeProviderError.invalidResult) {
                try ScribeRequestPolicy.validateDirectDraftRecipient(
                    String(message.dropFirst(message.prefix(while: { $0 != "," }).count + 2)),
                    spokenRequest: speech, protectedValues: []
                )
            }
        }
    }

    @Test
    func boundedRecipientFramesLeaveAmbiguousNamesAndQuotesUntouched() {
        for speech in [
            "Tell Alex Chen ticket AB-1042 is still open.",
            "Tell alex ticket AB-1042 is still open.",
            "Draft a message to Pat Chen saying the files arrive tomorrow.",
            "Tell Leo ticket.",
            "Include the exact phrase “Tell Leo ticket AB-1042 is still open”."
        ] {
            #expect(ScribeWritingDirectionParser.parse(speech).request.recipientFrame == nil)
        }
    }

    @Test
    func formalTwoEventCuePreservesOccurredVersusScheduledStatus() throws {
        let spoken = "The meeting was Monday and the demo is scheduled for Wednesday. Write this formally."
        let cue = "Preserve temporal status: the meeting already took place on Monday, while only the demo is scheduled for Wednesday. Do not describe the meeting as merely scheduled."
        let request = ScribeRequest.directDictation(processedDictation: spoken)
        let local = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(local.systemMessage.contains(cue))
        for excluded in [
            "The meeting was scheduled for Monday and the demo is scheduled for Wednesday. Write this formally.",
            "The meeting was Monday and the demo is scheduled for Wednesday. Make it casual.",
            "The meeting was Monday and the demo is scheduled for Wednesday. Also mention testing. Write this formally.",
            "Quote: The meeting was Monday and the demo is scheduled for Wednesday. Write this formally."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: excluded), destination: .legacyLocal
            )
            #expect(!input.systemMessage.contains("Preserve temporal status:"))
        }
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: request, destination: .deepSeek
        ).systemMessage.contains("Preserve temporal status:") == false)
    }

    @Test
    func pastEventCannotBecomeAnotherScheduledEvent() throws {
        let speech = "The meeting was Monday and the demo is scheduled for Wednesday. Write this formally."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "The meeting was scheduled for Monday, and the demo is scheduled for Wednesday.",
                requiredLiterals: [], spokenRequest: speech
            )
        }
        try ScribeRequestPolicy.validateOutput(
            "The meeting took place on Monday, and the demo is scheduled for Wednesday.",
            requiredLiterals: [], spokenRequest: speech
        )
        try ScribeRequestPolicy.validateOutput(
            "The meeting was scheduled for Monday, and the demo is scheduled for Wednesday.",
            requiredLiterals: [],
            spokenRequest: "The meeting was scheduled for Monday and the demo is scheduled for Wednesday."
        )
    }

    @Test
    func explicitNamedReplyFramesCannotLoseTheirRecipient() throws {
        for (speech, name, body) in [
            ("Reply to Noor: Thursday works for a call, but only after 3 p.m. ET.",
             "Noor", "Thursday works for a call, but only after 3 p.m. ET."),
            ("Write this as a response to Jae: I appreciate the invitation, but I cannot attend. Do not give a reason.",
             "Jae", "I appreciate the invitation, but I cannot attend. Do not give a reason.")
        ] {
            let parsed = ScribeWritingDirectionParser.parse(speech)
            #expect(parsed.request.recipientFrame == .init(
                kind: .tell, recipient: .named(name), body: body
            ))
            #expect(throws: ScribeProviderError.invalidResult) {
                try ScribeRequestPolicy.validateDirectDraftRecipient(
                    body, spokenRequest: speech, protectedValues: []
                )
            }
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                "\(name), \(body)", spokenRequest: speech, protectedValues: []
            )
        }
        for ambiguous in [
            "Reply to Noor Ahmed: Thursday works for a call.",
            "Reply to noor: Thursday works for a call.",
            "Write this as a response to Jae and Pat: I cannot attend.",
            "Quote: Reply to Noor: Thursday works for a call."
        ] {
            #expect(ScribeWritingDirectionParser.parse(ambiguous).request.recipientFrame == nil)
        }
    }
}
