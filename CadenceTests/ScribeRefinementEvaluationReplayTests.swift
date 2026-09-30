import CryptoKit
import Foundation
import Testing
@testable import Cadence

/// Opt-in validation of saved synthetic refinement output. It reconstructs the
/// production refinement request before applying the production output guard;
/// no provider is invoked and the report contains no draft text.
@MainActor
struct ScribeRefinementEvaluationReplayTests {
    @Test
    func replayBoundSyntheticRefinementResults() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CADENCE_REPLAY_SCRIBE_REFINEMENT"] == "1" else { return }
        let corpusURL = try refinementURL(env, "CADENCE_REPLAY_REFINEMENT_CORPUS")
        let requestsURL = try refinementURL(env, "CADENCE_REPLAY_REQUESTS")
        let generatorURL = try refinementURL(env, "CADENCE_REPLAY_GENERATOR")
        let resultsURL = try refinementURL(env, "CADENCE_REPLAY_RESULTS")
        let policyURL = try refinementURL(env, "CADENCE_REPLAY_REFINEMENT_POLICY_SOURCE")
        let requestPolicyURL = try refinementURL(env, "CADENCE_REPLAY_REQUEST_POLICY_SOURCE")
        let recipientPolicyURL = try refinementURL(env, "CADENCE_REPLAY_RECIPIENT_POLICY_SOURCE")
        let outputURL = try refinementURL(env, "CADENCE_REPLAY_OUTPUT")
        let corpusData = try Data(contentsOf: corpusURL), requestsData = try Data(contentsOf: requestsURL)
        let generatorData = try Data(contentsOf: generatorURL), resultsData = try Data(contentsOf: resultsURL)
        let policyData = try Data(contentsOf: policyURL)
        let requestPolicyData = try Data(contentsOf: requestPolicyURL)
        let recipientPolicyData = try Data(contentsOf: recipientPolicyURL)
        let corpus = try JSONDecoder().decode(RefinementReplayCorpus.self, from: corpusData)
        let requests = try JSONDecoder().decode(RefinementReplayRequests.self, from: requestsData)
        let results = try JSONDecoder().decode(RefinementReplayResults.self, from: resultsData)
        let ids = Set(corpus.cases.map(\.id))
        guard corpus.schemaVersion == 1, corpus.syntheticOnly, !ids.isEmpty, ids.count == corpus.cases.count,
              requests.schemaVersion == 2, requests.syntheticOnly, requests.corpusSHA256 == refinementHash(corpusData),
              Set(requests.requests.map(\.id)) == ids, requests.requests.count == ids.count,
              results.schemaVersion == 2, results.corpusSHA256 == refinementHash(corpusData),
              results.manifest.state == "complete", results.manifest.requestsSHA256 == refinementHash(requestsData),
              results.manifest.generatorSHA256 == refinementHash(generatorData), results.manifest.expectedCaseCount == ids.count,
              results.manifest.completedCaseCount == ids.count, Set(results.results.map(\.id)) == ids,
              results.results.count == ids.count, results.manifest.hasRecognizedSettings,
              results.manifest.hasValidSplitMetadata(for: results.results) else { throw RefinementReplayError.invalidArtifact }
        let requestByID = Dictionary(uniqueKeysWithValues: requests.requests.map { ($0.id, $0) })
        let resultByID = Dictionary(uniqueKeysWithValues: results.results.map { ($0.id, $0) })
        var rows: [RefinementReplayRow] = []
        for fixture in corpus.cases {
            let exported = try #require(requestByID[fixture.id])
            let result = try #require(resultByID[fixture.id])
            let reconstructed = try refinementRequest(fixture)
            let input = try ScribeDraftRefinementPolicy.providerSafeInput(for: reconstructed, destination: .legacyLocal)
            guard exported.preparedDraft == nil,
                  exported.requestSHA256 == refinementRequestHash(system: exported.system, user: exported.user),
                  result.executionKind == "MODEL_GENERATION", result.elapsedMilliseconds >= 0 else { throw RefinementReplayError.invalidArtifact }
            let compilerMatchesCurrent = exported.system == input.systemMessage && exported.user == input.userMessage
            switch result.status {
            case "GENERATED":
                guard let draft = result.draft else { throw RefinementReplayError.invalidArtifact }
                do {
                    let normalized = try ScribeOutputPolicy.normalizedOutput(draft)
                    let effective = ScribeDraftRefinementPolicy.reviseUnchangedOutput(normalized, for: reconstructed)
                    _ = try ScribeDraftRefinementPolicy.validateOutput(effective, for: reconstructed)
                    rows.append(.init(
                        id: fixture.id, generationStatus: "GENERATED", readiness: "READY", reason: nil,
                        compilerMatchesCurrent: compilerMatchesCurrent,
                        boundedRevisionApplied: Data(effective.utf8) != Data(normalized.utf8),
                        unchangedAfterRevision: Data(effective.utf8) == Data(reconstructed.baseDraft.utf8)
                    ))
                } catch {
                    rows.append(.init(id: fixture.id, generationStatus: "GENERATED", readiness: "REJECTED", reason: "refinementPolicy", compilerMatchesCurrent: compilerMatchesCurrent))
                }
            case "FAILED":
                guard result.draft == nil else { throw RefinementReplayError.invalidArtifact }
                rows.append(.init(id: fixture.id, generationStatus: "FAILED", readiness: "NOT_GENERATED", reason: "generationFailed", compilerMatchesCurrent: compilerMatchesCurrent))
            case "UNAVAILABLE":
                guard result.draft == nil else { throw RefinementReplayError.invalidArtifact }
                rows.append(.init(id: fixture.id, generationStatus: "UNAVAILABLE", readiness: "NOT_GENERATED", reason: "generationUnavailable", compilerMatchesCurrent: compilerMatchesCurrent))
            default: throw RefinementReplayError.invalidArtifact
            }
        }
        try refinementWrite(RefinementReplayReport(corpusSHA256: refinementHash(corpusData), requestsSHA256: refinementHash(requestsData), generatorSHA256: refinementHash(generatorData), resultsSHA256: refinementHash(resultsData), refinementPolicySourceSHA256: refinementHash(policyData), requestPolicySourceSHA256: refinementHash(requestPolicyData), recipientRestrictionPolicySourceSHA256: refinementHash(recipientPolicyData), rows: rows), to: outputURL)
    }

    @MainActor
    private func refinementRequest(_ f: RefinementReplayCase) throws -> ScribeDraftRefinementRequest {
        let environment: WritingEnvironmentID = f.family == "coding" ? .claudeCode : .global
        let original = ScribeLiteralNormalizer.normalize(f.originalSpokenRequest, environmentID: environment)
        let instruction = ScribeLiteralNormalizer.normalize(f.instruction, environmentID: environment)
        guard original.parseStatus == .clean, instruction.parseStatus == .clean else { throw RefinementReplayError.invalidArtifact }
        let origin = ScribeDraftRevisionOrigin(actionID: UUID(), captureID: UUID(), target: .init(processIdentifier: 42, bundleIdentifier: "com.example.synthetic-refinement-target"), providerActionIdentity: .init(configurationID: UUID(), libraryRevision: 1, selectedModelID: "synthetic-local-model-binding"))
        let store = ScribeDraftRevisionStore(); let session = store.start(origin: origin, originalSpokenRequest: f.originalSpokenRequest, initialDraft: f.baseDraft)
        let token = try store.beginRevision(sessionID: session.id, origin: origin, baseVersionID: session.currentVersion.id, revisionUtterance: instruction.text)
        let originalRequest = ScribeRequest.directDictation(id: origin.actionID, processedDictation: original.text, exactLiterals: original.exactLiterals)
        return try ScribeDraftRefinementPolicy.request(token: token, session: session, originalRequest: originalRequest, instructionLiterals: original.exactLiterals + instruction.exactLiterals)
    }
}

private struct RefinementReplayCorpus: Decodable { let schemaVersion: Int; let syntheticOnly: Bool; let cases: [RefinementReplayCase] }
private struct RefinementReplayCase: Decodable { let id, family, originalSpokenRequest, baseDraft, instruction: String }
private struct RefinementReplayRequests: Decodable { let schemaVersion: Int; let syntheticOnly: Bool; let corpusSHA256: String; let requests: [RefinementReplayRequest] }
private struct RefinementReplayRequest: Decodable { let id, system, user, requestSHA256: String; let preparedDraft: String? }
private struct RefinementReplayResults: Decodable { let schemaVersion: Int; let corpusSHA256: String; let results: [RefinementReplayResult]; let manifest: RefinementReplayManifest
    enum CodingKeys: String, CodingKey { case schemaVersion, corpusSHA256, results, manifest = "runManifest" } }
private struct RefinementReplayResult: Decodable { let id, status: String; let draft, executionKind: String?; let elapsedMilliseconds: Int }
private struct RefinementReplayManifest: Decodable {
    let state, requestsSHA256, generatorSHA256, providerID, sampling: String
    let expectedCaseCount, completedCaseCount: Int
    let settingsRevision, maximumResponseTokens, generationTimeoutMilliseconds: Int?
    let expectedModelCaseCount, expectedPreparedDraftCaseCount, completedModelCaseCount, completedPreparedDraftCaseCount, modelElapsedMilliseconds, preparedDraftElapsedMilliseconds: Int?
    enum CodingKeys: String, CodingKey { case state, requestsSHA256, generatorSHA256, providerID, sampling, expectedCaseCount, completedCaseCount, settingsRevision, maximumResponseTokens, generationTimeoutMilliseconds, expectedModelCaseCount, expectedPreparedDraftCaseCount, completedModelCaseCount, completedPreparedDraftCaseCount, modelElapsedMilliseconds, preparedDraftElapsedMilliseconds }
    var hasRecognizedSettings: Bool { providerID == "legacyLocal" && sampling == "greedy" && ((settingsRevision == nil || settingsRevision == 1) ? maximumResponseTokens == 1024 && generationTimeoutMilliseconds == nil : settingsRevision == 2 && maximumResponseTokens == nil && generationTimeoutMilliseconds == 30_000) }
    func hasValidSplitMetadata(for results: [RefinementReplayResult]) -> Bool { let model = results.filter { $0.executionKind == "MODEL_GENERATION" }; let prepared = results.filter { $0.executionKind == "PREPARED_DRAFT" }; return expectedModelCaseCount == model.count && expectedPreparedDraftCaseCount == prepared.count && completedModelCaseCount == model.count && completedPreparedDraftCaseCount == prepared.count && modelElapsedMilliseconds == model.reduce(0) { $0 + $1.elapsedMilliseconds } && preparedDraftElapsedMilliseconds == prepared.reduce(0) { $0 + $1.elapsedMilliseconds } }
}
private struct RefinementReplayRow: Encodable {
    let id, generationStatus, readiness: String
    let reason: String?
    let compilerMatchesCurrent: Bool
    var boundedRevisionApplied = false
    var unchangedAfterRevision = false
}
private struct RefinementReplayReport: Encodable { let schemaVersion = 1; let semanticQuality = "NOT_EVALUATED"; let corpusSHA256, requestsSHA256, generatorSHA256, resultsSHA256, refinementPolicySourceSHA256, requestPolicySourceSHA256, recipientRestrictionPolicySourceSHA256: String; let rows: [RefinementReplayRow] }
private enum RefinementReplayError: Error { case missingConfiguration, invalidArtifact }
private func refinementURL(_ env: [String: String], _ key: String) throws -> URL { guard let value = env[key], !value.isEmpty else { throw RefinementReplayError.missingConfiguration }; return URL(fileURLWithPath: value) }
private func refinementHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func refinementRequestHash(system: String, user: String) -> String { var data = Data(system.utf8); data.append(0); data.append(contentsOf: user.utf8); return refinementHash(data) }
private func refinementWrite(_ report: RefinementReplayReport, to url: URL) throws { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(report).write(to: url, options: .atomic) }
