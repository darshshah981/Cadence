import Foundation
import Testing
@testable import Cadence

struct ScribeProviderTests {
    @Test
    func deepSeekProductionAndValidationWireProfilesAreExact() async throws {
        let transport = StubScribeHTTPTransport(responses: [
            .success(Self.deepSeekResponse(content: "Draft")),
            .success(Self.deepSeekResponse(content: "OK"))
        ])
        let provider = DeepSeekScribeProvider(
            credentialLoader: { "secret-key" },
            transport: transport
        )
        let request = ScribeRequest(
            intent: .compose,
            spokenTranscript: "Write an update",
            resolvedEnvironment: WritingEnvironmentResolver.resolve(
                recognizedEnvironmentID: .slack,
                adaptationEnabled: true,
                preferenceLoadResult: .absent
            )
        )

        #expect(try await provider.generate(try Self.providerRequest(
            request,
            destination: .deepSeek
        )).text == "Draft")
        try await provider.validateConnection()
        let sent = await transport.requests
        #expect(sent.count == 2)

        let production = try Self.json(sent[0].httpBody)
        #expect(production["model"] as? String == "deepseek-v4-flash")
        #expect(production["stream"] as? Bool == false)
        #expect(production["max_tokens"] as? Int == 1_024)
        #expect(production["temperature"] as? Double == 0.3)
        #expect((production["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect((production["messages"] as? [[String: String]])?.count == 2)
        #expect(production["tools"] == nil)
        #expect(sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")

        let validation = try Self.json(sent[1].httpBody)
        #expect(validation["max_tokens"] as? Int == 8)
        #expect(validation["temperature"] as? Double == 0)
        let validationMessages = try #require(validation["messages"] as? [[String: String]])
        #expect(validationMessages[0]["content"] == "Return only OK.")
        #expect(validationMessages[1]["content"] == "Cadence provider compatibility check.")
        #expect(await transport.deadlines == [.seconds(30), .seconds(15)])
    }

    @Test
    func advancedProfileOmitsDeepSeekOnlyFieldsAndUsesDerivedEndpoint() async throws {
        let endpoint = try AdvancedScribeEndpoint("https://provider.example/openai/v1")
        let transport = StubScribeHTTPTransport(responses: [
            .success(Self.advancedResponse(content: "Draft"))
        ])
        let provider = OpenAICompatibleScribeProvider(
            endpoint: endpoint,
            model: try ScribeModelIdentifier("custom-model"),
            credentialLoader: { "advanced-key" },
            transport: transport
        )

        let localRequest = ScribeRequest(
            intent: .compose,
            spokenTranscript: "Write an update"
        )
        _ = try await provider.generate(try Self.providerRequest(
            localRequest,
            destination: .advanced(
                origin: endpoint.normalizedOrigin,
                disclosureVersion: ScribeProviderDisclosure.currentVersion
            )
        ))
        let request = try #require(await transport.requests.first)
        let body = try Self.json(request.httpBody)

        #expect(request.url?.absoluteString == "https://provider.example/openai/v1/chat/completions")
        #expect(body["model"] as? String == "custom-model")
        #expect(body["max_tokens"] as? Int == 1_024)
        #expect(body["thinking"] == nil)
        #expect(body["temperature"] == nil)
        #expect(body.count == 4)
    }

    @Test(arguments: [
        (401, ScribeProviderFailureCategory.credentialRejected, ScribeProviderRetryDisposition.reconnect),
        (402, .balanceRequired, .manualAfterWait),
        (422, .incompatibleRequest, .updateCadence),
        (429, .rateLimited, .manualAfterWait),
        (500, .providerUnavailable, .manualNow),
        (503, .providerUnavailable, .manualNow)
    ])
    func deepSeekMapsStatusesWithoutReadingProviderBodies(
        status: Int,
        expectedCategory: ScribeProviderFailureCategory,
        expectedRetry: ScribeProviderRetryDisposition
    ) async {
        let transport = StubScribeHTTPTransport(responses: [
            .success(Self.response(status: status, body: Data("provider secret body".utf8)))
        ])
        let provider = DeepSeekScribeProvider(
            credentialLoader: { "key" },
            transport: transport
        )

        do {
            _ = try await provider.generate(try Self.providerRequest(
                ScribeRequest(intent: .compose, spokenTranscript: "Request"),
                destination: .deepSeek
            ))
            Issue.record("Expected provider failure")
        } catch let failure as ScribeProviderFailure {
            #expect(failure.category == expectedCategory)
            #expect(failure.retryDisposition == expectedRetry)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test(arguments: [
        (400, ScribeProviderFailureCategory.incompatibleRequest, ScribeProviderRetryDisposition.changeConfiguration),
        (404, .endpointNotFound, .changeConfiguration),
        (405, .incompatibleRequest, .changeConfiguration),
        (413, .incompatibleRequest, .changeConfiguration),
        (415, .incompatibleRequest, .changeConfiguration),
        (422, .incompatibleRequest, .changeConfiguration),
        (401, .credentialRejected, .reconnect),
        (408, .rateLimited, .manualAfterWait),
        (500, .providerUnavailable, .manualNow)
    ])
    func advancedMapsItsClosedStatusMatrix(
        status: Int,
        expectedCategory: ScribeProviderFailureCategory,
        expectedRetry: ScribeProviderRetryDisposition
    ) async {
        let transport = StubScribeHTTPTransport(responses: [
            .success(Self.response(status: status, body: Data("ignored".utf8)))
        ])
        let endpoint = try! AdvancedScribeEndpoint("https://provider.example/v1")
        let provider = OpenAICompatibleScribeProvider(
            endpoint: endpoint,
            model: try! ScribeModelIdentifier("model"),
            credentialLoader: { "key" },
            transport: transport
        )
        do {
            _ = try await provider.generate(try Self.providerRequest(
                ScribeRequest(intent: .compose, spokenTranscript: "Request"),
                destination: .advanced(
                    origin: endpoint.normalizedOrigin,
                    disclosureVersion: ScribeProviderDisclosure.currentVersion
                )
            ))
            Issue.record("Expected provider failure")
        } catch let failure as ScribeProviderFailure {
            #expect(failure.category == expectedCategory)
            #expect(failure.retryDisposition == expectedRetry)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func retryAfterSecondsIsBoundedAndPreserved() async {
        let transport = StubScribeHTTPTransport(responses: [
            .success(Self.response(
                status: 429,
                body: Data("ignored".utf8),
                headers: ["Content-Type": "application/json", "Retry-After": "90000"]
            ))
        ])
        let provider = DeepSeekScribeProvider(
            credentialLoader: { "key" },
            transport: transport
        )
        do {
            _ = try await provider.generate(try Self.providerRequest(
                ScribeRequest(intent: .compose, spokenTranscript: "Request"),
                destination: .deepSeek
            ))
            Issue.record("Expected rate limit")
        } catch let failure as ScribeProviderFailure {
            #expect(failure.category == .rateLimited)
            #expect(failure.retryAfterSeconds == 86_400)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func strictResponseParserRejectsPartialReasoningWrongModelAndMultipleChoices() async {
        let invalidBodies: [Data] = [
            Self.deepSeekResponse(content: "Draft", finishReason: "length").data,
            Self.deepSeekResponse(content: "Draft", reasoning: "hidden").data,
            Self.deepSeekResponse(content: "Draft", model: "unexpected-model").data,
            Self.response(status: 200, json: [
                "model": "deepseek-v4-flash",
                "choices": [
                    Self.choice(content: "One"),
                    Self.choice(content: "Two")
                ]
            ]).data
        ]

        for body in invalidBodies {
            let transport = StubScribeHTTPTransport(responses: [
                .success(Self.response(status: 200, body: body))
            ])
            let provider = DeepSeekScribeProvider(
                credentialLoader: { "key" },
                transport: transport
            )
            do {
                _ = try await provider.generate(try Self.providerRequest(
                    ScribeRequest(intent: .compose, spokenTranscript: "Request"),
                    destination: .deepSeek
                ))
                Issue.record("Expected invalid response")
            } catch let failure as ScribeProviderFailure {
                #expect(failure.category == .invalidResponse)
            } catch {
                Issue.record("Unexpected error type")
            }
        }
    }

    @Test(arguments: [
        (ScribeHTTPTransportError.redirected, ScribeProviderFailureCategory.unsafeConnection),
        (.bodyTooLarge, .invalidResponse),
        (.timedOut, .timedOut),
        (.url(.notConnectedToInternet), .transportUnavailable),
        (.url(.secureConnectionFailed), .unsafeConnection),
        (.cancelled, .cancelled)
    ])
    func transportFailuresMapToClosedSafeCategories(
        transportError: ScribeHTTPTransportError,
        expected: ScribeProviderFailureCategory
    ) async {
        let transport = StubScribeHTTPTransport(responses: [.failure(transportError)])
        let provider = OpenAICompatibleScribeProvider(
            endpoint: try! AdvancedScribeEndpoint("https://provider.example/v1"),
            model: try! ScribeModelIdentifier("model"),
            credentialLoader: { "key" },
            transport: transport
        )

        do {
            let destination = ScribeEgressDestination.advanced(
                origin: "https://provider.example",
                disclosureVersion: ScribeProviderDisclosure.currentVersion
            )
            _ = try await provider.generate(try Self.providerRequest(
                ScribeRequest(intent: .compose, spokenTranscript: "Request"),
                destination: destination
            ))
            Issue.record("Expected provider failure")
        } catch let failure as ScribeProviderFailure {
            #expect(failure.category == expected)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    private static func json(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func providerRequest(
        _ request: ScribeRequest,
        destination: ScribeEgressDestination
    ) throws -> ScribeProviderRequest {
        ScribeProviderRequest(
            id: request.id,
            input: try ScribeRequestPolicy.providerSafeInput(
                for: request,
                destination: destination
            )
        )
    }

    private static func deepSeekResponse(
        content: String,
        finishReason: String = "stop",
        reasoning: String? = nil,
        model: String = "deepseek-v4-flash"
    ) -> ScribeHTTPResponse {
        var message: [String: Any] = [
            "role": "assistant",
            "content": content
        ]
        if let reasoning { message["reasoning_content"] = reasoning }
        return response(status: 200, json: [
            "model": model,
            "choices": [[
                "index": 0,
                "finish_reason": finishReason,
                "message": message
            ]]
        ])
    }

    private static func advancedResponse(content: String) -> ScribeHTTPResponse {
        response(status: 200, json: ["choices": [choice(content: content)]])
    }

    private static func choice(content: String) -> [String: Any] {
        [
            "index": 0,
            "finish_reason": "stop",
            "message": ["role": "assistant", "content": content]
        ]
    }

    private static func response(status: Int, json: [String: Any]) -> ScribeHTTPResponse {
        response(status: status, body: try! JSONSerialization.data(withJSONObject: json))
    }

    private static func response(
        status: Int,
        body: Data,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> ScribeHTTPResponse {
        ScribeHTTPResponse(
            data: body,
            response: HTTPURLResponse(
                url: URL(string: "https://provider.example/chat/completions")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        )
    }
}

private actor StubScribeHTTPTransport: ScribeHTTPTransporting {
    private var responses: [Result<ScribeHTTPResponse, ScribeHTTPTransportError>]
    private(set) var requests: [URLRequest] = []
    private(set) var deadlines: [Duration] = []

    init(responses: [Result<ScribeHTTPResponse, ScribeHTTPTransportError>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest, deadline: Duration) async throws -> ScribeHTTPResponse {
        requests.append(request)
        deadlines.append(deadline)
        return try responses.removeFirst().get()
    }
}
