import Foundation

struct OpenAICompatibleScribeProvider: ScribeProvider {
    let capabilities: ScribeProviderCapabilities = [
        .semanticGeneration,
        .cancellation
    ]

    private let client: ScribeChatCompletionClient

    init(
        endpoint: AdvancedScribeEndpoint,
        model: ScribeModelIdentifier,
        credentialLoader: @escaping ScribeChatCompletionClient.CredentialLoader,
        transport: any ScribeHTTPTransporting = ScribeHTTPTransport()
    ) {
        client = ScribeChatCompletionClient(
            profile: .advanced,
            endpoint: endpoint.requestURL,
            modelID: model.rawValue,
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
