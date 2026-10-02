import CryptoKit
import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeRefinementEvaluationTests {
    @Test
    func syntheticRefinementCorpusUsesProductionCompilerAndValidation() throws {
        let corpusName = ProcessInfo.processInfo.environment["CADENCE_REFINEMENT_EVALUATION_CORPUS"]
            ?? "refinement-following"
        try #require(["refinement-following", "refinement-independent-2026-09-30-a"].contains(corpusName))
        let fixtureURL = try #require(Bundle(for: ScribeRefinementFixtureBundle.self).url(
            forResource: corpusName, withExtension: "json"
        ))
        let corpusBytes = try Data(contentsOf: fixtureURL)
        let corpus = try JSONDecoder().decode(RefinementEvaluationCorpus.self, from: corpusBytes)
        try #require(corpus.schemaVersion == 1)
        try #require(corpus.syntheticOnly)
        try #require(corpus.cases.count >= 6)
        try #require(Set(corpus.cases.map(\.id)).count == corpus.cases.count)

        var exports: [RefinementEvaluationRequestExport] = []
        for fixture in corpus.cases {
            try #require(!fixture.baseDraft.isEmpty)
            try #require(fixture.spoken == fixture.instruction)
            try #require(!ScribeDraftRefinementPolicy.isUndoInstruction(fixture.instruction))
            let environment: WritingEnvironmentID = fixture.family == "coding" ? .claudeCode : .global
            let original = ScribeLiteralNormalizer.normalize(fixture.originalSpokenRequest, environmentID: environment)
            let instruction = ScribeLiteralNormalizer.normalize(fixture.instruction, environmentID: environment)
            try #require(original.parseStatus == .clean)
            try #require(instruction.parseStatus == .clean)
            let originalLiterals = ScribeRequestPolicy.directCodingLiterals(
                in: original.text, existing: original.exactLiterals
            )

            // The fixture enters through the same in-memory session and token
            // authority as runtime refinement. These synthetic identities must
            // not become model input or part of a compiled-request hash.
            let origin = ScribeDraftRevisionOrigin(
                actionID: UUID(), captureID: UUID(),
                target: .init(processIdentifier: 42, bundleIdentifier: "com.example.synthetic-refinement-target"),
                providerActionIdentity: .init(
                    configurationID: UUID(), libraryRevision: 1, selectedModelID: "synthetic-local-model-binding"
                )
            )
            let store = ScribeDraftRevisionStore()
            let session = store.start(
                origin: origin, originalSpokenRequest: fixture.originalSpokenRequest, initialDraft: fixture.baseDraft
            )
            let token = try store.beginRevision(
                sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id,
                revisionUtterance: instruction.text
            )
            let originalRequest = ScribeRequest.directDictation(
                id: origin.actionID, processedDictation: original.text, exactLiterals: originalLiterals
            )
            let request = try ScribeDraftRefinementPolicy.request(
                token: token, session: session, originalRequest: originalRequest,
                instructionLiterals: originalLiterals + instruction.exactLiterals
            )
            try #require(request.baseDraft == fixture.baseDraft)
            try #require(request.token.instruction.utterance == instruction.text)
            try #require(Set(request.exactLiterals.map(\.value)) == Set(fixture.exactLiterals))
            try #require(request.protectedText == fixture.expectedProtectedText)

            let input = try ScribeDraftRefinementPolicy.providerSafeInput(for: request, destination: .legacyLocal)
            try ScribeProviderCapabilityPolicy.validate(
                input: input, profile: .defaultProfile(for: .legacyLocal), requirements: .draftRefinement
            )
            try #require(input.preparedDraft == nil)
            let compiledText = input.systemMessage + input.userMessage
            for privateMetadata in [origin.actionID.uuidString, origin.captureID.uuidString,
                                    origin.target.bundleIdentifier!, "synthetic-local-model-binding"] {
                #expect(!compiledText.contains(privateMetadata))
            }
            #expect(try ScribeDraftRefinementPolicy.validateOutput(fixture.exampleDraft, for: request) == fixture.exampleDraft)
            #expect(try store.session(id: session.id, origin: origin).currentVersion.text == fixture.baseDraft)
            exports.append(.init(
                id: fixture.id, system: input.systemMessage, user: input.userMessage,
                preparedDraft: input.preparedDraft,
                requestSHA256: RefinementEvaluationRequestExport.hash(
                    system: input.systemMessage, user: input.userMessage, preparedDraft: input.preparedDraft
                )
            ))
        }

        // Compiling and validating fixtures never runs a model. Export is an
        // explicit synthetic-only handoff to the separate local runner.
        guard ProcessInfo.processInfo.environment["CADENCE_EXPORT_REFINEMENT_FIXTURES"] == "1" else { return }
        let outputDirectory = try #require(ProcessInfo.processInfo.environment["CADENCE_SCRIBE_EVALUATION_DIRECTORY"])
        try #require(!outputDirectory.isEmpty)
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let envelope = RefinementEvaluationRequestEnvelope(
            schemaVersion: 2, syntheticOnly: true,
            corpusSHA256: SHA256.hash(data: corpusBytes).map { String(format: "%02x", $0) }.joined(),
            requests: exports
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let exportBytes = try encoder.encode(envelope)
        let decoded = try JSONDecoder().decode(RefinementEvaluationRequestEnvelope.self, from: exportBytes)
        #expect(decoded.schemaVersion == 2 && decoded.syntheticOnly)
        #expect(decoded.corpusSHA256 == envelope.corpusSHA256)
        #expect(Set(decoded.requests.map(\.id)) == Set(corpus.cases.map(\.id)))
        #expect(decoded.requests.allSatisfy {
            $0.preparedDraft == nil && $0.requestSHA256 == RefinementEvaluationRequestExport.hash(
                system: $0.system, user: $0.user, preparedDraft: $0.preparedDraft
            )
        })
        try exportBytes.write(to: directory.appendingPathComponent("requests.json"), options: .atomic)
    }
}

private final class ScribeRefinementFixtureBundle: NSObject {}

private struct RefinementEvaluationCorpus: Decodable {
    let schemaVersion: Int
    let syntheticOnly: Bool
    let cases: [RefinementEvaluationFixture]
}

private struct RefinementEvaluationFixture: Decodable {
    let id: String
    let family: String
    let originalSpokenRequest: String
    let baseDraft: String
    let instruction: String
    /// Compatibility with the generic phrase scorer: this is revision speech.
    let spoken: String
    let exampleDraft: String
    let exactLiterals: [String]
    let expectedProtectedText: [String]
}

private struct RefinementEvaluationRequestEnvelope: Codable {
    let schemaVersion: Int
    let syntheticOnly: Bool
    let corpusSHA256: String
    let requests: [RefinementEvaluationRequestExport]
}

private struct RefinementEvaluationRequestExport: Codable {
    let id: String
    let system: String
    let user: String
    let preparedDraft: String?
    let requestSHA256: String

    /// Same schema-2 byte binding as the production instruction exporter and
    /// local runner. Nil preparedDraft means this request requires generation.
    static func hash(system: String, user: String, preparedDraft: String?) -> String {
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
