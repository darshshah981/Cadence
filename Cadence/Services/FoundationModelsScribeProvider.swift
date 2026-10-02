#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
actor FoundationModelsScribeProvider: ScribeProvider {
    nonisolated var capabilities: ScribeProviderCapabilities {
        switch SystemLanguageModel.default.availability {
        case .available:
            return [.semanticGeneration, .cancellation]
        case .unavailable:
            return []
        }
    }

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        guard capabilities.contains(.semanticGeneration) else {
            throw ScribeProviderError.unavailable
        }

        do {
            let draft = try await OnDeviceScribeGeneration.generate(
                systemMessage: request.input.systemMessage,
                userMessage: request.input.userMessage,
                preparedDraft: request.input.preparedDraft
            )
            return ScribeResult(
                requestID: request.id,
                text: try ScribeOutputPolicy.normalizedOutput(draft),
                binding: request.resultBinding
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OnDeviceScribeGenerationError {
            throw Self.recoveryError(for: error)
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.recoveryError(for: error)
        } catch let error as ScribeProviderError {
            throw error
        } catch {
            throw ScribeProviderError.unavailable
        }
    }

    nonisolated static func recoveryError(for error: OnDeviceScribeGenerationError) -> ScribeProviderError {
        switch error {
        case .timedOut: return .timedOut
        case .busy: return .busy
        }
    }

    /// Classify the typed platform error without inspecting or retaining its
    /// description, which can contain the user's prompt or generated text.
    nonisolated static func recoveryError(
        for error: LanguageModelSession.GenerationError
    ) -> ScribeProviderError {
        switch error {
        case .exceededContextWindowSize:
            return .inputTooLarge
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        case .guardrailViolation, .refusal:
            return .requestDeclined
        case .rateLimited, .concurrentRequests:
            return .busy
        case .decodingFailure:
            return .invalidResult
        case .assetsUnavailable, .unsupportedGuide:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

}
#endif
