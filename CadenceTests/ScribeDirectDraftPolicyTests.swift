import Foundation
import Testing
@testable import Cadence

struct ScribeDirectDraftPolicyTests {
    @Test
    func completeCasualAndConciseStatusesApplyTheRequestedStyleWithoutChangingFacts() throws {
        for (spoken, draft) in [
            ("Tell Arun the draft is ready for review. Make it casual.",
             "Hey Arun, the draft's ready for review."),
            ("Tell Zoë the report is ready for review. Make it casual.",
             "Hey Zoë, the report's ready for review."),
            ("Tell Rina the deck is ready for the team. Make it casual.",
             "Hey Rina, the deck's ready for the team."),
            ("The prototype is ready and the meeting begins Friday. Make this concise.",
             "Prototype ready; the meeting begins Friday."),
            ("The build is ready and the demo begins Tuesday. Make this concise.",
             "Build ready; the demo begins Tuesday."),
            ("The release is ready and the review begins Monday. Make this concise.",
             "Release ready; the review begins Monday."),
            ("The slides are ready and the call starts Thursday. Make this concise.",
             "Slides ready; the call starts Thursday.")
        ] {
            let request = ScribeRequest.directDictation(processedDictation: spoken)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: request, destination: .legacyLocal
            ).preparedDraft == draft)
            #expect(try ScribeRequestPolicy.validateOutput(
                draft, requiredLiterals: [], spokenRequest: spoken
            ) == draft)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: request, destination: .deepSeek
            ).preparedDraft == nil)
        }
        for spoken in [
            "Tell Arun the draft may be ready for review. Make it casual.",
            "Tell Arun the draft is ready for review. Make it casual. Ask about Friday.",
            "Quote: Tell Arun the draft is ready for review. Make it casual.",
            "The prototype is not ready and the meeting begins Friday. Make this concise.",
            "The prototype is ready and the meeting may begin Friday. Make this concise.",
            "The prototype is ready and the meeting begins Friday. Make this concise. Also ask for confirmation."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: spoken), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func quotedCodingInspectionDropsOnlyTheSpokenRecipientFrame() throws {
        for (spoken, draft) in [
            (
                "Ask Codex to inspect `src/Auth.swift` with --no-cache without editing files.",
                "Inspect `src/Auth.swift` with --no-cache without editing files."
            ),
            (
                "Ask Claude to find `make it shorter` in src/Copy.swift without changing code.",
                "Find `make it shorter` in src/Copy.swift without changing code."
            )
        ] {
            let local = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: spoken), destination: .legacyLocal
            )
            #expect(local.preparedDraft == draft)
            let literals = ScribeRequestPolicy.directCodingLiterals(in: spoken, existing: [])
            #expect(try ScribeRequestPolicy.validateOutput(
                draft, requiredLiterals: literals, spokenRequest: spoken
            ) == draft)
            try ScribeRecipientRestrictionPolicy.validate(
                output: draft,
                requirements: ScribeRecipientRestrictionPolicy.extract(from: spoken)
            )
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: spoken), destination: .deepSeek
            ).preparedDraft == nil)
        }
        for unsupported in [
            "Ask Codex to inspect `src/Auth.swift` and then fix it.",
            "Ask Codex to inspect `src/Auth.swift`. Also edit the tests.",
            "Ask Codex to fix `src/Auth.swift` without editing files.",
            "Ask Codex to inspect `src/Auth.swift without editing files.",
            "Ask Codex to inspect `make it shorter` without editing files."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func shortCompleteNamedConstraintsKeepTheirSourceWording() throws {
        for (speech, draft) in [
            ("Tell Paul the total is $68 including shipping, but not taxes.",
             "Paul, the total is $68 including shipping, but not taxes."),
            ("Tell Lea the fee is €34 per user, not €34 total.",
             "Lea, the fee is €34 per user, not €34 total."),
            ("Tell Bea the refund may arrive Friday, but it has not been issued.",
             "Bea, the refund may arrive Friday, but it has not been issued.")
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            ).preparedDraft == draft)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .deepSeek
            ).preparedDraft == nil)
        }
        for unsupported in [
            "Tell Bea the refund may arrive Friday, actually Saturday.",
            "Tell Bea the refund may arrive Friday. Also ask about the bank.",
            "Tell Bea to rewrite this if the refund arrives.",
            "Tell Bea Chen the refund may arrive Friday.",
            "Tell Bea the refund may arrive Friday. Write this formally.",
            "Quote: Tell Bea the refund may arrive Friday."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func simpleNamedProhibitionBecomesMessageWithoutLosingCondition() throws {
        for (speech, draft) in [
            ("Tell Devon not to merge the branch unless the tests pass.",
             "Devon, do not merge the branch unless the tests pass."),
            ("Tell Zoë not to delete the notes before review.",
             "Zoë, do not delete the notes before review."),
            ("Tell Omar do not publish unless legal signs off.",
             "Omar, do not publish unless legal signs off.")
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            let local = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
            #expect(local.preparedDraft == draft)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: request, destination: .deepSeek
            ).preparedDraft == nil)
        }
        for speech in [
            "Tell Devon not to merge, actually merge after review.",
            "Tell Devon not to merge. Ask about the tests.",
            "Tell Devon Lee not to merge the branch.",
            "Tell Omar do not publish, actually publish after review.",
            "Quote: Tell Devon not to merge the branch."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func completeNamedTicketStatusKeepsRecipientAndIdentifier() throws {
        for (speech, draft) in [
            ("Tell Leo ticket AB-1042 is still open.", "Leo, ticket AB-1042 is still open."),
            ("Tell Zoë issue ZX_7 is pending.", "Zoë, issue ZX_7 is pending."),
            ("Tell Mira case CF-21 is resolved.", "Mira, case CF-21 is resolved."),
            ("Tell Lena case RS-42 remains open until QA closes it.",
             "Lena, case RS-42 remains open until QA closes it.")
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            let local = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
            #expect(local.preparedDraft == draft)
            #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
        }
        for speech in [
            "Tell Leo ticket AB-1042 is still open. Ask about payment.",
            "Tell Leo ticket AB-1042 is still open, actually closed.",
            "Tell Leo ticket AB-1042 might be open.",
            "Tell Leo Chen ticket AB-1042 is still open.",
            "Quote: Tell Leo ticket AB-1042 is still open."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func exactPhraseNoteAddressesRecipientWithoutTurningPhraseIntoWriterInstruction() throws {
        let speech = "Include the exact phrase \"Write this formally\" in a note to Pat."
        let request = ScribeRequest.directDictation(processedDictation: speech)
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(input.preparedDraft == "Pat, “Write this formally”")
        #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateDirectDraftRecipient(
                "Write this formally to Pat.", spokenRequest: speech,
                protectedValues: ["Write this formally"]
            )
        }
        try ScribeRequestPolicy.validateDirectDraftRecipient(
            "Pat, “Write this formally”", spokenRequest: speech,
            protectedValues: ["Write this formally"]
        )
        for changed in [
            "Include the exact phrase \"Write this formally\" in a note to Pat. Also ask about launch.",
            "Include the exact phrase \"Write this formally\" in a note to Pat and Sam.",
            "Tell Pat to include the exact phrase \"Write this formally\"."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: changed), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func completeNamedRepliesKeepAddresseeAndDoNotCopyWriterInstruction() throws {
        for (speech, draft) in [
            ("Reply to Noor: Thursday works for a call, but only after 3 p.m. ET.",
             "Noor, Thursday works for a call, but only after 3 p.m. ET."),
            ("Write this as a response to Jae: I appreciate the invitation, but I cannot attend. Do not give a reason.",
             "Jae, I appreciate the invitation, but I cannot attend.")
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: request, destination: .legacyLocal
            ).preparedDraft == draft)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: request, destination: .deepSeek
            ).preparedDraft == nil)
        }
        for unsupported in [
            "Reply to Noor: Actually, Thursday works for a call.",
            "Reply to Noor: Please write a response about Thursday.",
            "Reply to Noor Ahmed: Thursday works for a call.",
            "Write this as a response to Jae: I cannot attend. Do not give a reason.",
            "Write this as a response to Jae: I appreciate the invitation, but I cannot attend because I am busy. Do not give a reason."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func completeNamedBudgetContrastKeepsBothBounds() throws {
        for (speech, draft) in [
            ("Tell Elena the budget is at least $1,200, not at most $1,200.",
             "Elena, the budget is at least $1,200, not at most $1,200."),
            ("Tell Zoë the budget is at most $950, not at least $950.",
             "Zoë, the budget is at most $950, not at least $950.")
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: request, destination: .legacyLocal
            ).preparedDraft == draft)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: request, destination: .deepSeek
            ).preparedDraft == nil)
        }
        for unsupported in [
            "Tell Elena the budget is at least $1,200, not at most $1,500.",
            "Tell Elena the budget is at least $1,200, not at least $1,200.",
            "Tell Elena the budget is at least $1,200, not at most $1,200. Also ask for approval.",
            "Quote: Tell Elena the budget is at least $1,200, not at most $1,200."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func twoApprovalQuestionBecomesAQuestionToTheRecipient() throws {
        let speech = "Ask Farah whether we can deploy only after both legal and security approve."
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .legacyLocal
        ).preparedDraft == "Farah, can we deploy only after both legal and security approve?")
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .deepSeek
        ).preparedDraft == nil)
        for unsupported in [
            "Ask Farah whether we can deploy only after legal approves.",
            "Ask Farah whether we can deploy after either legal or security approve.",
            "Ask Farah whether we can deploy only after both legal and security approve. Also ask about QA.",
            "Quote: Ask Farah whether we can deploy only after both legal and security approve."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func completePricePeriodContrastKeepsTheExplicitCorrection() throws {
        for (speech, draft) in [
            ("The price is $149 per year, not $149 per month. Make this concise.",
             "The price is $149 per year, not $149 per month."),
            ("The price is $29 per month, not $29 per year. Make this concise.",
             "The price is $29 per month, not $29 per year.")
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            ).preparedDraft == draft)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .deepSeek
            ).preparedDraft == nil)
        }
        for unsupported in [
            "The price is $149 per year, not $159 per month. Make this concise.",
            "The price is $149 per year, not $149 per year. Make this concise.",
            "The price is $149 per year, not $149 per month. Also mention the discount.",
            "Quote: The price is $149 per year, not $149 per month. Make this concise."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func namedWhetherQuestionsPreserveTheirExistingConditions() throws {
        for (speech, draft) in [
            ("Ask Nico whether the change is approved for staging only, not production.",
             "Nico, is the change approved for staging only, not production?"),
            ("Ask Ben whether the contract can be signed after counsel approves, but before Friday.",
             "Ben, can the contract be signed after counsel approves, but before Friday?"),
            ("Ask Rhea whether the cancellation applies to the trial only, not paid accounts.",
             "Rhea, does the cancellation apply to the trial only, not paid accounts?"),
            ("Ask Omar whether review can begin only after the logs finish uploading.",
             "Omar, can review begin only after the logs finish uploading?"),
            ("Ask Marc whether the update can wait until Tuesday.",
             "Marc, can the update wait until Tuesday?"),
            ("Ask Blair if the booking is confirmed for April 7 or only requested.",
             "Blair, is the booking confirmed for April 7 or only requested?")
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            ).preparedDraft == draft)
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .deepSeek
            ).preparedDraft == nil)
        }
        for unsupported in [
            "Ask Ben whether the support contract can be signed after counsel approves, but before Friday.",
            "Ask Ben whether the contract can be signed after counsel approves, but before Friday. Also ask about tax.",
            "Ask Rhea whether the cancellation applies to paid accounts only, not the trial.",
            "Ask Omar whether review can begin before the logs finish uploading.",
            "Quote: Ask Rhea whether the cancellation applies to the trial only, not paid accounts."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func explicitTaxAndPercentContrastsKeepBothSides() throws {
        let tax = "Tell Leo the total is $1,045.50 including tax, not before tax."
        let percent = "The fee increased by 4%, not by 4 percentage points. Make this concise."
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: tax), destination: .legacyLocal
        ).preparedDraft == "Leo, the total is $1,045.50 including tax, not before tax.")
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: percent), destination: .legacyLocal
        ).preparedDraft == "The fee increased by 4%, not by 4 percentage points.")
        let rate = "The rate rose by 6%, not by 6 percentage points. Make this concise."
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: rate), destination: .legacyLocal
        ).preparedDraft == "The rate rose by 6%, not by 6 percentage points.")
        for unsupported in [
            "Tell Leo the total is $1,045.50 including tax, not before tax. Also mention shipping.",
            "The fee increased by 4%, not by 5 percentage points. Make this concise.",
            "The fee increased by 4%, not by 4 percentage points. Also explain why."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func quotedIdentifierNoteKeepsNamedRecipientAndLiteral() throws {
        let speech = "Tell Jo to include the exact identifier \"CASE_17B\" in the update and not rename it."
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .legacyLocal
        ).preparedDraft == "Jo, include the exact identifier \"CASE_17B\" in the update and do not rename it.")
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .deepSeek
        ).preparedDraft == nil)
        for unsupported in [
            "Tell Jo to include the exact identifier \"CASE_17B\" in the update and rename it.",
            "Tell Jo to include the exact identifier \"CASE_17B\" in the update and not rename it. Also ask about QA.",
            "Tell Jo Lee to include the exact identifier \"CASE_17B\" in the update and not rename it."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func namedNumericContrastAndQuotedPhraseSummaryPreserveTheirLimits() throws {
        let limit = "Tell Dana the limit is under $600, not exactly $600."
        let phrase = "Tell Mira to include the exact phrase \"pending verification\" in the summary and not claim approval."
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: limit), destination: .legacyLocal
        ).preparedDraft == "Dana, the limit is under $600, not exactly $600.")
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: phrase), destination: .legacyLocal
        ).preparedDraft == "Mira, include the exact phrase \"pending verification\" in the summary and do not claim approval.")
        for unsupported in [
            "Tell Dana the limit is under $600, not exactly $650.",
            "Tell Dana the limit is under $600, not exactly $600. Also ask about tax.",
            "Tell Mira to include the exact phrase \"pending verification\" in the summary and claim approval.",
            "Tell Mira Chen to include the exact phrase \"pending verification\" in the summary and not claim approval."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func exactPhraseRecipientInstructionKeepsTheStatedTarget() throws {
        let speech = "Tell Farah to use the exact phrase \"awaiting final review\" in the update and not imply approval."
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .legacyLocal
        ).preparedDraft == "Farah, use the exact phrase \"awaiting final review\" in the update and do not imply approval.")
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation:
                "Tell Talia to include the exact phrase \"approval still pending\" in the note and not claim payment."),
            destination: .legacyLocal
        ).preparedDraft == "Talia, include the exact phrase \"approval still pending\" in the note and do not claim payment.")
        for unsupported in [
            "Tell Farah Lee to use the exact phrase \"awaiting final review\" in the update and not imply approval.",
            "Tell Farah to use the exact phrase \"awaiting final review\" in the update and not imply approval. Also mention QA.",
            "Quote: Tell Farah to use the exact phrase \"awaiting final review\" in the update and not imply approval."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: unsupported), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func approvalQuestionKeepsTheFileAsTheApprovalSubject() throws {
        let speech = "Ask Robin whether the file needs approval before Friday."
        let request = ScribeRequest.directDictation(processedDictation: speech)
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(input.preparedDraft == "Robin, does the file need approval before Friday?")
        #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
        for changed in [
            "Ask Robin whether the file needs approval before Friday. Also ask about testing.",
            "Ask Robin whether the file needs approval before Friday or after launch.",
            "Ask Robin to check whether the file needs approval before Friday.",
            "Quote: Ask Robin whether the file needs approval before Friday."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: changed), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func twoDistinctStatusesDoNotCarryWriterInstructionIntoMessage() throws {
        let speech = "Tell Sam the invoice is pending and the purchase order is approved. Keep the two statuses distinct."
        let request = ScribeRequest.directDictation(processedDictation: speech)
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(input.preparedDraft == "Sam, the invoice is pending and the purchase order is approved.")
        #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
        for changed in [
            "Tell Sam the invoice is pending and the purchase order is approved. Keep the two statuses distinct. Also ask for payment.",
            "Tell Sam the invoice is pending and the purchase order is approved. Keep the two statuses distinct, but mention the delay.",
            "Quote: Tell Sam the invoice is pending and the purchase order is approved. Keep the two statuses distinct."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: changed), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func politeDeclineDoesNotPromiseToBePoliteOrInventAReason() throws {
        let speech = "Tell Morgan I cannot join the call tonight, and make the reply polite without inventing a reason."
        let request = ScribeRequest.directDictation(processedDictation: speech)
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(input.preparedDraft == "Hi Morgan, I’m sorry, but I cannot join the call tonight.")
        #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
        for changed in [
            "Tell Morgan I cannot join the call tonight because I am sick, and make the reply polite without inventing a reason.",
            "Tell Morgan I cannot join the call tonight, and make the reply polite without inventing a reason. Ask for a new time.",
            "Tell Morgan to make the reply polite without inventing a reason.",
            "Quote: Tell Morgan I cannot join the call tonight, and make the reply polite without inventing a reason."
        ] {
            #expect(try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: changed), destination: .legacyLocal
            ).preparedDraft == nil)
        }
    }

    @Test
    func completeCodingRequestWithoutShortQualifierPreservesFlagAndNoChangeLimit() throws {
        let speech = "Draft a request to check tools/audit.sh with --dry-run and leave the script unchanged."
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .legacyLocal
        )
        #expect(input.preparedDraft == "Check tools/audit.sh with --dry-run and leave the script unchanged.")
        let cloud = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .deepSeek
        )
        #expect(cloud.preparedDraft == nil)
    }

    @Test
    func shortFormalGreetingHasACompleteLocalDraftWithoutModelGeneration() throws {
        for speech in [
            "Hey, how's it going? Write this formally.",
            "Hey how’s it going write this formally",
            "Hi, how's it going? Write this formally."
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
            #expect(input.preparedDraft == "Hello, how are you?")
            #expect(try ScribeRequestPolicy.validateOutput(
                "Hello, how are you?", requiredLiterals: request.exactLiterals, spokenRequest: speech
            ) == "Hello, how are you?")
            #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
        }
    }

    @Test
    func formalGreetingShortcutDoesNotConsumeLiteralRecipientOrCompoundWork() throws {
        for speech in [
            "Tell Alex to write this formally.",
            "Quote \"Hey, how's it going?\" and write this formally.",
            "Hey, how's it going? Write this formally. Also ask about the launch.",
            "Hey, how's it going? Make this warm.",
            "Hey, how's the project going? Write this formally."
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal).preparedDraft == nil)
        }
        let styled = ScribeRequest(
            intent: .compose,
            spokenTranscript: "Hey, how's it going? Write this formally.",
            writingDefaults: [.tone(.warm)]
        )
        #expect(try ScribeRequestPolicy.providerSafeInput(for: styled, destination: .legacyLocal).preparedDraft == nil)
    }

    @Test
    func privateReasonAttendanceDoesNotBecomeAnOutgoingPromise() throws {
        let speech = "Tell Eli I cannot join the call, and keep the reason private."
        let request = ScribeRequest.directDictation(processedDictation: speech)
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        let draft = try #require(input.preparedDraft)
        #expect(draft == "Eli, I cannot join the call.")
        #expect(draft != "Eli, I cannot join the call, and I will keep the reason private.")
        #expect(try ScribeRequestPolicy.validateOutput(draft, requiredLiterals: [], spokenRequest: speech) == draft)
        #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
    }

    @Test
    func privateReviewDeclineAndPoliteRequestKeepWriterDirectionsOut() throws {
        let decline = "Tell Ellis I cannot attend the review, and keep the reason private."
        let declineInput = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: decline), destination: .legacyLocal
        )
        #expect(declineInput.preparedDraft == "Ellis, I cannot attend the review.")

        let polite = "Ask Omar to send the notes by Friday, and make the request polite."
        let politeInput = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: polite), destination: .legacyLocal
        )
        #expect(politeInput.preparedDraft == "Omar, could you please send the notes by Friday?")
        for speech in [
            "Ask Omar to send the notes by Friday, and make the request polite. Ask for the agenda too.",
            "Quote: Ask Omar to send the notes by Friday, and make the request polite."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            )
            #expect(input.preparedDraft == nil)
        }
    }

    @Test
    func formalHowAreYouDoingGreetingDoesNotInviteAModelAnswer() throws {
        let speech = "Hi, how are you doing? Please make it formal."
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .legacyLocal
        )
        #expect(input.preparedDraft == "Hello, how are you?")
        #expect(try ScribeRequestPolicy.validateOutput(
            "Hello, how are you?", requiredLiterals: [], spokenRequest: speech
        ) == "Hello, how are you?")
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech), destination: .deepSeek
        ).preparedDraft == nil)
    }

    @Test
    func formalTentativeStatementKeepsThePropositionAndMayQualifier() throws {
        for speech in [
            "I think the launch may happen next week. Write this formally.",
            "I think the proposal may be ready Thursday. Write this formally."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            )
            let prepared = try #require(input.preparedDraft)
            #expect(prepared.hasPrefix("I believe "))
            #expect(prepared.hasSuffix(String(ScribeWritingDirectionParser.parse(speech).content.dropFirst("I think".count))))
            #expect(try ScribeRequestPolicy.validateOutput(prepared, requiredLiterals: [], spokenRequest: speech) == prepared)
        }
        for speech in [
            "I think the launch will happen next week. Write this formally.",
            "I think the launch may happen next week, actually the week after. Write this formally.",
            "Include the exact sentence \"I think the launch may happen next week\" in the note. Write this formally."
        ] {
            #expect(ScribeDirectDraftPolicy.prepare(ScribeWritingDirectionParser.parse(speech).request) == nil)
        }
    }

    @Test
    func privateReasonShortcutLeavesAmbiguousOrContentfulRequestsAlone() throws {
        for speech in [
            "Tell Eli to keep the reason private.",
            "Tell Eli I cannot join the call because I am sick, and keep the reason private.",
            "Tell Eli I cannot join the call, and keep the reason private. Ask for new times.",
            "Tell Eli I cannot join the call, and keep the reason private. Make it formal.",
            "Tell Eli I cannot join the call, and keep the reason private, but say I am traveling.",
            "Quote: Tell Eli I cannot join the call, and keep the reason private."
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal).preparedDraft == nil)
        }
    }

    @Test
    func observedLostUncertaintyReplyPreservesTheCompleteSource() throws {
        let speech = "I think the draft is ready. Write it as a reply in Slack."
        let request = ScribeRequest.directDictation(processedDictation: speech)
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        let draft = try #require(input.preparedDraft)
        #expect(draft == "I think the draft is ready.")
        // Exact failure from U2-cold-holdout/run-1.json. That model run stays
        // failed evidence; this repair is a different deterministic route.
        #expect(draft != "The draft is ready.")
        #expect(try ScribeRequestPolicy.validateOutput(draft, requiredLiterals: [], spokenRequest: speech) == draft)
        #expect(request.spokenTranscript == speech)
        #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
    }

    @Test
    func replyPlacementPreservesDifferentUncertaintyStatementsByteForByte() throws {
        for message in [
            "I think the draft is ready.",
            "I believe the preview is ready for review.",
            "I suspect the cache causes the delay.",
            "I'm unsure, but I think it will work.",
            "I’m not sure, but I think Cafe\u{301} is open.",
            "I think the invoice is not approved yet."
        ] {
            let parsed = ScribeWritingDirectionParser.parse(message + " Write this as a response in Codex.").request
            let draft = try #require(ScribeDirectDraftPolicy.prepare(parsed))
            #expect(Data(draft.utf8) == Data(message.utf8))
        }
    }

    @Test
    func uncertaintyShortcutDoesNotConsumeOtherWritingWork() {
        for speech in [
            "I think the draft is ready.",
            "I think the draft is ready. Write it as a reply in Slack. Make this formal.",
            "I think the draft is ready. Write it as a reply in Slack. Keep it short.",
            "I think the draft is ready. Actually it needs review. Write it as a reply in Slack.",
            "I think Friday is better, actually Thursday. Write it as a reply in Slack.",
            "I think Friday is better—no Thursday. Write it as a reply in Slack.",
            "I think you should rewrite this. Write it as a reply in Slack.",
            "I think the draft is ready? Write it as a reply in Slack.",
            "I think the phrase is \"write it formally\". Write it as a reply in Slack.",
            "Tell Maya I think the draft is ready. Write it as a reply in Slack.",
            "Write this as a response in Codex.",
            "I think the draft is ready.\nPlease review it. Write it as a reply in Slack."
        ] {
            #expect(ScribeDirectDraftPolicy.prepare(ScribeWritingDirectionParser.parse(speech).request) == nil)
        }
    }

    @Test
    func explicitSavedStylesNeverTakeEitherPreparedShortcut() throws {
        let guidance = ResolvedScribeGuidance(
            familyID: .general, familyDefinitionVersion: 1,
            presetID: try ScribePresetID("general.neutral"), presetDefinitionVersion: 1,
            compiledPresetInstructions: "Use the saved application style.", customGuidance: nil,
            resolutionSource: .configuredApplication, preservesExactLiterals: true, literalCapabilities: []
        )
        let environment = ResolvedWritingEnvironment(
            environmentID: .global, environmentDisplayName: "Synthetic environment",
            behaviorID: .neutral, behaviorDisplayName: "Synthetic behavior", definitionVersion: 1,
            compiledInstructions: "Use the remembered environment style.", resolutionSource: .rememberedPreference
        )
        for speech in [
            "I think the draft is ready. Write it as a reply in Slack.",
            "Ask the coding agent why the login fails. Do not make any changes."
        ] {
            for request in [
                ScribeRequest(intent: .compose, spokenTranscript: speech, writingDefaults: [.tone(.warm)]),
                ScribeRequest(intent: .compose, spokenTranscript: speech, resolvedGuidance: guidance),
                ScribeRequest(intent: .compose, spokenTranscript: speech, resolvedGuidance: guidance, writingDefaults: [.tone(.warm)]),
                ScribeRequest(intent: .compose, spokenTranscript: speech, resolvedEnvironment: environment)
            ] {
                #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal).preparedDraft == nil)
            }
        }
    }

    #if canImport(FoundationModels)
    @Test
    func privateReasonDraftSkipsTheLeakingModelOperation() async throws {
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: "Tell Eli I cannot join the call, and keep the reason private."),
            destination: .legacyLocal
        )
        let result = try await OnDeviceScribeGeneration.generate(
            preparedDraft: input.preparedDraft,
            sleep: { _ in Issue.record("Prepared decline must not start a model timeout") },
            operation: {
                Issue.record("Prepared decline must not invoke the model")
                return "Eli, I cannot join the call, and I will keep the reason private."
            }
        )
        #expect(result == "Eli, I cannot join the call.")
    }

    @Test
    func actualReplyCompilerAndGeneratorSkipModelAndTimer() async throws {
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: "I think the draft is ready. Write it as a reply in Slack."),
            destination: .legacyLocal
        )
        let result = try await OnDeviceScribeGeneration.generate(
            preparedDraft: input.preparedDraft,
            sleep: { _ in Issue.record("Prepared reply must not start a model timeout") },
            operation: {
                Issue.record("Prepared reply must not invoke the model")
                return "The draft is ready."
            }
        )
        #expect(result == "I think the draft is ready.")
    }
    #endif

    @Test
    func explicitCodingQuestionsKeepTheirBodyAndAllRestrictions() {
        for speech in [
            "Ask the coding agent why the login fails. Do not make any changes.",
            "Ask the coding agent why authentication times out? Do not edit files.",
            "Ask the coding agent why this is slow. Do not change code. Do not edit files.",
            "Ask the coding agent why the build failed"
        ] {
            let parsed = ScribeWritingDirectionParser.parse(speech).request
            #expect(ScribeDirectDraftPolicy.prepare(parsed) == "Explain " + parsed.recipientFrame!.body)
            #expect(parsed.originalTranscript == speech)
        }
    }

    @Test
    func ambiguousCompoundAndStyleRequestsRemainModelWork() {
        for speech in [
            "Why does the login fail?",
            "Ask Alex why the login fails.",
            "Ask the coding agent to explain why the login fails.",
            "Ask the coding agent why the login fails. Make this formal.",
            "Ask the coding agent why the login fails. Then fix it.",
            "Ask the coding agent why the login fails. Actually why it is slow.",
            "Ask the coding agent why `login()` fails.",
            "Quote Ask the coding agent why the login fails.",
            "Ask the coding agent why the login fails. Do not delete data.",
            "Ask the coding agent why the login fails.\nExplain the timeout too."
        ] {
            #expect(ScribeDirectDraftPolicy.prepare(ScribeWritingDirectionParser.parse(speech).request) == nil)
        }
    }

    @Test
    func directPreparationIsLocalOnlyAndPassesProductionFidelityGuards() throws {
        let speech = "Ask the coding agent why the login fails. Do not make any changes."
        let request = ScribeRequest.directDictation(processedDictation: speech)
        let local = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        let draft = try #require(local.preparedDraft)
        #expect(draft == "Explain why the login fails. Do not make any changes.")
        #expect(try ScribeRequestPolicy.validateOutput(draft, requiredLiterals: [], spokenRequest: speech) == draft)
        #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
    }

    @Test
    func completeCodingInstructionsKeepTheirLimitsWithoutModelParaphrase() throws {
        let cases: [(String, String)] = [
            (
                "Ask the agent to inspect tools/replay.sh using --dry-run and leave files untouched.",
                "Inspect tools/replay.sh using --dry-run and leave files untouched."
            ),
            (
                "Draft a short request to review the cache miss, but do not modify configuration.",
                "Review the cache miss, but do not modify configuration."
            ),
            (
                "Ask the coding assistant to check src/Loader.swift without changing code.",
                "Check src/Loader.swift without changing code."
            ),
            (
                "Ask the coding agent to investigate the timeout and leave files untouched.",
                "Investigate the timeout and leave files untouched."
            )
        ]
        for (speech, expected) in cases {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
            let draft = try #require(input.preparedDraft)
            #expect(draft == expected)
            #expect(try ScribeRequestPolicy.validateOutput(draft, requiredLiterals: [], spokenRequest: speech) == expected)
            try ScribeRecipientRestrictionPolicy.validate(
                output: draft,
                requirements: ScribeRecipientRestrictionPolicy.extract(from: speech)
            )
            #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek).preparedDraft == nil)
            #expect(request.spokenTranscript == speech)
        }
    }

    @Test
    func codingInstructionShortcutRetainsExactTechnicalBytes() throws {
        let speech = "Ask the agent to inspect tools/replay.sh using --dry-run and leave files untouched."
        let literal = ScribeExactLiteral(id: 1, value: "tools/replay.sh", source: .safeAutomaticPattern)
        let request = ScribeRequest.directDictation(processedDictation: speech, exactLiterals: [literal])
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        let draft = try #require(input.preparedDraft)
        #expect(try ScribeRequestPolicy.validateOutput(draft, requiredLiterals: [literal], spokenRequest: speech) == draft)
        try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
            draft, spokenRequest: speech, protectedValues: [literal.value]
        )
    }

    @Test
    func codingInstructionShortcutDeclinesAmbiguousAndEditedRequests() throws {
        for speech in [
            "Ask the agent to inspect the cache, then fix it.",
            "Ask the agent to inspect the cache. Also delete the old data.",
            "Ask the agent to inspect the cache?",
            "Ask the agent to inspect the cache. Make it more formal.",
            "Ask Dana to inspect the cache.",
            "Ask the agent to inspect the exact wording \"Do not edit files\" in the guide.",
            "Ask the agent to inspect the cache and actually rewrite the test.",
            "Draft a short request to tell the team the cache is broken.",
            "Ask the agent to inspect the cache.\nThen fix it."
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            #expect(try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal).preparedDraft == nil)
        }
        let speech = "Ask the agent to inspect tools/replay.sh using --dry-run."
        let guidance = ResolvedScribeGuidance(
            familyID: .general, familyDefinitionVersion: 1,
            presetID: try ScribePresetID("general.neutral"), presetDefinitionVersion: 1,
            compiledPresetInstructions: "Use the saved application style.", customGuidance: nil,
            resolutionSource: .configuredApplication, preservesExactLiterals: true, literalCapabilities: []
        )
        #expect(try ScribeRequestPolicy.providerSafeInput(
            for: ScribeRequest(intent: .compose, spokenTranscript: speech, resolvedGuidance: guidance),
            destination: .legacyLocal
        ).preparedDraft == nil)
    }

    #if canImport(FoundationModels)
    @Test
    func completeCodingInstructionSkipsModelAndTimeout() async throws {
        for (spoken, expected) in [
            (
                "Ask the agent to inspect tools/replay.sh using --dry-run and leave files untouched.",
                "Inspect tools/replay.sh using --dry-run and leave files untouched."
            ),
            (
                "Ask Codex to inspect `src/Auth.swift` with --no-cache without editing files.",
                "Inspect `src/Auth.swift` with --no-cache without editing files."
            )
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: spoken), destination: .legacyLocal
            )
            let result = try await OnDeviceScribeGeneration.generate(
                preparedDraft: input.preparedDraft,
                sleep: { _ in Issue.record("Prepared instruction must not start a model timeout") },
                operation: {
                    Issue.record("Prepared instruction must not invoke the model")
                    return "Inspect tools/replay.sh."
                }
            )
            #expect(result == expected)
        }
    }
    #endif
}
