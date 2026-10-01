import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Cadence

private final class ScribeFixtureBundle: NSObject {}

struct ScribeTests {
    @Test
    func readOnlyCodingPromptProtectsWrittenPathsAndFlags() throws {
        let spoken = "Ask Codex to inspect `src/Auth.swift` with --no-cache without editing files."
        let existing = [ScribeExactLiteral(id: 7, value: "--no-cache", source: .alreadyExact)]
        let literals = ScribeRequestPolicy.directCodingLiterals(in: spoken, existing: existing)
        #expect(literals.map(\.value) == ["--no-cache", "src/Auth.swift"])
        #expect(Set(literals.map(\.id)).count == 2)
        let request = ScribeRequest.directDictation(processedDictation: spoken, exactLiterals: literals)
        let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(input.userMessage.contains("Exact literals"))
        #expect(input.userMessage.contains("src/Auth.swift"))
        #expect(input.userMessage.contains("--no-cache"))
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "Inspect src/Auth.swift.bak without editing files.",
                requiredLiterals: literals, spokenRequest: spoken
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "Inspect src/Auth.swift with --no-cache without editing files.",
            requiredLiterals: literals, spokenRequest: spoken
        ).contains("src/Auth.swift"))
    }

    @Test
    func ordinaryRequestsDoNotGainCodingLiterals() {
        for spoken in [
            "Tell Maya to review src/Auth.swift with --no-cache.",
            "Please review src/Auth.swift with --no-cache."
        ] {
            #expect(ScribeRequestPolicy.directCodingLiterals(in: spoken, existing: []).isEmpty)
        }
    }

    @Test
    func codingEditPromptsKeepExactOldAndNewTargets() throws {
        for (spoken, changed) in [
            (
                "Ask Codex to fix src/Auth.swift using --no-cache.",
                "Fix src/Auth.swift.bak using --no-cache."
            ),
            (
                "Ask Codex to rename src/Auth.swift to src/Login.swift.",
                "Rename it to src/Login.swift."
            ),
            (
                "Ask the agent to remove src/Old.swift with --dry-run.",
                "Remove src/Old.swift with --dry-run-old."
            )
        ] {
            let literals = ScribeRequestPolicy.directCodingLiterals(in: spoken, existing: [])
            #expect(literals.contains { $0.value == "src/Auth.swift" || $0.value == "src/Old.swift" })
            #expect(throws: ScribeProviderError.invalidResult) {
                try ScribeRequestPolicy.validateOutput(
                    changed, requiredLiterals: literals, spokenRequest: spoken
                )
            }
        }
        let spoken = "Ask Codex to rename src/Auth.swift to src/Login.swift."
        let literals = ScribeRequestPolicy.directCodingLiterals(in: spoken, existing: [])
        #expect(literals.map(\.value) == ["src/Auth.swift", "src/Login.swift"])
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: spoken, exactLiterals: literals),
            destination: .legacyLocal
        )
        #expect(input.userMessage.contains("Exact literals"))
        #expect(input.userMessage.contains("src/Auth.swift"))
        #expect(input.userMessage.contains("src/Login.swift"))
        #expect(try ScribeRequestPolicy.validateOutput(
            "Rename src/Auth.swift to src/Login.swift.", requiredLiterals: literals, spokenRequest: spoken
        ) == "Rename src/Auth.swift to src/Login.swift.")

        let nonCodingEdit = "Please remove literal src/Auth.swift from this note."
        #expect(try ScribeRequestPolicy.validateOutput(
            "The note is ready.",
            requiredLiterals: [.init(id: 1, value: "src/Auth.swift", source: .alreadyExact)],
            spokenRequest: nonCodingEdit
        ) == "The note is ready.")
    }

    @Test
    func sourceFreeSummaryIsUnresolvedWithoutConsumingRecipientOrQuotedCommands() {
        for spoken in [
            "Summarize this in one sentence.", "Please sum up that briefly.",
            "Summarize it in two sentences.",
            "Summarize this in two bullets.",
            "Summarize that in 3 bullet points."
        ] {
            let parsed = ScribeWritingDirectionParser.parse(spoken)
            #expect(parsed.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
            #expect(parsed.content == spoken)
            #expect(!ComposeSelectedTextRewritePolicy.canUseSelection(for: parsed))
        }
        let countedBullets = ScribeWritingDirectionParser.parse("Put this into two bullets.")
        #expect(countedBullets.unresolvedReferences == [.sourceRequired(transform: .rewrite)])
        #expect(countedBullets.request.writingDirections == [.bullets(count: 2)])
        #expect(ComposeSelectedTextRewritePolicy.canUseSelection(for: countedBullets))
        for spoken in [
            "Tell Maya to summarize this in one sentence.",
            "Tell Maya to put this into two bullets.",
            "Write a note saying summarize this in one sentence.",
            "Put this into two bullets: fix the retry path and document the timeout.",
            "Include the exact phrase \"Summarize this\" in the note."
        ] {
            #expect(ScribeWritingDirectionParser.parse(spoken).unresolvedReferences.isEmpty)
        }
    }

    @Test
    func unsolicitedModelIdentityRefusalCannotBecomeAComposeDraft() throws {
        let spoken = "I might be wrong, but I think the issue is in the cache. Write this as a Codex reply."
        let refusal = "I'm sorry, but as a chatbot created by Apple, I cannot comply with your request. As an AI language model, I follow guidelines."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(refusal, requiredLiterals: [], spokenRequest: spoken)
        }
        let literal = "Write a note quoting: As an AI language model, I cannot comply with your request."
        #expect(try ScribeRequestPolicy.validateOutput(
            "As an AI language model, I cannot comply with your request.",
            requiredLiterals: [], spokenRequest: literal
        ).contains("cannot comply"))
    }

    @Test
    func warmStatusCueKeepsOnlySimplePositiveNamedGreetings() throws {
        let cue = "Retain the brief greeting already present in the Spoken message."
        for spoken in [
            "Keep this warm and short. Tell Maya the preview is ready for review.",
            "Tell Noah the build is ready for testing. Make this warm."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: spoken), destination: .legacyLocal
            )
            #expect(input.systemMessage.contains(cue))
            #expect(input.userMessage.contains("Spoken message:\nHi "))
        }
        for spoken in [
            "Tell Maya the preview may be ready for review. Make this warm.",
            "Tell Maya the preview is not ready for review. Make this warm.",
            "Tell Maya the preview is ready for review, but a bug remains. Make this warm.",
            "Tell Maya the preview is ready for review. Ask her to confirm. Make this warm.",
            "Tell Maya the preview is ready for review. Make this formal."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: spoken), destination: .legacyLocal
            )
            #expect(!input.systemMessage.contains(cue))
        }
    }

    @Test
    func upbeatScheduleCueAppliesOnlyToSimpleNamedAnnouncements() throws {
        let cue = "Make the announcement sound upbeat by ending the factual sentence with an exclamation mark."
        for spoken in [
            "Make this upbeat and brief. Tell Nora the rehearsal starts at nine.",
            "Make this upbeat and brief. Tell Leo the lesson starts at seven.",
            "Tell Maya the demo begins at 9:30. Make this upbeat."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: spoken), destination: .legacyLocal
            )
            #expect(input.systemMessage.contains(cue))
            #expect(input.preparedDraft == nil)
        }
        for spoken in [
            "Tell Nora the rehearsal is canceled. Make this upbeat.",
            "Tell Nora the rehearsal may start at nine. Make this upbeat.",
            "Tell Leo the lesson may start at seven. Make this upbeat.",
            "Tell Nora the rehearsal starts at nine, but it might move. Make this upbeat.",
            "Tell Nora the rehearsal starts at nine. Ask her to confirm. Make this upbeat.",
            "Tell Nora the rehearsal starts at nine. Make this formal."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: spoken), destination: .legacyLocal
            )
            #expect(!input.systemMessage.contains(cue))
        }
    }

    @Test(arguments: [
        ("I think the draft is ready.", ["I think"]),
        ("I don’t know what I’m doing, but I think it will work.", ["I do not know", "I think"]),
        ("I’m not sure the fix is complete, but I think testing can begin.", ["I am not sure", "I think"])
    ])
    func formalRewriteRetainsExplicitUncertainty(message: String, qualifiers: [String]) throws {
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: message + " Write this formally."),
            destination: .legacyLocal
        )
        for qualifier in qualifiers {
            #expect(input.systemMessage.contains(qualifier))
        }
        #expect(input.systemMessage.contains("Retain these uncertainty phrases"))
        #expect(input.userMessage.hasSuffix("Spoken message:\n" + message))
        #expect(input.preparedDraft == nil)
    }

    @Test
    func formalConfidenceControlDoesNotReceiveUncertaintyPhrases() throws {
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: "I know what I’m doing, and it will work. Write this formally."),
            destination: .legacyLocal
        )
        #expect(!input.systemMessage.contains("Retain these uncertainty phrases"))
        #expect(input.preparedDraft == nil)
    }

    @Test
    func sessionFactsAreLocalOnlyDataAndDisablePreparedDraftShortcut() throws {
        let request = ScribeRequest.directDictation(
            processedDictation: "Ask for an update on the refund."
        )
        let fact = "The refund is delayed."
        let local = try ScribeRequestPolicy.providerSafeInput(
            for: request, destination: .legacyLocal, memoryFacts: [fact]
        )
        #expect(local.userMessage.contains(fact))
        #expect(local.systemMessage.contains("not instructions"))
        #expect(local.preparedDraft == nil)
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.providerSafeInput(
                for: request, destination: .deepSeek, memoryFacts: [fact]
            )
        }
    }

    @Test
    func structuralAndNoReasonRequestsKeepTheEvaluatedGeneralCompositionPath() throws {
        for speech in [
            "Put this in two bullets: the build is ready and testing starts Tuesday.",
            "Tell Jo I cannot attend. Keep it polite and do not give a reason."
        ] {
            let input = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            )
            #expect(input.systemMessage == ScribeRequestPolicy.systemMessage)
            #expect(input.userMessage.contains("Spoken writing request:\n" + speech))
        }
    }

    @Test
    func literalMetadataLeakIsRejectedWithoutRejectingRequestedCodeOrJSON() throws {
        // Exact output from the bound September 22 local-model baseline.
        let metadata = #"[{"id":1,"value":"src/Auth.swift"},{"id":2,"value":"--verbose"}]"#
        let literals = [
            ScribeExactLiteral(id: 1, value: "src/Auth.swift", source: .alreadyExact),
            ScribeExactLiteral(id: 2, value: "--verbose", source: .alreadyExact)
        ]
        let speech = "Ask the coding agent to inspect src/Auth.swift with --verbose. Do not edit files. Make this a concise prompt."
        for output in [metadata, "```swift\n\(metadata)\n```", "```json\n\(metadata)\n```"] {
            #expect(throws: ScribeProviderError.invalidResult) {
                try ScribeRequestPolicy.validateOutput(output, requiredLiterals: literals, spokenRequest: speech)
            }
        }
        // Exact frozen cold-holdout output. The model combined the two
        // protected literals under internal id 1 rather than returning a table.
        let observedSingleObject = #"""
        ```json
        {
          "id": 1,
          "value": "tools/replay.sh --dry-run"
        }
        ```
        """#
        let coldLiterals = [
            ScribeExactLiteral(id: 1, value: "tools/replay.sh", source: .alreadyExact),
            ScribeExactLiteral(id: 2, value: "--dry-run", source: .alreadyExact)
        ]
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                observedSingleObject, requiredLiterals: coldLiterals,
                spokenRequest: "Ask the agent to inspect tools/replay.sh using --dry-run and leave files untouched."
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            metadata, requiredLiterals: literals, spokenRequest: "Include this exact JSON: \(metadata)"
        ) == metadata)
        let requestedObject = #"{"id":1,"value":"src/Auth.swift"}"#
        let oneLiteral = [ScribeExactLiteral(id: 1, value: "src/Auth.swift", source: .alreadyExact)]
        #expect(try ScribeRequestPolicy.validateOutput(
            requestedObject, requiredLiterals: oneLiteral, spokenRequest: "Include this exact JSON: \(requestedObject)"
        ) == requestedObject)
        let code = "```sh\ninspect src/Auth.swift --verbose\n```"
        #expect(try ScribeRequestPolicy.validateOutput(
            code, requiredLiterals: literals, spokenRequest: "Write the command inspect src/Auth.swift --verbose in a code block."
        ) == code)
    }

    @Test
    func generatedPromptScaffoldingIsRejectedUnlessDictated() throws {
        let speech = "I am not sure what I am doing, but I think it will work. Please draft this as a reply."
        let leaked = "Sure, here's the final message or prompt requested by the speaker:\n```\n\(speech)\n```"
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(leaked, requiredLiterals: [], spokenRequest: speech)
        }
        let literal = "final message or prompt requested by the speaker"
        #expect(try ScribeRequestPolicy.validateOutput(
            literal, requiredLiterals: [], spokenRequest: "Include the exact phrase \"\(literal)\"."
        ) == literal)
        let valid = "I'm not sure what I'm doing, but I think it will work."
        #expect(try ScribeRequestPolicy.validateOutput(valid, requiredLiterals: [], spokenRequest: speech) == valid)
    }

    @Test
    func codingDraftCannotClaimAnUnperformedAction() throws {
        let request = "Ask Codex to investigate the crash without changing code."
        for result in [
            "I fixed the crash.",
            "I've investigated the crash.",
            "Sure, I have updated the code.",
            "I reviewed the crash."
        ] {
            #expect(throws: ScribeProviderError.invalidResult) {
                try ScribeRequestPolicy.validateOutput(
                    result, requiredLiterals: [], spokenRequest: request
                )
            }
        }
        let valid = "Investigate the crash without changing code."
        #expect(try ScribeRequestPolicy.validateOutput(
            valid, requiredLiterals: [], spokenRequest: request
        ) == valid)
        let claimedBySpeaker = "Ask Codex to review this status note: I fixed the crash."
        #expect(try ScribeRequestPolicy.validateOutput(
            "I fixed the crash.", requiredLiterals: [], spokenRequest: claimedBySpeaker
        ) == "I fixed the crash.")
        #expect(try ScribeRequestPolicy.validateOutput(
            "I fixed the crash.", requiredLiterals: [],
            spokenRequest: "Draft a personal note saying I fixed the crash."
        ) == "I fixed the crash.")
    }

    @Test
    func replyDraftingCommandsAreSeparatedWithoutChangingRecipientTasks() {
        let message = "I'm unsure, but I think it will work."
        for speech in [
            message + " Can you please write this as a response in Codex?",
            "Please draft this as a reply on Slack. " + message,
            message + " Could you write this as a message?",
            message + " Write this as a reply in this thread."
        ] {
            let parsed = ScribeWritingDirectionParser.parse(speech)
            #expect(parsed.content == message)
            #expect(parsed.instructions.count == 1)
        }
        for speech in [
            "Tell Alex to write this as a response in Codex.",
            "Can you please write this as a response in Codex?",
            "Include the exact sentence \"Write this as a response in Codex\".",
            "The reviewer said: Write this as a response in Codex.",
            message + " Write this as a response in Codex without editing files."
        ] {
            let parsed = ScribeWritingDirectionParser.parse(speech)
            #expect(parsed.content == speech)
            #expect(parsed.instructions.isEmpty)
        }
        let combined = ScribeWritingDirectionParser.parse(message + " Write this as a reply in Codex. Make this formal.")
        #expect(combined.content == message)
        #expect(combined.instructions.count == 2)
    }

    @Test(arguments: [
        ("Hey, how's it going? Write this formally.", "Hey, how's it going?"),
        ("Hey, how’s it going? Write this formally", "Hey, how’s it going?"),
        ("Hey how’s it going write this formally", "Hey how’s it going")
    ])
    func localFormalCommandIsAppliedAsDirectionInsteadOfMessageContent(speech: String, message: String) throws {
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: speech),
            destination: .legacyLocal
        )
        #expect(input.systemMessage.contains("Rewrite the spoken message using these writing directions:"))
        #expect(input.systemMessage.contains("Use formal wording and complete sentences."))
        #expect(input.userMessage.hasSuffix("Spoken message:\n" + message))
        #expect(!input.userMessage.localizedCaseInsensitiveContains("write this formally"))
        #expect(input.preparedDraft == "Hello, how are you?")
    }

    @Test
    func localRecipientFramesKeepRecipientInstructionsAndCloudWording() throws {
        for (speech, expectedMessage) in [
            ("Tell Alex to write this formally.", "Alex, write this formally."),
            ("Tell Alex to keep the announcement casual.", "Alex, keep the announcement casual."),
            ("Ask the coding agent why the login fails. Do not make any changes.", "why the login fails. Do not make any changes."),
            ("Ask the coding agent to inspect src/Auth.swift with --verbose. Do not edit files. Make this a concise prompt.", "inspect src/Auth.swift with --verbose. Do not edit files.")
        ] {
            let request = ScribeRequest.directDictation(processedDictation: speech)
            let local = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
            #expect(local.userMessage.hasSuffix("Spoken message:\n" + expectedMessage))
            let cloud = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek)
            #expect(cloud.userMessage.contains("Spoken writing request:\n" + speech))
            #expect(request.spokenTranscript == speech)
        }
        let ambiguous = "Tell Alex Chen to write this formally."
        let input = try ScribeRequestPolicy.providerSafeInput(
            for: .directDictation(processedDictation: ambiguous), destination: .legacyLocal
        )
        #expect(input.userMessage.contains("Spoken writing request:\n" + ambiguous))
    }

    @Test
    func explicitWarmthUsesGreetingForKnownRecipientOnly() throws {
        let request = ScribeRequest.directDictation(
            processedDictation: "Keep this warm and short. Tell Maya the preview is ready for review."
        )
        let local = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
        #expect(local.userMessage.hasSuffix("Spoken message:\nHi Maya, the preview is ready for review."))
        #expect(local.preparedDraft == "Hi Maya, the preview is ready for review.")
        for speech in ["Tell Maya the preview is ready for review.", "The preview is ready for review. Keep this warm."] {
            let unchangedRecipient = try ScribeRequestPolicy.providerSafeInput(
                for: .directDictation(processedDictation: speech), destination: .legacyLocal
            )
            #expect(!unchangedRecipient.userMessage.contains("Hi Maya"))
        }
    }

    @Test
    func edgeStyleCommandsAreSeparatedAndLastToneWins() {
        for (speech, content) in [
            ("Hey, how's it going? Write this formally.", "Hey, how's it going?"),
            ("Okay, can you help with this? Hey, how's it going? Write this formally.", "Hey, how's it going?"),
            ("Write this formally. Hey, how's it going?", "Hey, how's it going?"),
            ("The build is ready. Please rewrite this in a formal tone.", "The build is ready.")
        ] {
            let parsed = ScribeWritingDirectionParser.parse(speech)
            #expect(parsed.content == content)
            #expect(parsed.instructions == ["Use formal wording and complete sentences."])
        }
        let conflicting = ScribeWritingDirectionParser.parse("Write this formally. The build is ready. Make this casual.")
        #expect(conflicting.content == "The build is ready.")
        #expect(conflicting.instructions == ["Use casual, natural wording."])
        let combined = ScribeWritingDirectionParser.parse("Write this formally. The build is ready. Keep it short.")
        #expect(combined.content == "The build is ready.")
        #expect(combined.instructions.count == 2)
    }

    @Test
    func recipientInstructionsQuotesAndMissingContentRemainUntouched() {
        for speech in [
            "Tell Alex to write this formally.",
            "Can you write this formally?",
            "Include the exact sentence \"Write this formally\" in the note.",
            "Quote Hey, how's it going? Write this formally.",
            "Write this formally.",
            "Write this formally. Make this casual.",
            "The reviewer said: Write this formally.",
            "The message should say `Write this formally.`",
            "Inspect the crash. Do not edit files.",
            "We need to write this formally."
        ] {
            let parsed = ScribeWritingDirectionParser.parse(speech)
            #expect(parsed.content == speech)
            #expect(parsed.instructions.isEmpty)
        }
        let protected = "Keep the command. Write this formally."
        #expect(ScribeWritingDirectionParser.parse(protected, protectedValues: ["Write this formally"]).content == protected)
    }

    @Test
    func separatingStyleKeepsRecipientRestrictionsAndCloudRequestUnchanged() throws {
        let speech = "Investigate the crash. Do not edit files. Make it concise."
        let parsed = ScribeWritingDirectionParser.parse(speech)
        #expect(parsed.content == "Investigate the crash. Do not edit files.")
        #expect(parsed.instructions.count == 1)
        let request = ScribeRequest.directDictation(processedDictation: speech)
        let cloud = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek)
        #expect(cloud.userMessage.contains("Spoken writing request:\n" + speech))
        #expect(!cloud.userMessage.contains("Explicit writing directions:"))
        #expect(request.spokenTranscript == speech)
    }

    @Test
    func instructionFixturesUseProductionRequestsAndPreserveRequiredLiterals() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixtureName = ProcessInfo.processInfo.environment["CADENCE_SCRIBE_EVALUATION_CORPUS"]
            ?? "instruction-following"
        try #require([
            "instruction-following", "instruction-holdout", "instruction-reserve-2026-09-30",
            "openai-core-2026-10-01",
            "instruction-independent-2026-09-30", "instruction-independent-2026-09-30-o",
            "instruction-independent-2026-09-30-p",
            "instruction-independent-2026-09-30-q", "instruction-independent-2026-09-30-r",
            "instruction-independent-2026-09-30-s",
            "instruction-validation-2026-09-30-b",
            "meaning-validation-2026-09-30", "meaning-validation-2026-09-30-b",
            "meaning-independent-2026-09-30-c", "meaning-independent-2026-09-30-d",
            "meaning-independent-2026-09-30-e", "meaning-independent-2026-09-30-f",
            "meaning-independent-2026-09-30-g", "meaning-independent-2026-09-30-h",
            "meaning-independent-2026-09-30-i", "meaning-independent-2026-09-30-j",
            "meaning-independent-2026-09-30-k",
            "meaning-independent-2026-09-30-l", "meaning-independent-2026-09-30-m",
            "meaning-independent-2026-09-30-n", "coding-targets-2026-09-30"
        ].contains(fixtureName))
        // Fixtures are bundled with the test target. Reading the source checkout
        // can block on Documents-folder permission in a native test host.
        let fixtureURL = try #require(Bundle(for: ScribeFixtureBundle.self).url(
            forResource: fixtureName, withExtension: "json"
        ))
        let data = try Data(contentsOf: fixtureURL)
        let corpus = try JSONDecoder().decode(InstructionCorpus.self, from: data)
        #expect(corpus.syntheticOnly)
        #expect(Set(corpus.cases.map(\.id)).count == corpus.cases.count)
        var generatedDrafts: [String: String] = [:]
        if ProcessInfo.processInfo.environment["CADENCE_VALIDATE_SYNTHETIC_SCRIBE_RESULTS"] == "1" {
            try #require(fixtureName == "instruction-following")
            let results = try JSONDecoder().decode([SyntheticGeneration].self, from: Data(
                contentsOf: root.appendingPathComponent("Build/ScribeInstructions/deepseek-results.json")
            ))
            #expect(results.count == corpus.cases.count)
            for result in results { generatedDrafts[result.id] = result.draft }
            #expect(Set(generatedDrafts.keys) == Set(corpus.cases.map(\.id)))
        }
        var exported: [[String: String]] = []
        var onDeviceExported: [EvaluationRequestExport] = []
        for fixture in corpus.cases {
            let family: ScribeEnvironmentFamilyID = fixture.family == "coding" ? .coding :
                fixture.family == "messaging" ? .messaging : .general
            let catalog = ScribeGuidanceCatalog.releaseOne
            let definition = try #require(catalog.family(family))
            let preset = try #require(catalog.preset(definition.defaultPresetID, in: family))
            let guidance = ResolvedScribeGuidance(
                familyID: family, familyDefinitionVersion: definition.definitionVersion,
                presetID: preset.id, presetDefinitionVersion: preset.definitionVersion,
                compiledPresetInstructions: preset.compiledInstructions, customGuidance: nil,
                resolutionSource: .bundledDefault, preservesExactLiterals: true,
                literalCapabilities: family == .coding ? [.automaticTechnicalLiteralNormalization] : []
            )
            let normalized = ScribeLiteralNormalizer.normalize(
                fixture.spoken, environmentID: family == .coding ? .claudeCode : .global
            )
            let requestLiterals = ScribeRequestPolicy.directCodingLiterals(
                in: normalized.text, existing: normalized.exactLiterals
            )
            let request = ScribeRequest(
                intent: .compose, spokenTranscript: normalized.text,
                resolvedGuidance: guidance, exactLiterals: requestLiterals
            )
            let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek)
            let localInput = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .legacyLocal)
            let localWriting = ScribeWritingDirectionParser.parse(normalized.text, protectedValues: requestLiterals.map(\.value))
            let structuralComposition = localWriting.request.writingDirections.contains {
                switch $0 { case .bullets, .avoidGivingReason: return true; default: return false }
            }
            let usesFocusedRewrite = (!localWriting.instructions.isEmpty
                || !localWriting.consumedCommands.isEmpty
                || localWriting.request.preparedMessage != nil)
                && localWriting.unresolvedReferences.isEmpty && !structuralComposition
            let label = usesFocusedRewrite ? "Spoken message:" : "Spoken writing request:"
            var message = usesFocusedRewrite ? (localWriting.request.preparedMessage ?? localWriting.content) : normalized.text
            if usesFocusedRewrite, localWriting.request.writingDirections.contains(.tone(.warm)),
               case .named = localWriting.request.recipientFrame?.recipient {
                message = "Hi " + message
            }
            #expect(localInput.userMessage.contains(label + "\n" + message))
            if !requestLiterals.isEmpty {
                #expect(localInput.userMessage.contains("Exact literals"))
            }
            #expect(request.spokenTranscript == normalized.text)
            #expect(localInput.userMessage.contains(preset.compiledInstructions))
            #expect(!usesFocusedRewrite
                ? localInput.userMessage.contains("never add a new restriction")
                : localInput.systemMessage.contains("recipient restrictions"))
            onDeviceExported.append(EvaluationRequestExport(
                id: fixture.id, system: localInput.systemMessage, user: localInput.userMessage,
                preparedDraft: localInput.preparedDraft,
                requestSHA256: EvaluationRequestExport.hash(
                    system: localInput.systemMessage, user: localInput.userMessage,
                    preparedDraft: localInput.preparedDraft
                )
            ))
            #expect(input.systemMessage == ScribeRequestPolicy.systemMessage)
            #expect(input.userMessage.contains(preset.compiledInstructions))
            #expect(input.userMessage.contains("Spoken writing request:\n" + normalized.text))
            // Paths appear verbatim in the request and literal metadata, without
            // transport-only slash escapes that can leak into drafted code.
            #expect(!input.userMessage.contains("\\/"))
            #expect(request.context == nil)
            #expect(try ScribeRequestPolicy.validateOutput(
                fixture.exampleDraft, requiredLiterals: requestLiterals,
                spokenRequest: normalized.text
            ) == fixture.exampleDraft)
            if let generated = generatedDrafts[fixture.id] {
                // Validate actual synthetic model results through the same output
                // policy used before review; meaning still needs separate assessment.
                #expect(try ScribeRequestPolicy.validateOutput(
                    generated, requiredLiterals: requestLiterals,
                    spokenRequest: normalized.text
                ) == generated.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            exported.append([
                "id": fixture.id, "system": input.systemMessage, "user": input.userMessage
            ])
        }
        if ProcessInfo.processInfo.environment["CADENCE_EXPORT_ON_DEVICE_FIXTURES"] == "1" {
            let directory = ProcessInfo.processInfo.environment["CADENCE_SCRIBE_EVALUATION_DIRECTORY"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? root.appendingPathComponent("Build/ScribeOnDevice")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let requestEnvelope = EvaluationRequestEnvelope(
                schemaVersion: 2, syntheticOnly: true,
                corpusSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                requests: onDeviceExported
            )
            let exportedData = try JSONEncoder.evaluationEncoder.encode(requestEnvelope)
            let decoded = try JSONDecoder().decode(EvaluationRequestEnvelope.self, from: exportedData)
            #expect(decoded.syntheticOnly)
            #expect(decoded.corpusSHA256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            #expect(decoded.requests.count == corpus.cases.count)
            #expect(Set(decoded.requests.map(\.id)) == Set(corpus.cases.map(\.id)))
            #expect(decoded.requests.allSatisfy {
                $0.requestSHA256 == EvaluationRequestExport.hash(system: $0.system, user: $0.user, preparedDraft: $0.preparedDraft)
            })
            try exportedData
                .write(to: directory.appendingPathComponent("requests.json"), options: .atomic)
        }
        // Opt-in synthetic-only export for the local model evaluation harness.
        // No credentials, user settings, app identity, or recorded speech are read.
        if ProcessInfo.processInfo.environment["CADENCE_EXPORT_SCRIBE_FIXTURES"] == "1" {
            let directory = root.appendingPathComponent("Build/ScribeInstructions")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: exported, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("requests.json"), options: .atomic)
        }
    }

    // Explicit synthetic-only comparison. Normal test runs never read a key or
    // contact OpenAI. The credential arrives through a private FIFO, never an
    // environment variable, command argument, request export, or regular file.
    @Test
    func optInOpenAICoreWritingComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CADENCE_RUN_OPENAI_CORE_COMPARISON"] == "1" else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Build/ComposeRoadmap/U2-openai-direct")
        let fixtureURL = try #require(Bundle(for: ScribeFixtureBundle.self).url(
            forResource: "openai-core-2026-10-01", withExtension: "json"
        ))
        let data = try Data(contentsOf: fixtureURL)
        let corpus = try JSONDecoder().decode(InstructionCorpus.self, from: data)
        try #require(corpus.syntheticOnly && corpus.cases.count == 20)
        let pipePath = directory.appendingPathComponent("credential.pipe").path
        var attributes = stat()
        try #require(lstat(pipePath, &attributes) == 0)
        try #require(attributes.st_mode & S_IFMT == S_IFIFO && attributes.st_mode & 0o777 == 0o600)
        let descriptor = open(pipePath, O_RDONLY | O_NONBLOCK)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        try #require(poll(&event, 1, 60_000) > 0 && event.revents & Int16(POLLIN) != 0)
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = read(descriptor, &bytes, bytes.count)
        try #require(count > 0 && count < bytes.count)
        let credential = try #require(String(bytes: bytes.prefix(count), encoding: .utf8))
        let provider = OpenAIDirectScribeProvider(
            model: try ScribeModelIdentifier("gpt-4.1-2025-04-14"),
            credentialLoader: { credential }
        )
        var results: [[String: Any]] = []
        for fixture in corpus.cases {
            let family: ScribeEnvironmentFamilyID = fixture.family == "coding" ? .coding :
                fixture.family == "messaging" ? .messaging : .general
            let definition = try #require(ScribeGuidanceCatalog.releaseOne.family(family))
            let preset = try #require(ScribeGuidanceCatalog.releaseOne.preset(definition.defaultPresetID, in: family))
            let guidance = ResolvedScribeGuidance(
                familyID: family, familyDefinitionVersion: definition.definitionVersion,
                presetID: preset.id, presetDefinitionVersion: preset.definitionVersion,
                compiledPresetInstructions: preset.compiledInstructions, customGuidance: nil,
                resolutionSource: .bundledDefault, preservesExactLiterals: true,
                literalCapabilities: family == .coding ? [.automaticTechnicalLiteralNormalization] : []
            )
            let normalized = ScribeLiteralNormalizer.normalize(
                fixture.spoken, environmentID: family == .coding ? .claudeCode : .global
            )
            let literals = ScribeRequestPolicy.directCodingLiterals(in: normalized.text, existing: normalized.exactLiterals)
            let request = ScribeRequest(intent: .compose, spokenTranscript: normalized.text,
                                        resolvedGuidance: guidance, exactLiterals: literals)
            let input = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .openAIDirect)
            var row: [String: Any] = ["id": fixture.id,
                "requestSHA256": EvaluationRequestExport.hash(system: input.systemMessage, user: input.userMessage)]
            let start = Date()
            do {
                let result = try await provider.generate(ScribeProviderRequest(id: UUID(), input: input))
                row["draft"] = result.text
                do {
                    _ = try ScribeRequestPolicy.validateOutput(result.text, requiredLiterals: literals, spokenRequest: normalized.text)
                    try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(result.text, spokenRequest: normalized.text, protectedValues: literals.map(\.value))
                    try ScribeRequestPolicy.validateDirectDraftUncertainty(result.text, spokenRequest: normalized.text, protectedValues: literals.map(\.value))
                    try ScribeRequestPolicy.validateDirectDraftRecipient(result.text, spokenRequest: normalized.text, protectedValues: literals.map(\.value))
                    try ScribeRecipientRestrictionPolicy.validate(output: result.text, requirements: ScribeRecipientRestrictionPolicy.extract(from: normalized.text))
                    row["policyAccepted"] = true
                } catch { row["policyAccepted"] = false }
            } catch let failure as ScribeProviderFailure {
                row["failureCategory"] = failure.category.rawValue
                row["policyAccepted"] = false
            } catch {
                row["failureCategory"] = "unclassified"
                row["policyAccepted"] = false
            }
            row["elapsedMilliseconds"] = Int(Date().timeIntervalSince(start) * 1_000)
            results.append(row)
            let envelope: [String: Any] = ["syntheticOnly": true, "sourceCommit": environment["CADENCE_COMPARISON_SOURCE_COMMIT"] ?? "unknown",
                "model": "gpt-4.1-2025-04-14", "corpusSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "semanticGate": "NOT_GRADED", "results": results]
            try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("first-results.json"), options: .atomic)
        }
        #expect(results.count == 20)
    }

    @Test
    func cloudWritingChecksPreserveNamedRecipientsAndReplyActionBoundaries() throws {
        let request = ScribeRequest.directDictation(processedDictation:
            "I might be mistaken, but I think the slowdown starts in the parser. Write this as a Codex reply.")
        let cloud = try ScribeRequestPolicy.providerSafeInput(for: request, destination: .openAIDirect)
        #expect(cloud.userMessage.contains("must not remove the addressee"))
        #expect(cloud.userMessage.contains("A statement requested as a reply or response remains a statement"))
        #expect(cloud.userMessage.contains("never invent restrictions or actions"))
        #expect(!cloud.userMessage.contains("including negative instructions such as \"Do not make any changes\""))
        for (speech, badDraft) in [
            ("Tell Priya the draft is ready for her review. Make this casual.", "The draft is ready for your review whenever you have a moment."),
            ("Tell Lia the call is at 11 AM. Sorry, make that 12 PM. Ask her to confirm.", "The call is at 12 PM. Could you please confirm?"),
            ("Tell Mei ticket ZX-42 is still under review and has not been approved.", "Ticket ZX-42 is still under review and hasn't been approved yet.")
        ] {
            #expect(throws: ScribeProviderError.invalidResult) {
                try ScribeRequestPolicy.validateDirectDraftRecipient(badDraft, spokenRequest: speech, protectedValues: [])
            }
        }
    }

    @Test
    func explicitExactQuotedWordsPreserveCapitalization() throws {
        let speech = "Write a note to Noah with the exact words \"Wait until security approves\"."
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput("Noah, wait until security approves.", requiredLiterals: [], spokenRequest: speech)
        }
        #expect(try ScribeRequestPolicy.validateOutput("Noah, Wait until security approves.", requiredLiterals: [], spokenRequest: speech) == "Noah, Wait until security approves.")
        // Ordinary quoted speech does not request exact byte preservation.
        #expect(try ScribeRequestPolicy.validateOutput("Noah, wait until security approves.", requiredLiterals: [], spokenRequest: "Tell Noah \"Wait until security approves\".") == "Noah, wait until security approves.")
    }

    @Test
    func directDictationContractHasNoSelectedTextInput() {
        #expect(ScribeIntent.compose.requiresSelectedText == false)
        #expect(ScribeIntent.compose.contextScope == .none)

        let request = ScribeRequest(intent: .compose, spokenTranscript: "Synthetic dictation")
        #expect(request.context == nil)
    }

    @Test
    func directDictationFactoryNeverCarriesTargetOrSelectedTextContext() {
        let request = ScribeRequest.directDictation(
            processedDictation: "Synthetic direct-only practice dictation"
        )

        #expect(request.intent == .compose)
        #expect(request.context == nil)
        #expect(request.spokenTranscript == "Synthetic direct-only practice dictation")
    }

    @Test
    func privateModeNeverAdvertisesSemanticGeneration() {
        let readiness = ScribeReadiness(
            privacyMode: .privateMode,
            providerCapabilities: .semanticGeneration,
            permissionsGranted: true
        )

        #expect(!readiness.canGenerate)
        #expect(readiness.canUseLiteralFallback)
        #expect(readiness.blockingReason == .privateMode)
    }

    @Test
    func mockProviderReturnsScriptedResultAndDeduplicatesRequest() async throws {
        let provider = MockScribeProvider(
            responses: [.success("A concise response.")]
        )
        let request = Self.providerRequest()

        let first = try await provider.generate(request)
        let duplicate = try await provider.generate(request)
        let callCount = await provider.generationCount

        #expect(first == duplicate)
        #expect(first.requestID == request.id)
        #expect(first.text == "A concise response.")
        #expect(callCount == 1)
    }

    @Test
    func mockProviderRejectsEmptyOutput() async {
        let provider = MockScribeProvider(responses: [.success("   \n")])
        let request = Self.providerRequest()

        await #expect(throws: ScribeProviderError.emptyResult) {
            try await provider.generate(request)
        }
    }

    @Test
    func mockProviderRejectsMalformedAndOversizedOutput() async {
        let malformed = MockScribeProvider(responses: [.success("Draft\u{0000}text")])
        let oversized = MockScribeProvider(
            responses: [.success(String(repeating: "a", count: ScribeOutputPolicy.maximumUTF8Bytes + 1))]
        )
        let request = Self.providerRequest()

        await #expect(throws: ScribeProviderError.invalidResult) {
            try await malformed.generate(request)
        }
        await #expect(throws: ScribeProviderError.resultTooLarge) {
            try await oversized.generate(request)
        }
    }

    @Test
    func mockProviderCooperatesWithTaskCancellation() async {
        let provider = MockScribeProvider(
            responses: [.delayedSuccess("Late result", .seconds(10))]
        )
        let request = Self.providerRequest()
        let task = Task { try await provider.generate(request) }

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func mockProviderSurfacesOfflineTimeoutAndCancellation() async {
        for failure in [
            ScribeProviderError.offline,
            ScribeProviderError.timedOut,
            ScribeProviderError.cancelled
        ] {
            let provider = MockScribeProvider(responses: [.failure(failure)])
            let request = Self.providerRequest()

            await #expect(throws: failure) {
                try await provider.generate(request)
            }
        }
    }

    @Test
    func sessionStateKeepsRequestIdentityAcrossLifecycle() {
        let requestID = UUID()
        let result = ScribeResult(requestID: requestID, text: "Draft")

        #expect(ScribeSessionState.listening(requestID: requestID).requestID == requestID)
        #expect(ScribeSessionState.generating(requestID: requestID).requestID == requestID)
        #expect(ScribeSessionState.generatingSlow(requestID: requestID).requestID == requestID)
        #expect(ScribeSessionState.reviewing(result).requestID == requestID)
        #expect(ScribeSessionState.idle.requestID == nil)
    }

    private static func providerRequest(id: UUID = UUID()) -> ScribeProviderRequest {
        ScribeProviderRequest(
            id: id,
            input: ProviderSafeScribeInput(
                systemMessage: "Fixture system message",
                userMessage: "Fixture user message"
            )
        )
    }
}

private struct InstructionCorpus: Decodable {
    let syntheticOnly: Bool
    let cases: [InstructionFixture]
}

private struct InstructionFixture: Decodable {
    let id: String
    let family: String
    let spoken: String
    let exampleDraft: String
}

private struct SyntheticGeneration: Decodable {
    let id: String
    let draft: String
}

private struct EvaluationRequestEnvelope: Codable {
    let schemaVersion: Int
    let syntheticOnly: Bool
    let corpusSHA256: String
    let requests: [EvaluationRequestExport]
}

private struct EvaluationRequestExport: Codable {
    let id: String
    let system: String
    let user: String
    let preparedDraft: String?
    let requestSHA256: String

    // This exact byte sequence is the binding shared with the production runner:
    // UTF-8 system bytes, NUL, user bytes, and for prepared requests only,
    // NUL + "preparedDraft" + NUL + exact prepared-draft UTF-8 bytes.
    static func hash(system: String, user: String, preparedDraft: String? = nil) -> String {
        var data = Data(system.utf8)
        data.append(0)
        data.append(contentsOf: user.utf8)
        if let preparedDraft {
            data.append(0)
            data.append(contentsOf: "preparedDraft".utf8)
            data.append(0)
            data.append(contentsOf: preparedDraft.utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var evaluationEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
