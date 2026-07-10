import Foundation

actor MockScribeProvider: ScribeProvider {
    enum Response: Sendable {
        case success(String)
        case failure(ScribeProviderError)
    }

    nonisolated let capabilities: ScribeProviderCapabilities
    private var responses: [Response]
    private var completedRequests: [UUID: ScribeResult] = [:]
    private(set) var generationCount = 0

    init(
        capabilities: ScribeProviderCapabilities = .mock,
        responses: [Response] = [.success("Cadence mock Scribe result.")]
    ) {
        self.capabilities = capabilities
        self.responses = responses
    }

    func generate(_ request: ScribeRequest) async throws -> ScribeResult {
        try Task.checkCancellation()

        if let existing = completedRequests[request.id] {
            return existing
        }

        guard capabilities.contains(.semanticGeneration) else {
            throw ScribeProviderError.unavailable
        }

        generationCount += 1
        let response = responses.isEmpty
            ? Response.success("Cadence mock Scribe result.")
            : responses.removeFirst()

        switch response {
        case let .failure(error):
            throw error
        case let .success(text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw ScribeProviderError.emptyResult
            }
            let result = ScribeResult(requestID: request.id, text: normalized)
            completedRequests[request.id] = result
            return result
        }
    }
}
