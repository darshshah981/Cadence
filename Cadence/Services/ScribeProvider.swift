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
    func generate(_ request: ScribeRequest) async throws -> ScribeResult
}
