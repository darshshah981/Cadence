import Foundation

enum ScribeProviderError: String, Error, Equatable, Sendable {
    case unavailable
    case offline
    case timedOut
    case cancelled
    case emptyResult
    case invalidResult
    case resultTooLarge

    var userMessage: String {
        switch self {
        case .unavailable:
            return "Scribe is not configured. You can insert the literal transcript instead."
        case .offline:
            return "Scribe is offline. Try again or insert the literal transcript."
        case .timedOut:
            return "Scribe took too long. Try again or insert the literal transcript."
        case .cancelled:
            return "Scribe was cancelled."
        case .emptyResult:
            return "Scribe did not return any text. Try again or insert the literal transcript."
        case .invalidResult:
            return "Scribe returned text Cadence could not safely insert. Try again or insert the literal transcript."
        case .resultTooLarge:
            return "Scribe returned too much text to review safely. Try a smaller request."
        }
    }
}

protocol ScribeProvider: Sendable {
    var capabilities: ScribeProviderCapabilities { get }
    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult
}

struct ScribeProviderActionSnapshot: Sendable {
    let provider: any ScribeProvider
    let destination: ScribeEgressDestination

    func validateForAcquisition(intent: ScribeIntent) throws {
        guard destination.disclosureVersion == ScribeProviderDisclosure.currentVersion,
              !destination.recipientOrigin.isEmpty,
              provider.capabilities.contains(.semanticGeneration),
              !intent.requiresSelectedText || provider.capabilities.contains(.selectedTextContext) else {
            throw ScribeProviderFailure(
                phase: .generation,
                category: .configurationInvalid,
                retryDisposition: .reconnect
            )
        }
    }

    func contextAuthorization(for capture: ScribeContextSnapshot) -> ScribeContextAuthorization {
        ScribeContextAuthorization(
            scope: capture.scope,
            providerKind: destination.providerKind,
            recipientOrigin: destination.recipientOrigin,
            disclosureVersion: destination.disclosureVersion,
            captureID: capture.id,
            target: capture.target,
            verificationToken: capture.verificationToken
        )
    }

    var selectedTextDisclosure: String {
        switch destination.providerKind {
        case .openAIDirect:
            return ScribeProviderDisclosure.selectedTextRecipient("OpenAI")
        case .openRouter:
            return ScribeProviderDisclosure.selectedTextRecipient("OpenRouter")
        case .deepSeek:
            return ScribeProviderDisclosure.selectedTextRecipient("DeepSeek")
        case .advanced:
            let recipient = URL(string: destination.recipientOrigin)?.host
                ?? destination.recipientOrigin
            return ScribeProviderDisclosure.selectedTextRecipient(recipient)
        case .legacyLocal:
            return "Selected text stays on this Mac and is used only after you choose Respond or Edit."
        }
    }
}
