// Local, opt-in evaluation of synthetic Compose requests. It never reads app
// settings, credentials, network providers, microphones, or screen context.
// Schema 1 hashes system UTF-8 + NUL + user UTF-8. Schema 2 additionally
// hashes NUL + "preparedDraft" + NUL + prepared-draft UTF-8 when supplied.
import CryptoKit
import Foundation
import FoundationModels

private enum EvaluationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

private struct EvaluationRequest: Decodable {
    let id, system, user, requestSHA256: String
    let preparedDraft: String?
    let containsPreparedDraft: Bool
    private enum CodingKeys: String, CodingKey { case id, system, user, requestSHA256, preparedDraft }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        system = try values.decode(String.self, forKey: .system)
        user = try values.decode(String.self, forKey: .user)
        requestSHA256 = try values.decode(String.self, forKey: .requestSHA256)
        containsPreparedDraft = values.contains(.preparedDraft)
        preparedDraft = try values.decodeIfPresent(String.self, forKey: .preparedDraft)
    }
}
private struct RequestEnvelope: Decodable {
    let schemaVersion: Int
    let syntheticOnly: Bool
    let corpusSHA256: String
    let requests: [EvaluationRequest]
}
private enum ExecutionKind: String, Encodable { case modelGeneration = "MODEL_GENERATION", preparedDraft = "PREPARED_DRAFT" }
/// Content-free failure categories distinguish a timed-out model operation
/// from later admission denials. Never serialize a platform error description:
/// it may contain prompt or generated text.
private enum EvaluationFailureCategory: String, Encodable {
    case timedOut
    case busy
    case cancelled
    case modelError
}
private struct EvaluationResult: Encodable {
    let id, status: String
    let draft: String?
    let elapsedMilliseconds: Int
    let repeatIndex: Int?
    let executionKind: ExecutionKind?
    let failureCategory: EvaluationFailureCategory?
}
private struct RunManifest: Encodable {
    let requestsSHA256, generatorSHA256: String
    let providerID, sampling, state: String
    let settingsRevision: Int
    let maximumResponseTokens: Int?
    let generationTimeoutMilliseconds: Int
    let expectedCaseCount, completedCaseCount, elapsedMilliseconds: Int
    let expectedModelCaseCount, expectedPreparedDraftCaseCount: Int?
    let completedModelCaseCount, completedPreparedDraftCaseCount: Int?
    let modelElapsedMilliseconds, preparedDraftElapsedMilliseconds: Int?
    let startedAt, finishedAt, operatingSystem, operatingSystemVersion, build: String

    private enum CodingKeys: String, CodingKey {
        case requestsSHA256, generatorSHA256, providerID, sampling, state, settingsRevision, maximumResponseTokens, generationTimeoutMilliseconds
        case expectedCaseCount, completedCaseCount, elapsedMilliseconds, expectedModelCaseCount, expectedPreparedDraftCaseCount
        case completedModelCaseCount, completedPreparedDraftCaseCount, modelElapsedMilliseconds, preparedDraftElapsedMilliseconds
        case startedAt, finishedAt, operatingSystem, operatingSystemVersion, build
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestsSHA256, forKey: .requestsSHA256); try values.encode(generatorSHA256, forKey: .generatorSHA256)
        try values.encode(providerID, forKey: .providerID); try values.encode(sampling, forKey: .sampling); try values.encode(state, forKey: .state)
        try values.encode(settingsRevision, forKey: .settingsRevision)
        if let maximumResponseTokens { try values.encode(maximumResponseTokens, forKey: .maximumResponseTokens) }
        else { try values.encodeNil(forKey: .maximumResponseTokens) }
        try values.encode(generationTimeoutMilliseconds, forKey: .generationTimeoutMilliseconds)
        try values.encode(expectedCaseCount, forKey: .expectedCaseCount); try values.encode(completedCaseCount, forKey: .completedCaseCount)
        try values.encode(elapsedMilliseconds, forKey: .elapsedMilliseconds)
        try values.encodeIfPresent(expectedModelCaseCount, forKey: .expectedModelCaseCount); try values.encodeIfPresent(expectedPreparedDraftCaseCount, forKey: .expectedPreparedDraftCaseCount)
        try values.encodeIfPresent(completedModelCaseCount, forKey: .completedModelCaseCount); try values.encodeIfPresent(completedPreparedDraftCaseCount, forKey: .completedPreparedDraftCaseCount)
        try values.encodeIfPresent(modelElapsedMilliseconds, forKey: .modelElapsedMilliseconds); try values.encodeIfPresent(preparedDraftElapsedMilliseconds, forKey: .preparedDraftElapsedMilliseconds)
        try values.encode(startedAt, forKey: .startedAt); try values.encode(finishedAt, forKey: .finishedAt)
        try values.encode(operatingSystem, forKey: .operatingSystem); try values.encode(operatingSystemVersion, forKey: .operatingSystemVersion); try values.encode(build, forKey: .build)
    }
}
private struct ResultEnvelope: Encodable {
    let schemaVersion: Int
    let corpusSHA256: String
    let results: [EvaluationResult]
    let runManifest: RunManifest
}

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func requestHash(system: String, user: String, preparedDraft: String?, schemaVersion: Int) -> String {
    var data = Data(system.utf8)
    data.append(0)
    data.append(contentsOf: user.utf8)
    if schemaVersion == 2, let preparedDraft {
        data.append(0); data.append(contentsOf: "preparedDraft".utf8); data.append(0)
        data.append(contentsOf: preparedDraft.utf8)
    }
    return sha256(data)
}
private func isSHA256(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
private func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private func milliseconds(since date: Date) -> Int { max(0, Int(Date().timeIntervalSince(date) * 1_000)) }

private func validate(_ envelope: RequestEnvelope) throws {
    guard envelope.schemaVersion == 1 || envelope.schemaVersion == 2 else { throw EvaluationError.invalid("Request schemaVersion must be 1 or 2.") }
    guard envelope.syntheticOnly else { throw EvaluationError.invalid("Request envelope must explicitly declare syntheticOnly: true.") }
    guard isSHA256(envelope.corpusSHA256) else { throw EvaluationError.invalid("Request envelope must declare a lowercase SHA-256 corpus hash.") }
    guard !envelope.requests.isEmpty else { throw EvaluationError.invalid("Request envelope must contain at least one request.") }
    var ids = Set<String>()
    for request in envelope.requests {
        guard !request.id.isEmpty, !request.system.isEmpty, !request.user.isEmpty else { throw EvaluationError.invalid("Every request must have nonempty id, system, and user fields.") }
        guard envelope.schemaVersion == 2 || !request.containsPreparedDraft else { throw EvaluationError.invalid("Schema 1 requests must not carry preparedDraft.") }
        guard !request.containsPreparedDraft || request.preparedDraft?.isEmpty == false else { throw EvaluationError.invalid("preparedDraft must be a nonempty string when supplied.") }
        guard ids.insert(request.id).inserted else { throw EvaluationError.invalid("Request envelope contains duplicate IDs.") }
        guard isSHA256(request.requestSHA256), request.requestSHA256 == requestHash(system: request.system, user: request.user, preparedDraft: request.preparedDraft, schemaVersion: envelope.schemaVersion) else {
            throw EvaluationError.invalid("Request \(request.id) has an invalid requestSHA256 binding.")
        }
    }
}
private func environment() -> (operatingSystem: String, operatingSystemVersion: String, build: String) {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return (ProcessInfo.processInfo.operatingSystemVersionString, "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", ProcessInfo.processInfo.environment["CADENCE_EVALUATION_BUILD"] ?? "unknown")
}
private func write(_ envelope: ResultEnvelope, to output: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(envelope).write(to: output, options: .atomic)
}

@main
struct ScribeInstructionEvaluation {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw EvaluationError.invalid("Provide synthetic request JSON, output JSON, and generator SHA-256.") }
            let input = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
            let generatorSHA256 = CommandLine.arguments[3]
            guard isSHA256(generatorSHA256) else { throw EvaluationError.invalid("Generator source hash must be lowercase SHA-256.") }
            let inputData = try Data(contentsOf: input)
            let requestEnvelope = try JSONDecoder().decode(RequestEnvelope.self, from: inputData)
            try validate(requestEnvelope)

            let started = Date(), startedAt = iso8601(Date()), host = environment(), requestsSHA256 = sha256(inputData)
            let isVersionTwo = requestEnvelope.schemaVersion == 2
            let modelExpected = requestEnvelope.requests.filter { $0.preparedDraft == nil }.count
            let preparedExpected = requestEnvelope.requests.count - modelExpected
            guard #available(macOS 26.0, *) else { throw EvaluationError.invalid("On-device generation requires macOS 26 or later.") }
            let maximumResponseTokens = OnDeviceScribeGeneration.maximumResponseTokens
            let generationTimeoutMilliseconds = OnDeviceScribeGeneration.generationTimeoutMilliseconds
            let modelIsAvailable: Bool
            if case .available = SystemLanguageModel.default.availability { modelIsAvailable = true }
            else { modelIsAvailable = false }
            var results: [EvaluationResult] = [], modelElapsed = 0, preparedElapsed = 0

            func manifest(state: String) -> RunManifest {
                let modelCompleted = results.filter { $0.executionKind == .modelGeneration || (!isVersionTwo && $0.executionKind == nil) }.count
                let preparedCompleted = results.filter { $0.executionKind == .preparedDraft }.count
                return RunManifest(requestsSHA256: requestsSHA256, generatorSHA256: generatorSHA256, providerID: "legacyLocal", sampling: "greedy", state: state,
                    settingsRevision: 2, maximumResponseTokens: maximumResponseTokens, generationTimeoutMilliseconds: generationTimeoutMilliseconds,
                    expectedCaseCount: requestEnvelope.requests.count, completedCaseCount: results.count, elapsedMilliseconds: milliseconds(since: started),
                    expectedModelCaseCount: isVersionTwo ? modelExpected : nil, expectedPreparedDraftCaseCount: isVersionTwo ? preparedExpected : nil,
                    completedModelCaseCount: isVersionTwo ? modelCompleted : nil, completedPreparedDraftCaseCount: isVersionTwo ? preparedCompleted : nil,
                    modelElapsedMilliseconds: isVersionTwo ? modelElapsed : nil, preparedDraftElapsedMilliseconds: isVersionTwo ? preparedElapsed : nil,
                    startedAt: startedAt, finishedAt: iso8601(Date()), operatingSystem: host.operatingSystem, operatingSystemVersion: host.operatingSystemVersion, build: host.build)
            }

            for request in requestEnvelope.requests {
                let kind: ExecutionKind = request.preparedDraft == nil ? .modelGeneration : .preparedDraft
                let requestStarted = Date()
                let status: String; let draft: String?; let failureCategory: EvaluationFailureCategory?
                if kind == .modelGeneration && !modelIsAvailable {
                    status = "UNAVAILABLE"; draft = nil; failureCategory = nil
                }
                else {
                    do {
                        draft = try await OnDeviceScribeGeneration.generate(systemMessage: request.system, userMessage: request.user, preparedDraft: request.preparedDraft)
                        status = "GENERATED"; failureCategory = nil
                    } catch let error as OnDeviceScribeGenerationError {
                        status = "FAILED"; draft = nil
                        failureCategory = error == .timedOut ? .timedOut : .busy
                    } catch is CancellationError {
                        status = "FAILED"; draft = nil; failureCategory = .cancelled
                    } catch {
                        status = "FAILED"; draft = nil; failureCategory = .modelError
                    }
                }
                let elapsed = milliseconds(since: requestStarted)
                if kind == .modelGeneration { modelElapsed += elapsed } else { preparedElapsed += elapsed }
                results.append(.init(id: request.id, status: status, draft: draft, elapsedMilliseconds: elapsed, repeatIndex: nil,
                                     executionKind: isVersionTwo ? kind : nil, failureCategory: failureCategory))
                let state = results.contains { $0.status == "UNAVAILABLE" } ? "unavailable" : "running"
                try write(ResultEnvelope(schemaVersion: requestEnvelope.schemaVersion, corpusSHA256: requestEnvelope.corpusSHA256, results: results, runManifest: manifest(state: state)), to: output)
                print("\(request.id): \(status) [\(kind.rawValue)]")
            }
            let finalState = results.contains { $0.status == "UNAVAILABLE" } ? "unavailable" : "complete"
            try write(ResultEnvelope(schemaVersion: requestEnvelope.schemaVersion, corpusSHA256: requestEnvelope.corpusSHA256, results: results, runManifest: manifest(state: finalState)), to: output)
            if finalState == "unavailable" { print("Local model unavailable; affected model-generation rows did not run.") }
        } catch {
            fputs("Evaluation input error: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }
}
