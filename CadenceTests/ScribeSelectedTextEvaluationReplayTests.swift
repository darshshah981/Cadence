import CryptoKit
import Foundation
import Testing
@testable import Cadence

/// Saved synthetic results only. This reconstructs current selected-text input
/// and executes current output guards; it never calls a provider or capture API.
@MainActor
struct ScribeSelectedTextEvaluationReplayTests {
    @Test
    func replayBoundSyntheticSelectedTextResults() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["CADENCE_REPLAY_SCRIBE_SELECTED_TEXT"] == "1" else { return }
        let corpus = try selectedReplayURL(env, "CADENCE_REPLAY_SELECTED_CORPUS")
        let requests = try selectedReplayURL(env, "CADENCE_REPLAY_REQUESTS")
        let results = try selectedReplayURL(env, "CADENCE_REPLAY_RESULTS")
        let generator = try selectedReplayURL(env, "CADENCE_REPLAY_GENERATOR")
        let policyDirectory = try selectedReplayURL(env, "CADENCE_REPLAY_SELECTED_POLICY_DIRECTORY")
        let policyManifest = try selectedReplayURL(env, "CADENCE_REPLAY_SELECTED_POLICY_HASH_MANIFEST")
        let temporaryDirectory = try selectedReplayURL(env, "CADENCE_REPLAY_SELECTED_TEMP_DIRECTORY")
        let output = try selectedReplayURL(env, "CADENCE_REPLAY_OUTPUT")
        let policyURLs = selectedReplayPolicyPaths.map { policyDirectory.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent) }
        try selectedReplayValidateOutput(output, temporaryDirectory: temporaryDirectory, inputs: [corpus, requests, results, generator, policyManifest] + policyURLs)
        let staged = try Dictionary(uniqueKeysWithValues: zip(selectedReplayPolicyPaths, policyURLs).map { ($0.0, try Data(contentsOf: $0.1)) })
        // The trusted shell verifies checkout bytes before/after native replay.
        // Reading only staged files avoids Documents TCC prompts in the test host.
        let expectedHashes = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: policyManifest))
        let report = try selectedReplayReport(
            corpusData: Data(contentsOf: corpus), requestsData: Data(contentsOf: requests),
            resultsData: Data(contentsOf: results), generatorData: Data(contentsOf: generator),
            stagedPolicySources: staged, expectedPolicyHashes: expectedHashes
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    @Test
    func completeArtifactReplaysCurrentCompilerAndReturnsContentFreeReadiness() throws {
        let fixture = try SelectedReplayFixture()
        let report = try fixture.report()
        #expect(report.rows.count == 1)
        #expect(report.rows[0].reviewReadiness == "READY")
        #expect(report.rows[0].compilerMatchesCurrent)
        #expect(report.semanticQuality == "NOT_EVALUATED")
        let bytes = try JSONEncoder().encode(report)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(fixture.source))
        #expect(!text.contains(fixture.spoken))
        #expect(report.generatorSHA256 == selectedReplayHash(fixture.generator))
        #expect(report.currentPolicySourceSHA256.count == selectedReplayPolicyPaths.count)
    }

    @Test
    func staleIncompleteAndMismatchedArtifactsAreRejected() throws {
        let fixture = try SelectedReplayFixture()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["state"] = "running" },
            { $0["requestsSHA256"] = String(repeating: "0", count: 64) },
            { $0["generatorSHA256"] = String(repeating: "0", count: 64) },
            { $0["expectedCaseCount"] = 2 },
            { $0["completedCaseCount"] = 0 },
            { $0.removeValue(forKey: "maximumResponseTokens") },
            { $0["maximumResponseTokens"] = 1_024 },
            { $0["settingsRevision"] = 1 },
            { $0["generationTimeoutMilliseconds"] = 1 },
            { $0["providerID"] = "deepSeek" },
            { $0["sampling"] = "random" },
            { $0["completedModelCaseCount"] = 0 },
            { $0.removeValue(forKey: "modelElapsedMilliseconds") },
            { $0["preparedDraftElapsedMilliseconds"] = 1 },
            { $0["finishedAt"] = "invalid" }
        ]
        for mutate in mutations {
            var root = try selectedReplayObject(fixture.results)
            var manifest = try #require(root["runManifest"] as? [String: Any])
            mutate(&manifest); root["runManifest"] = manifest
            #expect(throws: SelectedReplayError.invalidArtifact) { try fixture.report(results: selectedReplayData(root)) }
        }
        var incomplete = try selectedReplayObject(fixture.results)
        incomplete["results"] = []
        #expect(throws: SelectedReplayError.invalidArtifact) { try fixture.report(results: selectedReplayData(incomplete)) }
        var duplicate = try selectedReplayObject(fixture.results)
        let row = try #require((duplicate["results"] as? [[String: Any]])?.first)
        duplicate["results"] = [row, row]
        #expect(throws: SelectedReplayError.invalidArtifact) { try fixture.report(results: selectedReplayData(duplicate)) }
        var changedPolicies = fixture.policies
        changedPolicies[selectedReplayPolicyPaths[0]] = Data("stale guard".utf8)
        #expect(throws: SelectedReplayError.stalePolicy) { try fixture.report(stagedPolicies: changedPolicies) }
        #expect(throws: SelectedReplayError.invalidArtifact) { try fixture.report(generator: Data("different generator".utf8)) }
    }

    @Test
    func staleCompilerIsRejectedEvenIfEnvelopeHashesAreRecomputed() throws {
        let fixture = try SelectedReplayFixture()
        var requests = try selectedReplayObject(fixture.requests)
        var row = try #require((requests["requests"] as? [[String: Any]])?.first)
        row["system"] = "A stale compiler instruction"
        row["requestSHA256"] = selectedReplayRequestHash(system: "A stale compiler instruction", user: try #require(row["user"] as? String))
        requests["requests"] = [row]
        let requestBytes = try selectedReplayData(requests)
        var results = try selectedReplayObject(fixture.results)
        var manifest = try #require(results["runManifest"] as? [String: Any])
        manifest["requestsSHA256"] = selectedReplayHash(requestBytes); results["runManifest"] = manifest
        #expect(throws: SelectedReplayError.staleCompiler) {
            try fixture.report(requests: requestBytes, results: selectedReplayData(results))
        }
    }

    @Test
    func canonicallyEquivalentButByteDifferentCompilerInputIsRejected() throws {
        let fixture = try SelectedReplayFixture(source: "Caf\u{e9} is ready.")
        var requests = try selectedReplayObject(fixture.requests)
        var row = try #require((requests["requests"] as? [[String: Any]])?.first)
        let original = try #require(row["user"] as? String)
        let decomposed = original.replacingOccurrences(of: "\u{e9}", with: "e\u{301}")
        #expect(original == decomposed)
        #expect(Data(original.utf8) != Data(decomposed.utf8))
        row["user"] = decomposed
        row["requestSHA256"] = selectedReplayRequestHash(system: try #require(row["system"] as? String), user: decomposed)
        requests["requests"] = [row]
        let requestBytes = try selectedReplayData(requests)
        var results = try selectedReplayObject(fixture.results)
        var manifest = try #require(results["runManifest"] as? [String: Any])
        manifest["requestsSHA256"] = selectedReplayHash(requestBytes); results["runManifest"] = manifest
        #expect(throws: SelectedReplayError.staleCompiler) {
            try fixture.report(requests: requestBytes, results: selectedReplayData(results))
        }
    }

    @Test
    func replayUsesSourceLeakExemptionButOnlyVoiceMayAuthorizeLiteralRemoval() throws {
        let marker = try SelectedReplayFixture(source: "Investigate why Spoken writing request: appears.", spoken: "Make this shorter.", draft: "Investigate why Spoken writing request: appears.")
        #expect(try marker.report().rows[0].reviewReadiness == "READY")
        let sourceInstruction = try SelectedReplayFixture(source: "Remove --verbose from the example.", spoken: "Make this shorter.", draft: "Remove the flag from the example.")
        #expect(try sourceInstruction.report().rows[0].rejectionCategory == "outputPolicy")
        let quotedSource = try SelectedReplayFixture(source: "Please include the phrase \"Make it shorter\" in the review note.", spoken: "Make this warmer.", draft: "Make it shorter")
        #expect(try quotedSource.report().rows[0].rejectionCategory == "outputPolicy")
    }

    @Test
    func replayAppliesOnlyBoundedUnchangedSelectionRevision() throws {
        let warm = try SelectedReplayFixture(
            source: "Maya, the preview is ready for review.", spoken: "Make this warmer."
        ).report()
        #expect(warm.rows[0].reviewReadiness == "READY")
        #expect(warm.rows[0].boundedRevisionApplied)
        #expect(warm.rows[0].noticeCategory == nil)

        let technical = try SelectedReplayFixture(
            source: "Inspect `src/Auth.swift` using --verbose.", spoken: "Make this more concise."
        ).report()
        #expect(technical.rows[0].reviewReadiness == "READY")
        #expect(technical.rows[0].boundedRevisionApplied)
        #expect(technical.rows[0].noticeCategory == nil)

        let formalPartial = try SelectedReplayFixture(
            source: "Hey Olivia, the summary is ready. Please take a look.",
            spoken: "Make this more formal.",
            draft: "Olivia, the summary is ready. Please take a look."
        ).report()
        #expect(formalPartial.rows[0].reviewReadiness == "READY")
        #expect(formalPartial.rows[0].boundedRevisionApplied)
        #expect(formalPartial.rows[0].noticeCategory == nil)

        let quoted = try SelectedReplayFixture(
            source: "Please include the phrase \"Make it shorter\" in the review note.",
            spoken: "Make this warmer.", draft: "Make it shorter"
        ).report()
        #expect(quoted.rows[0].reviewReadiness == "REJECTED")
        #expect(!quoted.rows[0].boundedRevisionApplied)
    }

    @Test
    func replayPreservesRecipientRestrictionsAndBaseOutputValidation() throws {
        let droppedRestriction = try SelectedReplayFixture(source: "Inspect the issue. Do not change code.", spoken: "Make this shorter.", draft: "Inspect the issue.")
        #expect(try droppedRestriction.report().rows[0].rejectionCategory == "recipientRestriction")
        let control = try SelectedReplayFixture(draft: "Bad\u{0}result")
        #expect(try control.report().rows[0].rejectionCategory == "outputPolicy")
        let noOp = try SelectedReplayFixture()
        #expect(try noOp.report().rows[0].reviewReadiness == "READY")
        #expect(try noOp.report().rows[0].noticeCategory == "selectedTextUnchanged")
        // Passing the guard, including unchanged text, does not score whether
        // the requested rewrite actually improved tone or concision.
    }

    @Test
    func failedGenerationIsDistinctFromARejectedDraft() throws {
        let fixture = try SelectedReplayFixture()
        var results = try selectedReplayObject(fixture.results)
        var row = try #require((results["results"] as? [[String: Any]])?.first)
        row["status"] = "FAILED"; row.removeValue(forKey: "draft"); results["results"] = [row]
        let report = try fixture.report(results: selectedReplayData(results))
        #expect(report.rows[0].reviewReadiness == "NOT_GENERATED")
        #expect(report.rows[0].generationStatus == "FAILED")
        row["draft"] = "Unexpected retained output"; results["results"] = [row]
        #expect(throws: SelectedReplayError.invalidArtifact) { try fixture.report(results: selectedReplayData(results)) }
    }
}

private let selectedReplayPolicyPaths = [
    "Cadence/Services/ComposeContextCompiler.swift",
    "Cadence/Models/ComposeGroundedRequestModels.swift",
    "Cadence/Models/ComposeContextSnapshot.swift",
    "Cadence/Services/ComposeSelectedTextContextController.swift",
    "Cadence/Services/ScribeContextPolicy.swift",
    "Cadence/Models/ScribeContextPolicyModels.swift",
    "Cadence/Services/ComposePreferenceResolver.swift",
    "Cadence/Models/ComposeWritingPreferenceModels.swift",
    "Cadence/Services/ComposeSelectedTextRewritePolicy.swift",
    "Cadence/Services/ScribeRequestPolicy.swift",
    "Cadence/Models/ScribeModels.swift",
    "Cadence/Services/ScribeRecipientRestrictionPolicy.swift",
    "Cadence/Services/ScribeWritingDirectionParser.swift",
    "Cadence/Models/ScribeWritingRequest.swift",
    "Cadence/Services/ScribeLiteralNormalizer.swift",
    "Cadence/Models/ScribeProviderCapabilityModels.swift",
    "Cadence/Services/ScribeProviderCapabilityPolicy.swift",
    "Cadence/Services/ScribeCoordinator.swift"
]

@MainActor
private func selectedReplayReport(corpusData: Data, requestsData: Data, resultsData: Data, generatorData: Data,
                                  stagedPolicySources: [String: Data], expectedPolicyHashes: [String: String]) throws -> SelectedReplayReport {
    guard Set(stagedPolicySources.keys) == Set(selectedReplayPolicyPaths),
          Set(expectedPolicyHashes.keys) == Set(selectedReplayPolicyPaths),
          selectedReplayPolicyPaths.allSatisfy({ path in
              guard let source = stagedPolicySources[path], !source.isEmpty else { return false }
              return selectedReplayHash(source) == expectedPolicyHashes[path]
          }) else { throw SelectedReplayError.stalePolicy }
    let corpus: SelectedReplayCorpus
    let requests: SelectedReplayRequests
    let results: SelectedReplayResults
    do {
        corpus = try JSONDecoder().decode(SelectedReplayCorpus.self, from: corpusData)
        requests = try JSONDecoder().decode(SelectedReplayRequests.self, from: requestsData)
        results = try JSONDecoder().decode(SelectedReplayResults.self, from: resultsData)
    } catch { throw SelectedReplayError.invalidArtifact }
    let ids = Set(corpus.cases.map(\.id))
    guard corpus.schemaVersion == 1, corpus.syntheticOnly, !ids.isEmpty, ids.count == corpus.cases.count,
          corpus.cases.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.source.isEmpty && $0.source.utf8.count <= 8 * 1_024 && !$0.spoken.isEmpty }),
          requests.schemaVersion == 2, requests.syntheticOnly, requests.corpusSHA256 == selectedReplayHash(corpusData),
          requests.requests.count == ids.count, Set(requests.requests.map(\.id)) == ids,
          results.schemaVersion == 2, results.corpusSHA256 == selectedReplayHash(corpusData),
          results.results.count == ids.count, Set(results.results.map(\.id)) == ids,
          results.runManifest.valid(requests: requestsData, generator: generatorData, results: results.results, expectedCount: ids.count) else { throw SelectedReplayError.invalidArtifact }
    let requestByID = Dictionary(uniqueKeysWithValues: requests.requests.map { ($0.id, $0) })
    let resultByID = Dictionary(uniqueKeysWithValues: results.results.map { ($0.id, $0) })
    var rows: [SelectedReplayRow] = []
    for fixture in corpus.cases {
        guard let exported = requestByID[fixture.id], let result = resultByID[fixture.id], exported.preparedDraft == nil,
              exported.requestSHA256 == selectedReplayRequestHash(system: exported.system, user: exported.user),
              result.executionKind == "MODEL_GENERATION", result.elapsedMilliseconds >= 0 else { throw SelectedReplayError.invalidArtifact }
        let (request, selection) = try selectedReplayRequest(source: fixture.source, spoken: fixture.spoken)
        let compilation = try selectedReplayCompile(request, selection: selection)
        let input = compilation.input
        try ScribeProviderCapabilityPolicy.validate(input: input, profile: .defaultProfile(for: .legacyLocal), requirements: .selectedTextRewrite)
        guard input.preparedDraft == nil,
              Data(exported.system.utf8) == Data(input.systemMessage.utf8),
              Data(exported.user.utf8) == Data(input.userMessage.utf8) else { throw SelectedReplayError.staleCompiler }
        switch result.status {
        case "GENERATED":
            guard let draft = result.draft else { throw SelectedReplayError.invalidArtifact }
            let readiness: String, rejection: String?
            var notice: String?
            var boundedRevisionApplied = false
            do {
                let normalized = try ScribeOutputPolicy.normalizedOutput(draft)
                let effective = ComposeSelectedTextRewritePolicy.reviseBoundedOutput(
                    normalized, source: selection.selectedText, instruction: request.spokenTranscript
                )
                boundedRevisionApplied = Data(effective.utf8) != Data(normalized.utf8)
                let validated = try ComposeContextCompiler.validateOutput(effective, for: compilation)
                readiness = "READY"; rejection = nil
                if Data(validated.utf8) == Data(selection.selectedText.utf8) { notice = "selectedTextUnchanged" }
            } catch is ScribeRecipientRestrictionValidationError {
                readiness = "REJECTED"; rejection = "recipientRestriction"
            } catch { readiness = "REJECTED"; rejection = "outputPolicy" }
            rows.append(.init(id: fixture.id, generationStatus: result.status, reviewReadiness: readiness, rejectionCategory: rejection, noticeCategory: notice, boundedRevisionApplied: boundedRevisionApplied))
        case "FAILED", "UNAVAILABLE":
            guard result.draft == nil else { throw SelectedReplayError.invalidArtifact }
            rows.append(.init(id: fixture.id, generationStatus: result.status, reviewReadiness: "NOT_GENERATED", rejectionCategory: result.status == "FAILED" ? "generationFailed" : "generationUnavailable", noticeCategory: nil, boundedRevisionApplied: false))
        default: throw SelectedReplayError.invalidArtifact
        }
    }
    return .init(corpusSHA256: selectedReplayHash(corpusData), requestsSHA256: selectedReplayHash(requestsData), resultsSHA256: selectedReplayHash(resultsData), generatorSHA256: selectedReplayHash(generatorData), currentPolicySourceSHA256: stagedPolicySources.mapValues(selectedReplayHash), rows: rows)
}

private func selectedReplayRequest(source: String, spoken: String) throws -> (ScribeRequest, ComposeContextSnapshot) {
    let action = ScribeContextActionBinding(actionID: UUID(), captureID: UUID(), target: .init(processIdentifier: 42, bundleIdentifier: "com.example.synthetic-selection"), opaqueSurfaceID: "synthetic-selection", eligibility: .eligible)
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let process = ApplicationProcessIdentity(processIdentifier: 42, bundleIdentifier: "com.example.synthetic-selection", bundleURL: URL(fileURLWithPath: "/tmp/Synthetic.app"), incarnation: UUID(), launchDate: now)
    let target = ComposeContentCaptureTarget(action: action, source: .init(captureID: action.captureID, target: action.target, process: process, verificationToken: "synthetic", recognitionSignature: .init(role: "AXTextArea", subrole: nil, identifierAncestry: [])))
    let authorization = try ScribeContextPolicy.authorize(
        .init(action: action, operation: .capture(.selectedText)), using: selectedReplayPolicy(),
        permissions: .init(accessibility: true), at: now
    )
    let snapshot = ComposeContextSnapshot(id: UUID(), target: target, selectedRange: .init(location: 0, length: source.utf16.count), selectedText: source, capturedAt: now, completeness: .completeSelectedRange, authorization: authorization)
    let voice = ScribeLiteralNormalizer.normalize(spoken, environmentID: .global)
    guard voice.parseStatus == .clean else { throw SelectedReplayError.invalidArtifact }
    return (.directDictation(id: action.actionID, processedDictation: voice.text, exactLiterals: voice.exactLiterals), snapshot)
}

private func selectedReplayPolicy() -> ScribeContextPolicySnapshot {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    return .init(revision: UUID(uuidString: "AA128E95-7C45-4E97-BEC0-DDB805E7F755")!, isEnabled: true,
                 captureGrants: [.init(id: UUID(uuidString: "601234DF-7004-4896-8082-80067235B4D1")!,
                                      scope: .application(bundleIdentifier: "com.example.synthetic-selection"), categories: [.selectedText],
                                      window: .init(acceptedAt: now - 1, expiresAt: now + 60))])
}

private func selectedReplayCompile(_ request: ScribeRequest, selection: ComposeContextSnapshot) throws -> ComposeGroundedCompilation {
    try ComposeContextCompiler.compileSelectedRewrite(
        request, snapshot: selection, egress: .legacyLocal, policy: selectedReplayPolicy(),
        permissions: .init(accessibility: true), now: selection.capturedAt
    )
}

private struct SelectedReplayCorpus: Decodable { let schemaVersion: Int; let syntheticOnly: Bool; let cases: [SelectedReplayCase] }
private struct SelectedReplayCase: Decodable { let id, source, spoken: String }
private struct SelectedReplayRequests: Decodable { let schemaVersion: Int; let syntheticOnly: Bool; let corpusSHA256: String; let requests: [SelectedReplayRequest] }
private struct SelectedReplayRequest: Decodable { let id, system, user, requestSHA256: String; let preparedDraft: String? }
private struct SelectedReplayResults: Decodable { let schemaVersion: Int; let corpusSHA256: String; let results: [SelectedReplayResult]; let runManifest: SelectedReplayManifest }
private struct SelectedReplayResult: Decodable { let id, status, executionKind: String; let draft: String?; let elapsedMilliseconds: Int }
private struct SelectedReplayManifest: Decodable {
    let state, requestsSHA256, generatorSHA256, providerID, sampling: String
    let settingsRevision, generationTimeoutMilliseconds, expectedCaseCount, completedCaseCount, elapsedMilliseconds: Int
    let expectedModelCaseCount, expectedPreparedDraftCaseCount, completedModelCaseCount, completedPreparedDraftCaseCount: Int
    let modelElapsedMilliseconds, preparedDraftElapsedMilliseconds: Int
    let startedAt, finishedAt, operatingSystem, operatingSystemVersion, build: String
    let explicitNilTokenLimit: Bool
    private enum CodingKeys: String, CodingKey { case state, requestsSHA256, generatorSHA256, providerID, sampling, settingsRevision, maximumResponseTokens, generationTimeoutMilliseconds, expectedCaseCount, completedCaseCount, elapsedMilliseconds, expectedModelCaseCount, expectedPreparedDraftCaseCount, completedModelCaseCount, completedPreparedDraftCaseCount, modelElapsedMilliseconds, preparedDraftElapsedMilliseconds, startedAt, finishedAt, operatingSystem, operatingSystemVersion, build }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(String.self, forKey: .state); requestsSHA256 = try values.decode(String.self, forKey: .requestsSHA256); generatorSHA256 = try values.decode(String.self, forKey: .generatorSHA256)
        providerID = try values.decode(String.self, forKey: .providerID); sampling = try values.decode(String.self, forKey: .sampling)
        settingsRevision = try values.decode(Int.self, forKey: .settingsRevision); generationTimeoutMilliseconds = try values.decode(Int.self, forKey: .generationTimeoutMilliseconds)
        expectedCaseCount = try values.decode(Int.self, forKey: .expectedCaseCount); completedCaseCount = try values.decode(Int.self, forKey: .completedCaseCount); elapsedMilliseconds = try values.decode(Int.self, forKey: .elapsedMilliseconds)
        expectedModelCaseCount = try values.decode(Int.self, forKey: .expectedModelCaseCount); expectedPreparedDraftCaseCount = try values.decode(Int.self, forKey: .expectedPreparedDraftCaseCount)
        completedModelCaseCount = try values.decode(Int.self, forKey: .completedModelCaseCount); completedPreparedDraftCaseCount = try values.decode(Int.self, forKey: .completedPreparedDraftCaseCount)
        modelElapsedMilliseconds = try values.decode(Int.self, forKey: .modelElapsedMilliseconds); preparedDraftElapsedMilliseconds = try values.decode(Int.self, forKey: .preparedDraftElapsedMilliseconds)
        startedAt = try values.decode(String.self, forKey: .startedAt); finishedAt = try values.decode(String.self, forKey: .finishedAt)
        operatingSystem = try values.decode(String.self, forKey: .operatingSystem); operatingSystemVersion = try values.decode(String.self, forKey: .operatingSystemVersion); build = try values.decode(String.self, forKey: .build)
        if values.contains(.maximumResponseTokens) { explicitNilTokenLimit = try values.decodeNil(forKey: .maximumResponseTokens) }
        else { explicitNilTokenLimit = false }
    }
    func valid(requests: Data, generator: Data, results: [SelectedReplayResult], expectedCount: Int) -> Bool {
        guard state == "complete", requestsSHA256 == selectedReplayHash(requests), generatorSHA256 == selectedReplayHash(generator),
              providerID == "legacyLocal", sampling == "greedy", settingsRevision == 2, explicitNilTokenLimit,
              generationTimeoutMilliseconds == 30_000, expectedCaseCount == expectedCount, completedCaseCount == expectedCount,
              expectedModelCaseCount == expectedCount, completedModelCaseCount == expectedCount,
              expectedPreparedDraftCaseCount == 0, completedPreparedDraftCaseCount == 0, preparedDraftElapsedMilliseconds == 0,
              elapsedMilliseconds >= 0, modelElapsedMilliseconds >= 0,
              !operatingSystem.isEmpty, !operatingSystemVersion.isEmpty, !build.isEmpty,
              let started = ISO8601DateFormatter().date(from: startedAt), let finished = ISO8601DateFormatter().date(from: finishedAt), finished >= started else { return false }
        var sum = 0
        for result in results {
            guard result.elapsedMilliseconds >= 0 else { return false }
            let addition = sum.addingReportingOverflow(result.elapsedMilliseconds)
            guard !addition.overflow else { return false }; sum = addition.partialValue
        }
        return sum == modelElapsedMilliseconds && elapsedMilliseconds >= sum
    }
}
private struct SelectedReplayRow: Encodable { let id, generationStatus, reviewReadiness: String; let rejectionCategory, noticeCategory: String?; let boundedRevisionApplied: Bool; let executionKind = "MODEL_GENERATION"; let compilerMatchesCurrent = true }
private struct SelectedReplayReport: Encodable {
    let schemaVersion = 1, semanticQuality = "NOT_EVALUATED"
    let corpusSHA256, requestsSHA256, resultsSHA256, generatorSHA256: String
    let currentPolicySourceSHA256: [String: String]
    let rows: [SelectedReplayRow]
    let limitations = ["Synthetic saved-result replay only; no model call or provider authentication.", "READY means current output guards accept the saved draft, not semantic quality or a successful rewrite.", "Source hashes bind staged policy bytes checked by the trusted shell; they do not cryptographically prove binary provenance.", "Only corpus.cases are replayed; policyOnlyCoverage is not scored here.", "No Accessibility capture, selection replacement, user preferences, history, or UI behavior is exercised."]
}
private enum SelectedReplayError: Error, Equatable { case missingConfiguration, invalidArtifact, staleCompiler, stalePolicy, unsafeOutput }
private func selectedReplayHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func selectedReplayRequestHash(system: String, user: String) -> String { var data = Data(system.utf8); data.append(0); data.append(contentsOf: user.utf8); return selectedReplayHash(data) }
private func selectedReplayURL(_ env: [String: String], _ key: String) throws -> URL { guard let path = env[key], !path.isEmpty else { throw SelectedReplayError.missingConfiguration }; return URL(fileURLWithPath: path) }
private func selectedReplayObject(_ data: Data) throws -> [String: Any] { guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SelectedReplayError.invalidArtifact }; return object }
private func selectedReplayData(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
private func selectedReplayValidateOutput(_ output: URL, temporaryDirectory: URL, inputs: [URL]) throws {
    let resolved = output.standardizedFileURL.resolvingSymlinksInPath()
    let stage = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let temporaryRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
    guard stage.deletingLastPathComponent().path == temporaryRoot.path,
          stage.lastPathComponent.hasPrefix("cadence-selected-replay."),
          resolved.path.hasPrefix(stage.path + "/"),
          inputs.allSatisfy({ $0.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(stage.path + "/") }),
          !inputs.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == resolved }) else { throw SelectedReplayError.unsafeOutput }
    if FileManager.default.fileExists(atPath: resolved.path) {
        let identity = try FileManager.default.attributesOfItem(atPath: resolved.path)
        for input in inputs {
            let other = try FileManager.default.attributesOfItem(atPath: input.path)
            guard (identity[.systemFileNumber] as? NSNumber) != (other[.systemFileNumber] as? NSNumber)
                    || (identity[.systemNumber] as? NSNumber) != (other[.systemNumber] as? NSNumber) else { throw SelectedReplayError.unsafeOutput }
        }
    }
}

@MainActor
private struct SelectedReplayFixture {
    let source, spoken: String
    let corpus, requests, results, generator: Data
    let policies: [String: Data]
    init(source: String = "Keep --verbose in the example.", spoken: String = "Make this shorter.", draft: String? = nil) throws {
        self.source = source; self.spoken = spoken
        generator = Data("synthetic generator identity for integrity tests only".utf8)
        policies = Dictionary(uniqueKeysWithValues: selectedReplayPolicyPaths.map { ($0, Data("synthetic policy binding: \($0)".utf8)) })
        corpus = try selectedReplayData(["schemaVersion": 1, "syntheticOnly": true, "cases": [["id": "fixture", "source": source, "spoken": spoken]]])
        let (request, selection) = try selectedReplayRequest(source: source, spoken: spoken)
        let input = try selectedReplayCompile(request, selection: selection).input
        requests = try selectedReplayData(["schemaVersion": 2, "syntheticOnly": true, "corpusSHA256": selectedReplayHash(corpus), "requests": [["id": "fixture", "system": input.systemMessage, "user": input.userMessage, "requestSHA256": selectedReplayRequestHash(system: input.systemMessage, user: input.userMessage)]]])
        results = try selectedReplayData(["schemaVersion": 2, "corpusSHA256": selectedReplayHash(corpus), "results": [["id": "fixture", "status": "GENERATED", "executionKind": "MODEL_GENERATION", "elapsedMilliseconds": 10, "draft": draft ?? source]], "runManifest": ["state": "complete", "requestsSHA256": selectedReplayHash(requests), "generatorSHA256": selectedReplayHash(generator), "providerID": "legacyLocal", "sampling": "greedy", "settingsRevision": 2, "maximumResponseTokens": NSNull(), "generationTimeoutMilliseconds": 30_000, "expectedCaseCount": 1, "completedCaseCount": 1, "elapsedMilliseconds": 11, "expectedModelCaseCount": 1, "expectedPreparedDraftCaseCount": 0, "completedModelCaseCount": 1, "completedPreparedDraftCaseCount": 0, "modelElapsedMilliseconds": 10, "preparedDraftElapsedMilliseconds": 0, "startedAt": "2026-09-23T00:00:00Z", "finishedAt": "2026-09-23T00:00:01Z", "operatingSystem": "Synthetic", "operatingSystemVersion": "26.0", "build": "synthetic"]])
    }
    func report(requests: Data? = nil, results: Data? = nil, generator: Data? = nil, stagedPolicies: [String: Data]? = nil) throws -> SelectedReplayReport {
        try selectedReplayReport(corpusData: corpus, requestsData: requests ?? self.requests, resultsData: results ?? self.results, generatorData: generator ?? self.generator, stagedPolicySources: stagedPolicies ?? policies, expectedPolicyHashes: policies.mapValues(selectedReplayHash))
    }
}
