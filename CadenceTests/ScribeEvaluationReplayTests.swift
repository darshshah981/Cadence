import CryptoKit
import Foundation
import Testing
@testable import Cadence

private final class ScribeEvaluationReplayBundle: NSObject {}

/// Opt-in replay of already-generated, synthetic model artifacts. This test
/// never invokes a provider. Generation outcome and review-readiness outcome
/// are intentionally reported as separate facts.
struct ScribeEvaluationReplayTests {
    @Test
    func replayBoundSyntheticResultsThroughProductionOutputPolicies() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CADENCE_REPLAY_SCRIBE_EVALUATION"] == "1" else { return }
        let requestsURL = try requiredURL(environment, "CADENCE_REPLAY_REQUESTS")
        let generatorURL = try requiredURL(environment, "CADENCE_REPLAY_GENERATOR")
        let resultsURL = try requiredURL(environment, "CADENCE_REPLAY_RESULTS")
        let outputURL = try requiredURL(environment, "CADENCE_REPLAY_OUTPUT")
        let requestPolicyURL = try requiredURL(environment, "CADENCE_REPLAY_REQUEST_POLICY_SOURCE")
        let recipientPolicyURL = try requiredURL(environment, "CADENCE_REPLAY_RECIPIENT_POLICY_SOURCE")
        // Default is the bundled development corpus. A caller may explicitly
        // stage a separately named synthetic corpus (for example, cold
        // holdout evidence); no path is inferred from result artifacts.
        let fixtureURL: URL
        if let path = environment["CADENCE_REPLAY_INSTRUCTION_CORPUS"], !path.isEmpty {
            fixtureURL = URL(fileURLWithPath: path)
        } else {
            fixtureURL = try #require(Bundle(for: ScribeEvaluationReplayBundle.self).url(
                forResource: "instruction-following", withExtension: "json"
            ))
        }

        let corpusData = try Data(contentsOf: fixtureURL)
        let requestsData = try Data(contentsOf: requestsURL)
        let generatorData = try Data(contentsOf: generatorURL)
        let resultsData = try Data(contentsOf: resultsURL)
        let requestPolicyData = try Data(contentsOf: requestPolicyURL)
        let recipientPolicyData = try Data(contentsOf: recipientPolicyURL)
        let corpus = try JSONDecoder().decode(ReplayCorpus.self, from: corpusData)
        let fixtureIDs = Set(corpus.cases.map(\.id))
        guard corpus.schemaVersion == 1, corpus.syntheticOnly,
              !corpus.cases.isEmpty, fixtureIDs.count == corpus.cases.count else {
            throw ReplayError.invalidArtifact
        }

        let requests = try JSONDecoder().decode(ReplayRequests.self, from: requestsData)
        let requestIDs = Set(requests.requests.map(\.id))
        guard (requests.schemaVersion == 1 || requests.schemaVersion == 2), requests.syntheticOnly,
              requests.corpusSHA256 == hash(corpusData), requestIDs == fixtureIDs,
              requestIDs.count == requests.requests.count else {
            throw ReplayError.invalidArtifact
        }
        for request in requests.requests {
            guard requests.schemaVersion == 2 || !request.containsPreparedDraft,
                  !request.containsPreparedDraft || request.preparedDraft?.isEmpty == false,
                  request.requestSHA256 == requestHash(system: request.system, user: request.user,
                                                       preparedDraft: request.preparedDraft,
                                                       schemaVersion: requests.schemaVersion) else {
                throw ReplayError.invalidArtifact
            }
        }

        let envelope = try JSONDecoder().decode(ReplayResults.self, from: resultsData)
        let resultIDs = Set(envelope.results.map(\.id))
        guard envelope.schemaVersion == requests.schemaVersion,
              envelope.corpusSHA256 == hash(corpusData),
              envelope.runManifest.state == "complete",
              envelope.runManifest.requestsSHA256 == hash(requestsData),
              envelope.runManifest.generatorSHA256 == hash(generatorData),
              envelope.runManifest.hasRecognizedGenerationSettings,
              envelope.runManifest.expectedCaseCount == corpus.cases.count,
              envelope.runManifest.completedCaseCount == envelope.results.count,
              resultIDs == fixtureIDs, resultIDs.count == envelope.results.count else {
            throw ReplayError.invalidArtifact
        }
        if envelope.schemaVersion == 2 {
            guard envelope.runManifest.hasValidSplitExecutionMetadata(for: envelope.results) else {
                throw ReplayError.invalidArtifact
            }
        }

        let resultByID = Dictionary(uniqueKeysWithValues: envelope.results.map { ($0.id, $0) })
        let requestByID = Dictionary(uniqueKeysWithValues: requests.requests.map { ($0.id, $0) })
        var rows: [ReplayReportRow] = []
        for fixture in corpus.cases {
            let result = try #require(resultByID[fixture.id])
            let request = try #require(requestByID[fixture.id])
            let expectedExecutionKind = request.preparedDraft == nil ? "MODEL_GENERATION" : "PREPARED_DRAFT"
            guard (envelope.schemaVersion == 1 && !result.containsExecutionKind)
                    || (envelope.schemaVersion == 2 && result.executionKind == expectedExecutionKind) else {
                throw ReplayError.invalidArtifact
            }
            switch result.status {
            case "GENERATED":
                guard let draft = result.draft else { throw ReplayError.invalidArtifact }
                if envelope.schemaVersion == 2, expectedExecutionKind == "PREPARED_DRAFT",
                   Data(draft.utf8) != Data(request.preparedDraft!.utf8) {
                    throw ReplayError.invalidArtifact
                }
                let normalized = ScribeLiteralNormalizer.normalize(
                    fixture.spoken, environmentID: fixture.family == "coding" ? .claudeCode : .global
                )
                let requestLiterals = ScribeRequestPolicy.directCodingLiterals(
                    in: normalized.text, existing: normalized.exactLiterals
                )
                let protectedValues = requestLiterals.map(\.value)
                let writing = ScribeWritingDirectionParser.parse(
                    normalized.text, protectedValues: protectedValues
                )
                // A direct request with no source never reaches generation in
                // the coordinator. The offline runner deliberately generated
                // one anyway; it cannot become review-ready in a policy replay.
                if !writing.unresolvedReferences.isEmpty {
                    rows.append(.init(id: fixture.id, generationStatus: result.status, executionKind: result.executionKind ?? "MODEL_GENERATION", reviewReadiness: "REJECTED", rejectionCategory: "missingSource"))
                    continue
                }
                do {
                    let validated = try ScribeRequestPolicy.validateOutput(
                        draft, requiredLiterals: requestLiterals, spokenRequest: normalized.text
                    )
                    try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                        validated, spokenRequest: normalized.text, protectedValues: protectedValues
                    )
                    try ScribeRequestPolicy.validateDirectDraftRecipient(
                        validated, spokenRequest: normalized.text, protectedValues: protectedValues
                    )
                    do {
                        try ScribeRecipientRestrictionPolicy.validate(
                            output: validated,
                            requirements: ScribeRecipientRestrictionPolicy.extract(from: fixture.spoken)
                        )
                        rows.append(.init(id: fixture.id, generationStatus: result.status, executionKind: result.executionKind ?? "MODEL_GENERATION", reviewReadiness: "READY", rejectionCategory: nil))
                    } catch is ScribeRecipientRestrictionValidationError {
                        rows.append(.init(id: fixture.id, generationStatus: result.status, executionKind: result.executionKind ?? "MODEL_GENERATION", reviewReadiness: "REJECTED", rejectionCategory: "recipientRestriction"))
                    }
                } catch {
                    rows.append(.init(id: fixture.id, generationStatus: result.status, executionKind: result.executionKind ?? "MODEL_GENERATION", reviewReadiness: "REJECTED", rejectionCategory: "outputPolicy"))
                }
            case "FAILED":
                guard result.draft == nil else { throw ReplayError.invalidArtifact }
                rows.append(.init(id: fixture.id, generationStatus: result.status, executionKind: result.executionKind ?? "MODEL_GENERATION", reviewReadiness: "NOT_GENERATED", rejectionCategory: "generationFailed"))
            default:
                throw ReplayError.invalidArtifact
            }
        }
        guard rows.count == corpus.cases.count else { throw ReplayError.invalidArtifact }
        let report = ReplayReport(
            corpusSHA256: hash(corpusData), requestsSHA256: hash(requestsData),
            generatorSHA256: hash(generatorData), resultsSHA256: hash(resultsData),
            requestPolicySourceSHA256: hash(requestPolicyData), recipientRestrictionPolicySourceSHA256: hash(recipientPolicyData),
            rows: rows
        )
        try writeAtomically(report, to: outputURL)
    }
}

private struct ReplayCorpus: Decodable {
    let schemaVersion: Int
    let syntheticOnly: Bool
    let cases: [ReplayFixture]
}

private struct ReplayFixture: Decodable { let id, family, spoken: String }
private struct ReplayRequests: Decodable {
    let schemaVersion: Int
    let syntheticOnly: Bool
    let corpusSHA256: String
    let requests: [ReplayRequest]
}
private struct ReplayRequest: Decodable {
    let id, system, user, requestSHA256: String
    let preparedDraft: String?
    let containsPreparedDraft: Bool
    private enum CodingKeys: String, CodingKey { case id, system, user, requestSHA256, preparedDraft }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); system = try values.decode(String.self, forKey: .system)
        user = try values.decode(String.self, forKey: .user); requestSHA256 = try values.decode(String.self, forKey: .requestSHA256)
        containsPreparedDraft = values.contains(.preparedDraft)
        preparedDraft = try values.decodeIfPresent(String.self, forKey: .preparedDraft)
    }
}
private struct ReplayResults: Decodable {
    let schemaVersion: Int
    let corpusSHA256: String
    let results: [ReplayResult]
    let runManifest: ReplayManifest
}
private struct ReplayResult: Decodable {
    let id, status: String; let draft, executionKind: String?
    let elapsedMilliseconds: Int
    let containsExecutionKind: Bool
    private enum CodingKeys: String, CodingKey { case id, status, draft, elapsedMilliseconds, executionKind }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); status = try values.decode(String.self, forKey: .status)
        draft = try values.decodeIfPresent(String.self, forKey: .draft)
        elapsedMilliseconds = try values.decode(Int.self, forKey: .elapsedMilliseconds)
        containsExecutionKind = values.contains(.executionKind)
        executionKind = try values.decodeIfPresent(String.self, forKey: .executionKind)
    }
}
private struct ReplayManifest: Decodable {
    let state, requestsSHA256, generatorSHA256: String
    let expectedCaseCount, completedCaseCount: Int
    let settingsRevision, maximumResponseTokens, generationTimeoutMilliseconds: Int?
    let containsSettingsRevision, containsMaximumResponseTokens, containsGenerationTimeout: Bool
    let expectedModelCaseCount, expectedPreparedDraftCaseCount: Int?
    let completedModelCaseCount, completedPreparedDraftCaseCount: Int?
    let modelElapsedMilliseconds, preparedDraftElapsedMilliseconds: Int?
    private enum CodingKeys: String, CodingKey {
        case state, requestsSHA256, generatorSHA256, expectedCaseCount, completedCaseCount
        case settingsRevision, maximumResponseTokens, generationTimeoutMilliseconds
        case expectedModelCaseCount, expectedPreparedDraftCaseCount, completedModelCaseCount, completedPreparedDraftCaseCount
        case modelElapsedMilliseconds, preparedDraftElapsedMilliseconds
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(String.self, forKey: .state); requestsSHA256 = try values.decode(String.self, forKey: .requestsSHA256)
        generatorSHA256 = try values.decode(String.self, forKey: .generatorSHA256)
        expectedCaseCount = try values.decode(Int.self, forKey: .expectedCaseCount); completedCaseCount = try values.decode(Int.self, forKey: .completedCaseCount)
        containsSettingsRevision = values.contains(.settingsRevision); containsMaximumResponseTokens = values.contains(.maximumResponseTokens)
        containsGenerationTimeout = values.contains(.generationTimeoutMilliseconds)
        settingsRevision = try values.decodeIfPresent(Int.self, forKey: .settingsRevision)
        maximumResponseTokens = try values.decodeIfPresent(Int.self, forKey: .maximumResponseTokens)
        generationTimeoutMilliseconds = try values.decodeIfPresent(Int.self, forKey: .generationTimeoutMilliseconds)
        expectedModelCaseCount = try values.decodeIfPresent(Int.self, forKey: .expectedModelCaseCount)
        expectedPreparedDraftCaseCount = try values.decodeIfPresent(Int.self, forKey: .expectedPreparedDraftCaseCount)
        completedModelCaseCount = try values.decodeIfPresent(Int.self, forKey: .completedModelCaseCount)
        completedPreparedDraftCaseCount = try values.decodeIfPresent(Int.self, forKey: .completedPreparedDraftCaseCount)
        modelElapsedMilliseconds = try values.decodeIfPresent(Int.self, forKey: .modelElapsedMilliseconds)
        preparedDraftElapsedMilliseconds = try values.decodeIfPresent(Int.self, forKey: .preparedDraftElapsedMilliseconds)
    }
    var hasRecognizedGenerationSettings: Bool {
        if !containsSettingsRevision || settingsRevision == 1 {
            return maximumResponseTokens == 1024 && !containsGenerationTimeout
        }
        return settingsRevision == 2 && containsMaximumResponseTokens && maximumResponseTokens == nil
            && generationTimeoutMilliseconds == 30_000
    }
    func hasValidSplitExecutionMetadata(for results: [ReplayResult]) -> Bool {
        let model = results.filter { $0.executionKind == "MODEL_GENERATION" }
        let prepared = results.filter { $0.executionKind == "PREPARED_DRAFT" }
        return expectedModelCaseCount == model.count && expectedPreparedDraftCaseCount == prepared.count
            && completedModelCaseCount == model.count && completedPreparedDraftCaseCount == prepared.count
            && modelElapsedMilliseconds == model.reduce(0, { $0 + $1.elapsedMilliseconds })
            && preparedDraftElapsedMilliseconds == prepared.reduce(0, { $0 + $1.elapsedMilliseconds })
    }
}
private struct ReplayReport: Encodable {
    let schemaVersion = 2
    let semanticQuality = "NOT_EVALUATED"
    let corpusSHA256, requestsSHA256, generatorSHA256, resultsSHA256: String
    let requestPolicySourceSHA256, recipientRestrictionPolicySourceSHA256: String
    let rows: [ReplayReportRow]
    var summary: [String: Int] {
        ["total": rows.count, "ready": rows.filter { $0.reviewReadiness == "READY" }.count,
         "rejected": rows.filter { $0.reviewReadiness == "REJECTED" }.count,
         "notGenerated": rows.filter { $0.reviewReadiness == "NOT_GENERATED" }.count,
         "modelGeneration": rows.filter { $0.executionKind == "MODEL_GENERATION" }.count,
         "preparedDraft": rows.filter { $0.executionKind == "PREPARED_DRAFT" }.count]
    }
    let limitations = [
        "Generation status and review readiness are separate outcomes.",
        "Semantic quality is not evaluated by this policy replay.",
        "A guard rejection is not a generation-quality pass.",
        "Direct-request missing-source preflight can reject an offline model result before generation would run in the app.",
        "This replay validates synthetic artifacts only and does not invoke or authenticate a model."
    ]
}
private struct ReplayReportRow: Encodable {
    let id, generationStatus, executionKind, reviewReadiness: String
    let rejectionCategory: String?
}

private func requiredURL(_ environment: [String: String], _ key: String) throws -> URL {
    guard let path = environment[key], !path.isEmpty else { throw ReplayError.missingConfiguration }
    return URL(fileURLWithPath: path)
}
private enum ReplayError: Error { case missingConfiguration, invalidArtifact }
private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func requestHash(system: String, user: String, preparedDraft: String?, schemaVersion: Int) -> String {
    var data = Data(system.utf8); data.append(0); data.append(contentsOf: user.utf8)
    if schemaVersion == 2, let preparedDraft {
        data.append(0); data.append(contentsOf: "preparedDraft".utf8); data.append(0)
        data.append(contentsOf: preparedDraft.utf8)
    }
    return hash(data)
}
private func writeAtomically(_ report: ReplayReport, to url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: url, options: .atomic)
}
