import Testing
@testable import Cadence

struct ScribeRecipientRestrictionTests {
    @Test
    func observedConfigurationAndUntouchedFileLimitsArePreserved() throws {
        let configuration = ScribeRecipientRestrictionPolicy.extract(
            from: "Draft a short request to review the cache miss, but do not modify configuration."
        )
        #expect(configuration == [.noConfigurationChanges])
        #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noConfigurationChanges)) {
            try ScribeRecipientRestrictionPolicy.validate(output: "Review the cache miss.", requirements: configuration)
        }
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Review the cache miss without modifying configuration.", requirements: configuration
        )
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Review the cache miss. Do not change the configuration.", requirements: configuration
        )

        let files = ScribeRecipientRestrictionPolicy.extract(
            from: "Ask the agent to inspect tools/replay.sh using --dry-run and leave files untouched."
        )
        #expect(files == [.noFileEdits])
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Inspect tools/replay.sh using --dry-run and leave files untouched.", requirements: files
        )
        #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noFileEdits)) {
            try ScribeRecipientRestrictionPolicy.validate(output: "Inspect tools/replay.sh using --dry-run.", requirements: files)
        }
    }

    @Test
    func newRestrictionVocabularyDoesNotMatchQuotedReportedOrConditionalLimits() {
        for source in [
            "Find the phrase \"do not modify configuration\" in the document.",
            "Explain the phrase \"leave files untouched\" to the team.",
            "The reviewer asked the agent to inspect it and leave files untouched.",
            "Inspect the script and leave files untouched if possible.",
            "Draft a request to review it, but do not modify configuration unless needed."
        ] {
            #expect(ScribeRecipientRestrictionPolicy.extract(from: source).isEmpty)
        }
        for output in [
            "I reviewed it without modifying configuration.",
            "Review it without modifying configuration if possible.",
            "Explain the phrase \"do not modify configuration\".",
            "Review it without modifying code."
        ] {
            #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noConfigurationChanges)) {
                try ScribeRecipientRestrictionPolicy.validate(output: output, requirements: [.noConfigurationChanges])
            }
        }
    }

    @Test
    func evaluatedDirectCodingAgentAddressPreservesTheRestriction() throws {
        let requirements = ScribeRecipientRestrictionPolicy.extract(
            from: "Ask Codex to investigate the crash without changing code. Keep the prompt short."
        )
        #expect(requirements == [.noCodeChanges])
        // Exact accepted model output from the bound U2 evaluation, which
        // native replay exposed as a false rejection at the final guard.
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Codex, please investigate the crash without changing code.",
            requirements: requirements
        )
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Coding agent, inspect the crash without changing code.",
            requirements: requirements
        )
        for output in [
            "Codex, I investigated the crash without changing code.",
            "According to Codex, please investigate the crash without changing code.",
            "Codex, please investigate the crash without changing code if possible.",
            "Codex, please explain the phrase \"investigate the crash without changing code\"."
        ] {
            #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noCodeChanges)) {
                try ScribeRecipientRestrictionPolicy.validate(output: output, requirements: requirements)
            }
        }
    }

    @Test
    func actualBaselineDroppedAllChangesRestrictionIsRejected() {
        let speech = "Ask the coding agent why the login fails. Do not make any changes."
        let requirements = ScribeRecipientRestrictionPolicy.extract(from: speech)
        #expect(requirements == [.noChanges])
        #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noChanges)) {
            try ScribeRecipientRestrictionPolicy.validate(
                output: "Ask the coding agent why the login fails.", requirements: requirements
            )
        }
    }

    @Test
    func conservativeParaphrasesPreserveRestrictionStrength() throws {
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Investigate why login fails. Make no changes.", requirements: [.noChanges]
        )
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Inspect the crash without modifying code.", requirements: [.noCodeChanges]
        )
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Inspect src/Auth.swift with no file edits.", requirements: [.noFileEdits]
        )
        #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noChanges)) {
            try ScribeRecipientRestrictionPolicy.validate(
                output: "Investigate why login fails. Do not modify code.", requirements: [.noChanges]
            )
        }
    }

    @Test
    func quotedSearchAndExplicitLiteralRemovalDoNotCreateRestrictions() {
        #expect(ScribeRecipientRestrictionPolicy.extract(
            from: "Find the string \"Do not edit files.\" in docs."
        ).isEmpty)
        #expect(ScribeRecipientRestrictionPolicy.extract(
            from: "Ask the agent to remove the literal \"Do not edit files\" from the template."
        ).isEmpty)
        #expect(ScribeRecipientRestrictionPolicy.extract(
            from: "Delete this phrase: Do not make any changes."
        ).isEmpty)
        #expect(ScribeRecipientRestrictionPolicy.extract(
            from: "Explain the phrase ‘Do not edit files’ to the team."
        ).isEmpty)
        #expect(ScribeRecipientRestrictionPolicy.extract(
            from: "Ask the agent to inspect it unless files need editing."
        ).isEmpty)
    }

    @Test
    func multilineRestrictionsAndNoRestrictionTextAreHandledLocally() throws {
        let requirements = ScribeRecipientRestrictionPolicy.extract(
            from: "Inspect the project without editing files.\nAsk the coding agent to investigate the crash without changing code."
        )
        // Requirements retain their encounter order, rather than an unrelated
        // canonical ordering.
        #expect(requirements == [.noFileEdits, .noCodeChanges])
        try ScribeRecipientRestrictionPolicy.validate(
            output: "Inspect the project without editing files and without changing code.",
            requirements: requirements
        )
        #expect(ScribeRecipientRestrictionPolicy.extract(
            from: "Keep this concise, warm, and suitable for the recipient."
        ).isEmpty)
    }

    @Test
    func unknownOrIndirectPhrasingIsNotFalselyClassified() {
        #expect(ScribeRecipientRestrictionPolicy.extract(
            from: "Try to avoid touching implementation if possible."
        ).isEmpty)
        #expect(ScribeRecipientRestrictionPolicy.extract(
            from: "The reviewer said they did not edit files yesterday."
        ).isEmpty)
    }

    @Test
    func quotedOrCompletedOutputMentionsDoNotSatisfyRecipientRestriction() {
        #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noFileEdits)) {
            try ScribeRecipientRestrictionPolicy.validate(
                output: "Explain the phrase \"Do not edit files\".", requirements: [.noFileEdits]
            )
        }
        #expect(throws: ScribeRecipientRestrictionValidationError.missing(.noChanges)) {
            try ScribeRecipientRestrictionPolicy.validate(
                output: "No changes were made.", requirements: [.noChanges]
            )
        }
    }
}
