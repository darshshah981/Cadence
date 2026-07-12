import Foundation

struct OpenAIDirectScribeProvider: ScribeProvider {
    typealias CredentialLoader = @Sendable () throws -> String

    let capabilities: ScribeProviderCapabilities = [
        .semanticGeneration, .cancellation
    ]

    private struct Body: Encodable {
        let input: String
        let instructions: String
        let maxOutputTokens: Int
        let model: String
        let store: Bool
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case input, instructions, model, store, stream
            case maxOutputTokens = "max_output_tokens"
        }
    }

    private struct Response: Decodable {
        let status: String
        let output: [Output]
    }

    private struct Output: Decodable {
        let type: String
        let status: String?
        let role: String?
        let content: [Content]?
    }

    private struct Content: Decodable {
        let type: String
        let text: String?
    }

    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
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
        ScribeResult(
            requestID: request.id,
            text: try await execute(input: request.input, phase: .generation, maxTokens: 1_024),
            binding: request.resultBinding
        )
    }

    func validateConnection() async throws {
        _ = try await execute(
            input: .connectionValidation,
            phase: .validation,
            maxTokens: 8
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
            input: input.userMessage,
            instructions: input.systemMessage,
            maxOutputTokens: maxTokens,
            model: modelID,
            store: false,
            stream: false
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
        guard response.status == "completed", response.output.count == 1,
              let message = response.output.first,
              message.type == "message", message.status == "completed",
              message.role == "assistant", message.content?.count == 1,
              let content = message.content?.first,
              content.type == "output_text", let text = content.text else {
            throw FixedOriginScribeProviderSupport.failure(phase, .invalidResponse, .manualNow)
        }
        return try FixedOriginScribeProviderSupport.normalize(text, phase: phase)
    }

    private static func mapProviderError(
        _ response: HTTPURLResponse,
        _ data: Data,
        _ phase: ScribeProviderPhase
    ) -> ScribeProviderFailure? {
        if response.statusCode == 403 {
            return FixedOriginScribeProviderSupport.failure(phase, .providerRejected, .none)
        }
        guard let signal = FixedOriginScribeProviderSupport.boundedErrorSignal(from: data) else {
            return nil
        }
        let fields = [signal.code, signal.type].compactMap { $0 }
        if fields.contains(where: { $0.contains("quota") || $0.contains("credit") }) {
            return FixedOriginScribeProviderSupport.failure(phase, .balanceRequired, .manualAfterWait)
        }
        if fields.contains(where: { $0.contains("rate_limit") }) {
            return FixedOriginScribeProviderSupport.failure(phase, .rateLimited, .manualAfterWait)
        }
        if fields.contains(where: { $0.contains("model_not_found") || $0.contains("model_unavailable") }) {
            return FixedOriginScribeProviderSupport.failure(phase, .endpointNotFound, .changeConfiguration)
        }
        if fields.contains(where: {
            $0.contains("policy") || $0.contains("guardrail")
                || $0.contains("content_filter") || $0.contains("permission")
        }) {
            return FixedOriginScribeProviderSupport.failure(phase, .providerRejected, .none)
        }
        if fields.contains(where: { $0.contains("invalid_request") }) {
            return FixedOriginScribeProviderSupport.failure(phase, .incompatibleRequest, .updateCadence)
        }
        return nil
    }
}
