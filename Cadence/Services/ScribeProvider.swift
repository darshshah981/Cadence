import Foundation

enum ScribeProviderError: String, Error, Equatable, Sendable {
    case unavailable
    case offline
    case timedOut
    case cancelled
    case emptyResult
    case invalidResult
    case resultTooLarge
    case inputTooLarge
    case unsupportedLanguage
    case requestDeclined
    case busy

    var permitsUnchangedRetry: Bool {
        switch self {
        case .inputTooLarge, .unsupportedLanguage, .requestDeclined:
            return false
        default:
            return true
        }
    }

    var userMessage: String {
        switch self {
        case .unavailable:
            return "Compose is unavailable right now. You can insert the literal transcript instead."
        case .offline:
            return "Compose is offline. Try again or insert the literal transcript."
        case .timedOut:
            return "Compose took too long. Try again or insert the literal transcript."
        case .cancelled:
            return "Compose was cancelled."
        case .emptyResult:
            return "Compose did not return any text. Try again or insert the literal transcript."
        case .invalidResult:
            return "Compose returned text Cadence could not safely insert. Try again or insert the literal transcript."
        case .resultTooLarge:
            return "Compose returned too much text to review safely. Try a smaller request."
        case .inputTooLarge:
            return "This request is too long for the selected model. Record a shorter request or use the literal transcript."
        case .unsupportedLanguage:
            return "The selected model does not support this language. You can use the literal transcript or choose another provider in settings."
        case .requestDeclined:
            return "The selected model could not draft this request. Your original words are still available."
        case .busy:
            return "The selected model is busy. Wait a moment and try again. Your original words are still available."
        }
    }

    /// Contextual voice is an edit instruction. Recovery must never recommend
    /// inserting it as though it were the selected source or a finished draft.
    var selectedTextRewriteMessage: String {
        switch self {
        case .unavailable:
            return "Compose is unavailable right now. Try again later or cancel."
        case .offline:
            return "Compose is offline. Try again or cancel."
        case .timedOut:
            return "Compose took too long to rewrite the selection. Try again or cancel."
        case .cancelled:
            return "Compose was cancelled."
        case .emptyResult:
            return "Compose did not return a rewrite. Try again or cancel."
        case .invalidResult:
            return "Compose could not safely rewrite the selection. Try again or cancel."
        case .resultTooLarge:
            return "The rewrite is too long to review safely. Select less text and start again."
        case .inputTooLarge:
            return "This selection is too long for the selected model. Select less text and start again."
        case .unsupportedLanguage:
            return "The selected model does not support this language. Cancel this rewrite."
        case .requestDeclined:
            return "The selected model could not rewrite this selection. Cancel and try a different request."
        case .busy:
            return "The selected model is busy. Wait a moment and try again."
        }
    }
}

protocol ScribeProvider: Sendable {
    var capabilities: ScribeProviderCapabilities { get }
    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult
}

struct ScribeProviderActionIdentity: Equatable, Sendable {
    let configurationID: UUID
    let libraryRevision: Int
    let consentReceiptID: UUID?
    let selectedModelID: String
    let credentialReference: ScribeStoredCredentialReference?

    init(
        configurationID: UUID,
        libraryRevision: Int,
        consentReceiptID: UUID? = nil,
        selectedModelID: String,
        credentialReference: ScribeStoredCredentialReference? = nil
    ) {
        self.configurationID = configurationID
        self.libraryRevision = libraryRevision
        self.consentReceiptID = consentReceiptID
        self.selectedModelID = selectedModelID
        self.credentialReference = credentialReference
    }
}

enum ScribeProviderMutationDecision: Equatable, Sendable {
    case allowed
    case confirmationRequired
}

enum ScribeProviderMutationPolicy {
    static func decision(
        activeAction: ScribeProviderActionIdentity?,
        mutatingConfigurationID: UUID
    ) -> ScribeProviderMutationDecision {
        activeAction?.configurationID == mutatingConfigurationID
            ? .confirmationRequired
            : .allowed
    }

    static func activationDecision(
        activeAction: ScribeProviderActionIdentity?
    ) -> ScribeProviderMutationDecision {
        activeAction == nil ? .allowed : .confirmationRequired
    }
}

struct ScribeProviderActionSnapshot: Sendable {
    let provider: any ScribeProvider
    let destination: ScribeEgressDestination
    let configurationID: UUID?
    let libraryRevision: Int?
    let consentReceiptID: UUID?
    let selectedModelID: String?
    let credentialReference: ScribeStoredCredentialReference?
    let capabilityProfile: ScribeProviderCapabilityProfile

    var actionIdentity: ScribeProviderActionIdentity? {
        guard let configurationID, let libraryRevision, let selectedModelID
        else { return nil }
        return ScribeProviderActionIdentity(
            configurationID: configurationID,
            libraryRevision: libraryRevision,
            consentReceiptID: consentReceiptID,
            selectedModelID: selectedModelID,
            credentialReference: credentialReference
        )
    }

    init(
        provider: any ScribeProvider,
        destination: ScribeEgressDestination,
        configurationID: UUID? = nil,
        libraryRevision: Int? = nil,
        consentReceiptID: UUID? = nil,
        selectedModelID: String? = nil,
        credentialReference: ScribeStoredCredentialReference? = nil,
        capabilityProfile: ScribeProviderCapabilityProfile? = nil
    ) {
        self.provider = provider
        self.destination = destination
        self.configurationID = configurationID
        self.libraryRevision = libraryRevision
        self.consentReceiptID = consentReceiptID
        self.selectedModelID = selectedModelID
        self.credentialReference = credentialReference
        self.capabilityProfile = capabilityProfile ?? .defaultProfile(for: destination)
    }

    func validateForAcquisition() throws {
        guard destination.disclosureVersion == ScribeProviderDisclosure.currentVersion,
              !destination.recipientOrigin.isEmpty,
              provider.capabilities.contains(.semanticGeneration) else {
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

}
