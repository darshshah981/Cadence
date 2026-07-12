import Foundation

struct DeepSeekScribeProvider: ScribeProvider {
    let capabilities: ScribeProviderCapabilities = [
        .semanticGeneration,
        .cancellation
    ]

    private let client: ScribeChatCompletionClient

    init(
        credentialLoader: @escaping ScribeChatCompletionClient.CredentialLoader,
        transport: any ScribeHTTPTransporting = ScribeHTTPTransport()
    ) {
        let entry = ScribeProviderCatalog.releaseOne.deepSeekEntries[0]
        client = ScribeChatCompletionClient(
            profile: .deepSeek(entry),
            endpoint: entry.endpoint,
            modelID: entry.modelID,
            credentialLoader: credentialLoader,
            transport: transport
        )
    }

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        ScribeResult(requestID: request.id, text: try await client.generate(request), binding: request.resultBinding)
    }

    func validateConnection() async throws {
        try await client.validateConnection()
    }
}
