import Foundation
import Testing
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Cadence

struct FoundationModelsScribeRecoveryTests {
    @Test
    func unchangedRetriesAreLimitedToRecoverableRequests() {
        for error in [ScribeProviderError.inputTooLarge, .unsupportedLanguage, .requestDeclined] {
            #expect(!error.permitsUnchangedRetry)
        }
        for error in [ScribeProviderError.busy, .timedOut, .unavailable, .offline] {
            #expect(error.permitsUnchangedRetry)
        }
        #expect(!ScribeProviderError.unavailable.userMessage.contains("not configured"))
    }

    @Test
    func localGenerationBusyAndDeadlineFailuresKeepTheirRecoveryMeaning() {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            #expect(FoundationModelsScribeProvider.recoveryError(for: OnDeviceScribeGenerationError.busy) == .busy)
            #expect(FoundationModelsScribeProvider.recoveryError(for: OnDeviceScribeGenerationError.timedOut) == .timedOut)
        }
#endif
    }

    @Test
    func typedPlatformFailuresNeverExposeUnderlyingPromptText() {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let context = LanguageModelSession.GenerationError.Context(
                debugDescription: "SCRIBE_PROMPT_CANARY_2CC1"
            )
            let cases: [(LanguageModelSession.GenerationError, ScribeProviderError)] = [
                (.exceededContextWindowSize(context), .inputTooLarge),
                (.unsupportedLanguageOrLocale(context), .unsupportedLanguage),
                (.guardrailViolation(context), .requestDeclined),
                (.rateLimited(context), .busy),
                (.concurrentRequests(context), .busy),
                (.decodingFailure(context), .invalidResult),
                (.assetsUnavailable(context), .unavailable),
                (.unsupportedGuide(context), .unavailable)
            ]
            for (platformError, expected) in cases {
                let result = FoundationModelsScribeProvider.recoveryError(for: platformError)
                #expect(result == expected)
                #expect(!result.userMessage.contains(context.debugDescription))
            }
        }
#endif
    }
}
