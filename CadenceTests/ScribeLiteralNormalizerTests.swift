import Foundation
import Testing
@testable import Cadence

struct ScribeLiteralNormalizerTests {
    @Test(arguments: [
        ("literal camel case parse capital I capital D end literal", "parseID"),
        ("literal pascal case capital A capital P capital I client dot swift end literal", "APIClient.swift"),
        ("literal flag verbose end literal", "--verbose"),
        ("literal snake case user capital I capital D end literal", "user_id"),
        ("literal lower case src slash auth dot swift end literal", "src/auth.swift")
    ])
    func explicitLiteralGrammarProducesExactValues(spoken: String, expected: String) throws {
        let normalized = ScribeLiteralNormalizer.normalize(
            spoken,
            environmentID: .claudeCode
        )

        #expect(normalized.parseStatus == .clean)
        #expect(normalized.text == expected)
        #expect(normalized.exactLiterals.map(\.value) == [expected])
    }

    @Test
    func malformedLiteralGrammarFailsLocallyWithoutGuessing() {
        for spoken in [
            "literal camel case parse I D",
            "literal end literal",
            "literal literal parse end literal end literal",
            "literal camel case end literal",
            "literal mystery parse end literal",
            "literal lower case dot swift end literal",
            "literal lower case foo dot end literal",
            "literal lower case foo open bracket end literal"
        ] {
            let normalized = ScribeLiteralNormalizer.normalize(
                spoken,
                environmentID: .claudeCode
            )
            #expect(normalized.parseStatus == .needsLocalRepair)
            #expect(normalized.text == spoken)
            #expect(normalized.exactLiterals.isEmpty)
        }
    }

    @Test(arguments: [
        ("literal kebab case feature branch end literal", "feature-branch"),
        ("literal upper case api two end literal", "API2"),
        ("literal lower case foo open parenthesis close parenthesis end literal", "foo()"),
        ("literal verbatim git status --short end literal", "git status --short")
    ])
    func remainingClosedGrammarModesAndPairsAreDeterministic(spoken: String, expected: String) {
        let normalized = ScribeLiteralNormalizer.normalize(spoken, environmentID: .claudeCode)
        #expect(normalized.parseStatus == .clean)
        #expect(normalized.text == expected)
        #expect(normalized.exactLiterals.map(\.value) == [expected])
    }

    @Test
    func automaticPatternsAreConservativeAndCodingOnly() {
        let claude = ScribeLiteralNormalizer.normalize(
            "run dash dash verbose against config dot json",
            environmentID: .claudeCode
        )
        #expect(claude.text == "run --verbose against config.json")
        #expect(claude.exactLiterals.map(\.value) == ["--verbose", "config.json"])

        for environmentID in [WritingEnvironmentID.slack, .global] {
            let nonCoding = ScribeLiteralNormalizer.normalize(
                "run dash dash verbose against config dot json",
                environmentID: environmentID
            )
            #expect(nonCoding.text == "run dash dash verbose against config dot json")
            #expect(nonCoding.exactLiterals.isEmpty)
        }

        let ambiguous = ScribeLiteralNormalizer.normalize(
            "change parse ID in API client",
            environmentID: .claudeCode
        )
        #expect(ambiguous.text == "change parse ID in API client")
        #expect(ambiguous.exactLiterals.isEmpty)

        let path = ScribeLiteralNormalizer.normalize(
            "open src slash auth underscore service dot swift with dash dash verbose",
            environmentID: .claudeCode
        )
        #expect(path.text == "open src/auth_service.swift with --verbose")
        #expect(path.exactLiterals.map(\.value) == ["src/auth_service.swift", "--verbose"])

        let alreadyExact = ScribeLiteralNormalizer.normalize(
            "inspect src/Auth.swift with --verbose",
            environmentID: .claudeCode
        )
        #expect(alreadyExact.text == "inspect src/Auth.swift with --verbose")
        #expect(alreadyExact.exactLiterals.map(\.value) == ["src/Auth.swift", "--verbose"])
    }

    @Test
    func explicitLiteralGrammarWorksInEveryFamilyAndPolicyOnlyEgressesDictation() throws {
        for environmentID in WritingEnvironmentID.allCases {
            let normalized = ScribeLiteralNormalizer.normalize(
                "literal camel case parse capital I capital D end literal",
                environmentID: environmentID
            )
            #expect(normalized.parseStatus == .clean)
            #expect(normalized.exactLiterals.map(\.value) == ["parseID"])
        }
        let environment = WritingEnvironmentResolver.resolve(
            recognizedEnvironmentID: .slack,
            adaptationEnabled: true,
            preferenceLoadResult: .absent,
            catalog: .releaseOne
        )
        let request = ScribeRequest(
            intent: .compose,
            spokenTranscript: "Decline politely",
            resolvedEnvironment: environment,
            exactLiterals: []
        )

        let input = try ScribeRequestPolicy.providerSafeInput(
            for: request,
            destination: .deepSeek
        )

        #expect(input.systemMessage == ScribeRequestPolicy.systemMessage)
        #expect(input.userMessage.contains("Processed dictation (JSON data)"))
        #expect(input.userMessage.contains("Decline politely"))
        #expect(!input.userMessage.contains("<context>"))
        #expect(input.userMessage.contains("Write a message that can be pasted into a conversational team chat."))
        #expect(!input.userMessage.contains("com.tinyspeck"))
        #expect(!input.userMessage.contains("Slack · Neutral"))
    }

    @Test
    func requestPolicyRejectsAllContextBeforeProviderEgress() {
        let request = ScribeRequest(
            intent: .compose,
            spokenTranscript: "Make this concise",
            context: Self.authorizedContext(
                selectedText: "Fixture selection",
                destination: .deepSeek
            )
        )
        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.providerSafeInput(for: request, destination: .deepSeek)
        }
    }

    @Test
    func outputValidationRejectsMutatedRequiredLiteral() throws {
        let literal = ScribeExactLiteral(id: 1, value: "parseID", source: .explicitGrammar)

        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "Update parseId to reject empty strings.",
                requiredLiterals: [literal],
                spokenRequest: "change parseID to reject empty strings"
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "Update `parseID` to reject empty strings.",
            requiredLiterals: [literal],
            spokenRequest: "change parseID to reject empty strings"
        ) == "Update `parseID` to reject empty strings.")

        #expect(throws: ScribeProviderError.invalidResult) {
            try ScribeRequestPolicy.validateOutput(
                "Remove filler from this draft.",
                requiredLiterals: [literal],
                spokenRequest: "remove filler and keep parseID unchanged"
            )
        }
        #expect(try ScribeRequestPolicy.validateOutput(
            "Rename this identifier.",
            requiredLiterals: [literal],
            spokenRequest: "rename the identifier parseID"
        ) == "Rename this identifier.")
    }


    private static func authorizedContext(
        selectedText: String,
        destination: ScribeEgressDestination
    ) -> ScribeRequestContext {
        let captureID = UUID()
        let target = ScribeTargetIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.fixture.Editor"
        )
        let verificationToken = "fixture-target"
        return ScribeRequestContext(
            artifact: .explicitSelection(ScribeExplicitSelectionArtifact(
                captureID: captureID,
                target: target,
                verificationToken: verificationToken,
                text: selectedText
            )),
            authorization: ScribeContextAuthorization(
                scope: .selectedText,
                providerKind: destination.providerKind,
                recipientOrigin: destination.recipientOrigin,
                disclosureVersion: destination.disclosureVersion,
                captureID: captureID,
                target: target,
                verificationToken: verificationToken
            )
        )
    }
}
