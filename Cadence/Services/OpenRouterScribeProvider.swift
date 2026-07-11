import Foundation

struct OpenRouterScribeProvider: ScribeProvider {
    typealias CredentialLoader = @Sendable () throws -> String

    let capabilities: ScribeProviderCapabilities = [
        .semanticGeneration, .selectedTextContext, .cancellation
    ]

    private struct Message: Encodable { let content: String; let role: String }
    private struct Routing: Encodable {
        let dataCollection = "deny"
        let zdr = true
        enum CodingKeys: String, CodingKey { case dataCollection = "data_collection"; case zdr }
    }
    private struct Body: Encodable {
        let maxCompletionTokens: Int
        let messages: [Message]
        let model: String
        let provider = Routing()
        let stream = false
        enum CodingKeys: String, CodingKey {
            case maxCompletionTokens = "max_completion_tokens"
            case messages, model, provider, stream
        }
    }
    private struct Response: Decodable { let model: String; let choices: [Choice] }
    private struct Choice: Decodable {
        let index: Int
        let finishReason: String
        let message: ResponseMessage?
        let error: ChoiceError?
        enum CodingKeys: String, CodingKey {
            case index, message, error
            case finishReason = "finish_reason"
        }
    }
    private struct ChoiceError: Decodable {
        let metadata: ChoiceErrorMetadata?
    }
    private struct ChoiceErrorMetadata: Decodable {
        let errorType: String?
        enum CodingKeys: String, CodingKey { case errorType = "error_type" }
    }
    private struct ResponseMessage: Decodable {
        let role: String
        let content: String?
        let toolCalls: [JSONValue]?
        let functionCall: JSONValue?
        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case functionCall = "function_call"
        }
    }
    private enum JSONValue: Decodable {
        case value
        init(from decoder: Decoder) throws { self = .value }
    }

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let modelID: String
    private let credentialLoader: CredentialLoader
    private let transport: any ScribeHTTPTransporting

    init(
        model: ScribeModelIdentifier,
        credentialLoader: @escaping CredentialLoader,
        transport: any ScribeHTTPTransporting = ScribeHTTPTransport()
    ) {
        modelID = model.rawValue
        self.credentialLoader = credentialLoader
        self.transport = transport
    }

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        ScribeResult(requestID: request.id, text: try await execute(
            input: request.input, phase: .generation, maxTokens: 1_024
        ))
    }

    func validateConnection() async throws {
        _ = try await execute(
            input: ProviderSafeScribeInput(
                systemMessage: "Return only OK.",
                userMessage: "Cadence provider compatibility check."
            ), phase: .validation, maxTokens: 8
        )
    }

    private func execute(
        input: ProviderSafeScribeInput,
        phase: ScribeProviderPhase,
        maxTokens: Int
    ) async throws -> String {
        let credential = try FixedOriginScribeProviderSupport.credential(credentialLoader, phase: phase)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(Body(
            maxCompletionTokens: maxTokens,
            messages: [
                Message(content: input.systemMessage, role: "system"),
                Message(content: input.userMessage, role: "user")
            ],
            model: modelID
        ))
        let data = try await FixedOriginScribeProviderSupport.send(
            request,
            phase: phase,
            transport: transport,
            errorMapper: { response, data, phase in
                Self.mapProviderError(response, data, phase)
            }
        )
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw FixedOriginScribeProviderSupport.failure(phase, .invalidResponse, .manualNow) }
        guard response.model == modelID, response.choices.count == 1,
              let choice = response.choices.first, choice.index == 0 else {
            throw FixedOriginScribeProviderSupport.failure(phase, .invalidResponse, .manualNow)
        }
        if choice.finishReason == "error" {
            if let errorType = FixedOriginScribeProviderSupport
                .boundedSignalField(choice.error?.metadata?.errorType),
               let mapped = Self.mapOfficialErrorType(errorType, phase: phase) {
                throw mapped
            }
            throw FixedOriginScribeProviderSupport.failure(phase, .providerUnavailable, .manualNow)
        }
        guard let message = choice.message,
              message.role == "assistant",
              message.toolCalls == nil, message.functionCall == nil,
              let text = message.content else {
            throw FixedOriginScribeProviderSupport.failure(phase, .invalidResponse, .manualNow)
        }
        guard choice.finishReason == "stop" else {
            if choice.finishReason == "content_filter" {
                throw FixedOriginScribeProviderSupport.failure(phase, .providerRejected, .none)
            }
            throw FixedOriginScribeProviderSupport.failure(phase, .invalidResponse, .manualNow)
        }
        return try FixedOriginScribeProviderSupport.normalize(text, phase: phase)
    }

    private static func mapProviderError(
        _ response: HTTPURLResponse,
        _ data: Data,
        _ phase: ScribeProviderPhase
    ) -> ScribeProviderFailure? {
        if let errorType = FixedOriginScribeProviderSupport
            .boundedErrorSignal(from: data)?.metadataErrorType,
           let mapped = mapOfficialErrorType(errorType, phase: phase) {
            return mapped
        }
        if response.statusCode == 403 {
            return FixedOriginScribeProviderSupport.failure(phase, .providerRejected, .none)
        }
        return nil
    }

    private static func mapOfficialErrorType(
        _ errorType: String,
        phase: ScribeProviderPhase
    ) -> ScribeProviderFailure? {
        switch errorType {
        case "authentication":
            return FixedOriginScribeProviderSupport.failure(phase, .credentialRejected, .reconnect)
        case "permission_denied", "content_policy_violation", "refusal":
            return FixedOriginScribeProviderSupport.failure(phase, .providerRejected, .none)
        case "payment_required":
            return FixedOriginScribeProviderSupport.failure(phase, .balanceRequired, .manualAfterWait)
        case "rate_limit_exceeded":
            return FixedOriginScribeProviderSupport.failure(phase, .rateLimited, .manualAfterWait)
        case "provider_overloaded", "provider_unavailable", "provider_error", "server_error":
            return FixedOriginScribeProviderSupport.failure(phase, .providerUnavailable, .manualNow)
        case "not_found":
            return FixedOriginScribeProviderSupport.failure(phase, .endpointNotFound, .changeConfiguration)
        case "timeout":
            return FixedOriginScribeProviderSupport.failure(phase, .timedOut, .manualNow)
        case "invalid_request", "invalid_prompt":
            return FixedOriginScribeProviderSupport.failure(phase, .incompatibleRequest, .updateCadence)
        default:
            return nil
        }
    }
}
