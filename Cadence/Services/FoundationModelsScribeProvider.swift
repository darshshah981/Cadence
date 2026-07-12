#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
actor FoundationModelsScribeProvider: ScribeProvider {
    nonisolated let capabilities: ScribeProviderCapabilities

    init() {
        switch SystemLanguageModel.default.availability {
        case .available:
            capabilities = [.semanticGeneration, .cancellation]
        case .unavailable:
            capabilities = []
        }
    }

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        guard capabilities.contains(.semanticGeneration) else {
            throw ScribeProviderError.unavailable
        }

        do {
            let session = LanguageModelSession(instructions: request.input.systemMessage)
            let response = try await session.respond(to: request.input.userMessage)
            return ScribeResult(
                requestID: request.id,
                text: try ScribeOutputPolicy.normalizedOutput(response.content),
                binding: request.resultBinding
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScribeProviderError {
            throw error
        } catch {
            throw ScribeProviderError.unavailable
        }
    }

}
#endif
