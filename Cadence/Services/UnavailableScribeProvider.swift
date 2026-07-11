import Foundation

struct UnavailableScribeProvider: ScribeProvider {
    let capabilities: ScribeProviderCapabilities = []

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        throw ScribeProviderError.unavailable
    }
}
