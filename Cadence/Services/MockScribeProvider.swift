import Foundation

actor MockScribeProvider: ScribeProvider {
    enum Response: Sendable {
        case success(String)
        case delayedSuccess(String, Duration)
        case failure(ScribeProviderError)
    }

    nonisolated let capabilities: ScribeProviderCapabilities
    private var responses: [Response]
    private var completedRequests: [UUID: ScribeResult] = [:]
    private var completedRequestOrder: [UUID] = []
    private(set) var generationCount = 0

    init(
        capabilities: ScribeProviderCapabilities = .mock,
        responses: [Response] = [.success("Cadence mock Scribe result.")]
    ) {
        self.capabilities = capabilities
        self.responses = responses
    }

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
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
            let normalized = try ScribeOutputPolicy.normalizedOutput(text)
            let result = ScribeResult(requestID: request.id, text: normalized, binding: request.resultBinding)
            cache(result)
            return result
        case let .delayedSuccess(text, delay):
            try await Task.sleep(for: delay)
            let normalized = try ScribeOutputPolicy.normalizedOutput(text)
            let result = ScribeResult(requestID: request.id, text: normalized, binding: request.resultBinding)
            cache(result)
            return result
        }
    }

    private func cache(_ result: ScribeResult) {
        completedRequests[result.requestID] = result
        completedRequestOrder.append(result.requestID)
        while completedRequestOrder.count > 16 {
            completedRequests.removeValue(forKey: completedRequestOrder.removeFirst())
        }
    }
}
