import Foundation

struct ScribeChatCompletionClient: Sendable {
    enum Profile: Sendable {
        case deepSeek(DeepSeekScribeCatalogEntry)
        case advanced
    }

    typealias CredentialLoader = @Sendable () throws -> String

    private struct Thinking: Encodable {
        let type: String
    }

    private struct DeepSeekBody: Encodable {
        let model: String
        let messages: [ScribeChatMessageWire]
        let thinking: Thinking
        let stream: Bool
        let maxTokens: Int
        let temperature: Double

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case thinking
            case stream
            case maxTokens = "max_tokens"
            case temperature
        }
    }

    private struct AdvancedBody: Encodable {
        let model: String
        let messages: [ScribeChatMessageWire]
        let stream: Bool
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case stream
            case maxTokens = "max_tokens"
        }
    }

    private struct CompletionResponse: Decodable {
        let model: String?
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let index: Int
        let message: ResponseMessage
        let finishReason: String

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    private struct ResponseMessage: Decodable {
        let content: String?
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
        }
    }

    let profile: Profile
    let endpoint: URL
    let modelID: String
    let credentialLoader: CredentialLoader
    let transport: any ScribeHTTPTransporting

    func generate(_ request: ScribeProviderRequest) async throws -> String {
        try await execute(
            systemMessage: request.input.systemMessage,
            userMessage: request.input.userMessage,
            phase: .generation,
            maxTokens: 1_024,
            temperature: 0.3
        )
    }

    func validateConnection() async throws {
        _ = try await execute(
            systemMessage: "Return only OK.",
            userMessage: "Cadence provider compatibility check.",
            phase: .validation,
            maxTokens: 8,
            temperature: 0
        )
    }

    private func execute(
        systemMessage: String,
        userMessage: String,
        phase: ScribeProviderPhase,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String {
        let credential: String
        do {
            credential = try credentialLoader()
        } catch {
            throw failure(
                phase: phase,
                category: .configurationInvalid,
                retry: .reconnect
            )
        }
        guard !credential.isEmpty else {
            throw failure(
                phase: phase,
                category: .credentialRejected,
                retry: .reconnect
            )
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let messages = [
            ScribeChatMessageWire(role: "system", content: systemMessage),
            ScribeChatMessageWire(role: "user", content: userMessage)
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch profile {
        case .deepSeek:
            request.httpBody = try encoder.encode(DeepSeekBody(
                model: modelID,
                messages: messages,
                thinking: Thinking(type: "disabled"),
                stream: false,
                maxTokens: maxTokens,
                temperature: temperature
            ))
        case .advanced:
            request.httpBody = try encoder.encode(AdvancedBody(
                model: modelID,
                messages: messages,
                stream: false,
                maxTokens: maxTokens
            ))
        }

        let response: ScribeHTTPResponse
        do {
            response = try await transport.send(
                request,
                deadline: phase == .validation ? .seconds(15) : .seconds(30)
            )
        } catch let error as ScribeHTTPTransportError {
            throw mapTransport(error, phase: phase)
        } catch is CancellationError {
            throw failure(phase: phase, category: .cancelled, retry: .none)
        } catch {
            throw failure(
                phase: phase,
                category: .transportUnavailable,
                retry: .manualNow
            )
        }

        guard response.response.statusCode == 200 else {
            throw mapStatus(response.response, phase: phase)
        }
        guard response.data.count <= ScribeHTTPTransport.maximumResponseBytes,
              response.response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().hasPrefix("application/json") == true else {
            throw failure(phase: phase, category: .invalidResponse, retry: .manualNow)
        }

        let decoded: CompletionResponse
        do {
            decoded = try JSONDecoder().decode(CompletionResponse.self, from: response.data)
        } catch {
            throw failure(phase: phase, category: .invalidResponse, retry: .manualNow)
        }
        guard decoded.choices.count == 1,
              let choice = decoded.choices.first,
              choice.index == 0 else {
            throw failure(phase: phase, category: .invalidResponse, retry: .manualNow)
        }

        guard choice.finishReason == "stop" else {
            if choice.finishReason == "content_filter" {
                throw failure(phase: phase, category: .providerRejected, retry: .none)
            }
            if choice.finishReason == "insufficient_system_resource" {
                throw failure(phase: phase, category: .providerUnavailable, retry: .manualNow)
            }
            throw failure(phase: phase, category: .invalidResponse, retry: .manualNow)
        }
        guard let content = choice.message.content else {
            throw failure(phase: phase, category: .invalidResponse, retry: .manualNow)
        }

        if case let .deepSeek(entry) = profile {
            guard let responseModel = decoded.model,
                  entry.acceptedResponseModelIDs.contains(responseModel),
                  choice.message.reasoningContent?.isEmpty != false else {
                throw failure(phase: phase, category: .invalidResponse, retry: .manualNow)
            }
        }
        do {
            return try ScribeOutputPolicy.normalizedOutput(content)
        } catch {
            throw failure(phase: phase, category: .invalidResponse, retry: .manualNow)
        }
    }

    private func mapTransport(
        _ error: ScribeHTTPTransportError,
        phase: ScribeProviderPhase
    ) -> ScribeProviderFailure {
        switch error {
        case .cancelled:
            return failure(phase: phase, category: .cancelled, retry: .none)
        case .timedOut:
            return failure(phase: phase, category: .timedOut, retry: .manualNow)
        case .redirected:
            return failure(
                phase: phase,
                category: .unsafeConnection,
                retry: isDeepSeek ? .updateCadence : .changeConfiguration
            )
        case .bodyTooLarge, .invalidResponse:
            return failure(phase: phase, category: .invalidResponse, retry: .manualNow)
        case let .url(code):
            if code == .cancelled {
                return failure(phase: phase, category: .cancelled, retry: .none)
            }
            if code == .timedOut {
                return failure(phase: phase, category: .timedOut, retry: .manualNow)
            }
            if Self.tlsErrors.contains(code) {
                return failure(
                    phase: phase,
                    category: .unsafeConnection,
                    retry: isDeepSeek ? .updateCadence : .changeConfiguration
                )
            }
            return failure(
                phase: phase,
                category: .transportUnavailable,
                retry: .manualNow
            )
        }
    }

    private func mapStatus(
        _ response: HTTPURLResponse,
        phase: ScribeProviderPhase
    ) -> ScribeProviderFailure {
        let status = response.statusCode
        let retryAfter = Self.retryAfterSeconds(from: response)

        if status == 401 || status == 403 {
            return failure(phase: phase, category: .credentialRejected, retry: .reconnect)
        }
        if status == 408 || status == 429 {
            return failure(
                phase: phase,
                category: .rateLimited,
                retry: .manualAfterWait,
                retryAfterSeconds: retryAfter
            )
        }
        if (500...599).contains(status) {
            return failure(phase: phase, category: .providerUnavailable, retry: .manualNow)
        }

        switch profile {
        case .deepSeek:
            switch status {
            case 400, 422:
                return failure(phase: phase, category: .incompatibleRequest, retry: .updateCadence)
            case 402:
                return failure(phase: phase, category: .balanceRequired, retry: .manualAfterWait)
            default:
                return failure(phase: phase, category: .providerRejected, retry: .none)
            }
        case .advanced:
            switch status {
            case 400, 405, 413, 415, 422:
                return failure(phase: phase, category: .incompatibleRequest, retry: .changeConfiguration)
            case 404:
                return failure(phase: phase, category: .endpointNotFound, retry: .changeConfiguration)
            default:
                return failure(phase: phase, category: .providerRejected, retry: .none)
            }
        }
    }

    private var isDeepSeek: Bool {
        if case .deepSeek = profile { return true }
        return false
    }

    private func failure(
        phase: ScribeProviderPhase,
        category: ScribeProviderFailureCategory,
        retry: ScribeProviderRetryDisposition,
        retryAfterSeconds: Int? = nil
    ) -> ScribeProviderFailure {
        ScribeProviderFailure(
            phase: phase,
            category: category,
            retryDisposition: retry,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    private static let tlsErrors: Set<URLError.Code> = [
        .secureConnectionFailed,
        .serverCertificateHasBadDate,
        .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .clientCertificateRejected,
        .clientCertificateRequired
    ]

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if let seconds = Int(raw), seconds >= 0 {
            return min(seconds, 86_400)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, min(Int(date.timeIntervalSinceNow.rounded(.up)), 86_400))
    }
}
