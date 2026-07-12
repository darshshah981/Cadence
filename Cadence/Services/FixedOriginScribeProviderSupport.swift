import Foundation

enum FixedOriginScribeProviderSupport {
    typealias ErrorMapper = @Sendable (
        HTTPURLResponse,
        Data,
        ScribeProviderPhase
    ) -> ScribeProviderFailure?

    struct ProviderErrorSignal: Equatable, Sendable {
        let code: String?
        let type: String?
        let metadataErrorType: String?
    }

    private struct ProviderErrorEnvelope: Decodable {
        let error: ProviderErrorBody
    }

    private struct ProviderErrorBody: Decodable {
        let code: String?
        let type: String?
        let metadata: ProviderErrorMetadata?

        enum CodingKeys: String, CodingKey { case code, type, metadata }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let string = try? container.decode(String.self, forKey: .code) {
                code = string
            } else if let integer = try? container.decode(Int.self, forKey: .code) {
                code = String(integer)
            } else {
                code = nil
            }
            type = try? container.decode(String.self, forKey: .type)
            metadata = try? container.decode(ProviderErrorMetadata.self, forKey: .metadata)
        }
    }

    private struct ProviderErrorMetadata: Decodable {
        let errorType: String?
        enum CodingKeys: String, CodingKey { case errorType = "error_type" }
    }

    static func credential(
        _ loader: @Sendable () throws -> String,
        phase: ScribeProviderPhase
    ) throws -> String {
        let value: String
        do { value = try loader() } catch {
            throw failure(phase, .configurationInvalid, .reconnect)
        }
        guard !value.isEmpty else { throw failure(phase, .credentialRejected, .reconnect) }
        return value
    }

    static func send(
        _ request: URLRequest,
        phase: ScribeProviderPhase,
        transport: any ScribeHTTPTransporting,
        errorMapper: ErrorMapper? = nil
    ) async throws -> Data {
        let result: ScribeHTTPResponse
        do {
            result = try await transport.send(
                request,
                deadline: phase == .validation ? .seconds(15) : .seconds(30)
            )
        } catch let error as ScribeHTTPTransportError {
            throw mapTransport(error, phase: phase)
        } catch is CancellationError {
            throw failure(phase, .cancelled, .none)
        } catch {
            throw failure(phase, .transportUnavailable, .manualNow)
        }
        guard result.response.statusCode == 200 else {
            let isJSON = result.response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().hasPrefix("application/json") == true
            if isJSON, let mapped = errorMapper?(result.response, result.data, phase) {
                throw mapped
            }
            throw mapStatus(result.response, phase: phase)
        }
        guard result.data.count <= ScribeHTTPTransport.maximumResponseBytes,
              result.response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().hasPrefix("application/json") == true else {
            throw failure(phase, .invalidResponse, .manualNow)
        }
        return result.data
    }

    static func normalize(_ text: String, phase: ScribeProviderPhase) throws -> String {
        do { return try ScribeOutputPolicy.normalizedOutput(text) }
        catch { throw failure(phase, .invalidResponse, .manualNow) }
    }

    static func boundedErrorSignal(from data: Data) -> ProviderErrorSignal? {
        guard data.count <= 16 * 1_024,
              let body = try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: data) else {
            return nil
        }
        let code = boundedSignalField(body.error.code)
        let type = boundedSignalField(body.error.type)
        let metadataErrorType = boundedSignalField(body.error.metadata?.errorType)
        guard code != nil || type != nil || metadataErrorType != nil else { return nil }
        return ProviderErrorSignal(
            code: code,
            type: type,
            metadataErrorType: metadataErrorType
        )
    }

    static func boundedSignalField(_ field: String?) -> String? {
        guard let field, !field.isEmpty, field.utf8.count <= 128,
              field.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "_" || scalar == "-" || scalar == "."
              }) else { return nil }
        return field.lowercased()
    }

    static func failure(
        _ phase: ScribeProviderPhase,
        _ category: ScribeProviderFailureCategory,
        _ retry: ScribeProviderRetryDisposition,
        retryAfter: Int? = nil
    ) -> ScribeProviderFailure {
        ScribeProviderFailure(
            phase: phase, category: category, retryDisposition: retry,
            retryAfterSeconds: retryAfter
        )
    }

    private static func mapTransport(
        _ error: ScribeHTTPTransportError,
        phase: ScribeProviderPhase
    ) -> ScribeProviderFailure {
        switch error {
        case .cancelled, .url(.cancelled): return failure(phase, .cancelled, .none)
        case .timedOut, .url(.timedOut): return failure(phase, .timedOut, .manualNow)
        case .redirected: return failure(phase, .unsafeConnection, .updateCadence)
        case .bodyTooLarge, .invalidResponse: return failure(phase, .invalidResponse, .manualNow)
        case let .url(code):
            if tlsErrors.contains(code) { return failure(phase, .unsafeConnection, .updateCadence) }
            return failure(phase, .transportUnavailable, .manualNow)
        }
    }

    private static func mapStatus(
        _ response: HTTPURLResponse,
        phase: ScribeProviderPhase
    ) -> ScribeProviderFailure {
        switch response.statusCode {
        case 401, 403: return failure(phase, .credentialRejected, .reconnect)
        case 402: return failure(phase, .balanceRequired, .manualAfterWait)
        case 408, 429:
            let raw = response.value(forHTTPHeaderField: "Retry-After")
            let seconds = raw.flatMap(Int.init).map { min(max($0, 0), 86_400) }
            return failure(phase, .rateLimited, .manualAfterWait, retryAfter: seconds)
        case 500...599: return failure(phase, .providerUnavailable, .manualNow)
        case 400, 404, 405, 413, 415, 422:
            return failure(phase, .incompatibleRequest, .updateCadence)
        default: return failure(phase, .providerRejected, .none)
        }
    }

    private static let tlsErrors: Set<URLError.Code> = [
        .secureConnectionFailed, .serverCertificateHasBadDate,
        .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid, .clientCertificateRejected,
        .clientCertificateRequired
    ]
}
