import Foundation

struct UnavailableScribeProvider: ScribeProvider {
    let capabilities: ScribeProviderCapabilities = []

    func generate(_ request: ScribeRequest) async throws -> ScribeResult {
        throw ScribeProviderError.unavailable
    }
}
