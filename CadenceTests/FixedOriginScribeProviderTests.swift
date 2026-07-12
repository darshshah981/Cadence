import Foundation
import Testing
@testable import Cadence

struct FixedOriginScribeProviderTests {
    @Test
    func openAIRequestIsCanonicalAndResponseIsStrict() async throws {
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://api.openai.com/v1/responses")!,
            body: #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"  Draft  "}]}]}"#
        ))])
        let provider = OpenAIDirectScribeProvider(
            model: try ScribeModelIdentifier("gpt-test"),
            credentialLoader: { "secret" },
            transport: transport
        )
        let result = try await provider.generate(Self.request)
        #expect(result.text == "Draft")
        let sent = try #require(await transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(sent.httpMethod == "POST")
        #expect(sent.allHTTPHeaderFields == ["Authorization": "Bearer secret", "Content-Type": "application/json"])
        #expect(String(data: try #require(sent.httpBody), encoding: .utf8) ==
            #"{"input":"user","instructions":"system","max_output_tokens":1024,"model":"gpt-test","store":false,"stream":false}"#)
    }

    @Test(arguments: [
        #"{"status":"in_progress","output":[]}"#,
        #"{"status":"completed","output":[]}"#,
        #"{"status":"completed","output":[{"type":"tool_call","status":"completed"}]}"#,
        #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"   "}]}]}"#,
        #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"one"}]},{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"two"}]}]}"#,
        #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"one"},{"type":"output_text","text":"two"}]}]}"#
    ])
    func openAIRejectsAmbiguousOrNonMessageResponses(body: String) async {
        await Self.expectInvalidOpenAI(body)
    }

    @Test
    func openRouterRequestIsCanonicalAndResponseIsStrict() async throws {
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: url,
            body: #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":" Draft "}}]}"#
        ))])
        let provider = OpenRouterScribeProvider(
            model: try ScribeModelIdentifier("openai/gpt-test"),
            credentialLoader: { "secret" },
            transport: transport
        )
        #expect(try await provider.generate(Self.request).text == "Draft")
        let sent = try #require(await transport.requests.first)
        #expect(sent.url == url)
        #expect(sent.allHTTPHeaderFields == ["Authorization": "Bearer secret", "Content-Type": "application/json"])
        #expect(String(data: try #require(sent.httpBody), encoding: .utf8) ==
            #"{"max_completion_tokens":1024,"messages":[{"content":"system","role":"system"},{"content":"user","role":"user"}],"model":"openai/gpt-test","provider":{"data_collection":"deny","zdr":true},"stream":false}"#)
        #expect(await transport.requests.count == 1)
    }

    @Test
    func validationUsesTheSameFixedBuildersAndStrictParsers() async throws {
        let openAITransport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://api.openai.com/v1/responses")!,
            body: #"{"status":"completed","output":[{"type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#
        ))])
        let openAI = OpenAIDirectScribeProvider(
            model: try ScribeModelIdentifier("gpt-test"),
            credentialLoader: { "secret" }, transport: openAITransport
        )
        try await openAI.validateConnection()
        #expect(String(
            data: try #require(await openAITransport.requests.first?.httpBody),
            encoding: .utf8
        ) == #"{"input":"Cadence provider compatibility check.","instructions":"Return only OK.","max_output_tokens":8,"model":"gpt-test","store":false,"stream":false}"#)

        let openRouterTransport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            body: #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"OK"}}]}"#
        ))])
        let openRouter = OpenRouterScribeProvider(
            model: try ScribeModelIdentifier("openai/gpt-test"),
            credentialLoader: { "secret" }, transport: openRouterTransport
        )
        try await openRouter.validateConnection()
        #expect(String(
            data: try #require(await openRouterTransport.requests.first?.httpBody),
            encoding: .utf8
        ) == #"{"max_completion_tokens":8,"messages":[{"content":"Return only OK.","role":"system"},{"content":"Cadence provider compatibility check.","role":"user"}],"model":"openai/gpt-test","provider":{"data_collection":"deny","zdr":true},"stream":false}"#)
    }

    @Test(arguments: [
        (401, ScribeProviderFailureCategory.credentialRejected, ScribeProviderRetryDisposition.reconnect),
        (402, .balanceRequired, .manualAfterWait),
        (403, .providerRejected, .none),
        (429, .rateLimited, .manualAfterWait),
        (500, .providerUnavailable, .manualNow),
        (422, .incompatibleRequest, .updateCadence),
        (451, .providerRejected, .none)
    ])
    func fixedOriginStatusFailuresAreTypedAndNeverRetried(
        status: Int,
        category: ScribeProviderFailureCategory,
        retry: ScribeProviderRetryDisposition
    ) async {
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://api.openai.com/v1/responses")!,
            status: status,
            body: #"{"sensitive":"ignored"}"#
        ))])
        let provider = OpenAIDirectScribeProvider(
            model: try! ScribeModelIdentifier("gpt-test"),
            credentialLoader: { "secret" }, transport: transport
        )
        do {
            _ = try await provider.generate(Self.request)
            Issue.record("Expected typed failure")
        } catch let failure as ScribeProviderFailure {
            #expect(failure.category == category)
            #expect(failure.retryDisposition == retry)
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [
        ScribeHTTPTransportError.cancelled,
        .timedOut,
        .redirected,
        .bodyTooLarge,
        .url(.notConnectedToInternet)
    ])
    func fixedOriginTransportFailuresNeverRetry(error: ScribeHTTPTransportError) async {
        let transport = U4RecordingTransport(results: [.failure(error)])
        let provider = OpenRouterScribeProvider(
            model: try! ScribeModelIdentifier("openai/gpt-test"),
            credentialLoader: { "secret" }, transport: transport
        )
        await #expect(throws: ScribeProviderFailure.self) {
            _ = try await provider.generate(Self.request)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [
        (429, #"{"error":{"type":"insufficient_quota","code":"insufficient_quota","message":"secret"}}"#, ScribeProviderFailureCategory.balanceRequired),
        (403, #"{"error":{"type":"guardrail_rejected","code":"content_filter","message":"secret"}}"#, .providerRejected),
        (404, #"{"error":{"type":"invalid_request_error","code":"model_not_found","message":"secret"}}"#, .endpointNotFound),
        (400, #"{"error":{"type":"invalid_request_error","code":"invalid_request","message":"secret"}}"#, .incompatibleRequest)
    ])
    func openAIMapsOnlyBoundedAllowlistedErrorSignals(
        status: Int,
        body: String,
        category: ScribeProviderFailureCategory
    ) async {
        await Self.expectFailure(
            provider: OpenAIDirectScribeProvider(
                model: try! ScribeModelIdentifier("gpt-test"),
                credentialLoader: { "secret" },
                transport: U4RecordingTransport(results: [.success(U4Fixtures.response(
                    url: URL(string: "https://api.openai.com/v1/responses")!,
                    status: status, body: body
                ))])
            ),
            category: category
        )
    }

    @Test(arguments: [
        (401, #"{"error":{"code":401,"message":"secret","metadata":{"error_type":"authentication"}}}"#, ScribeProviderFailureCategory.credentialRejected),
        (503, #"{"error":{"code":503,"message":"secret","metadata":{"error_type":"provider_unavailable"}}}"#, .providerUnavailable),
        (402, #"{"error":{"code":402,"message":"secret","metadata":{"error_type":"payment_required"}}}"#, .balanceRequired),
        (429, #"{"error":{"code":429,"message":"secret","metadata":{"error_type":"rate_limit_exceeded"}}}"#, .rateLimited),
        (403, #"{"error":{"code":403,"message":"secret","metadata":{"error_type":"content_policy_violation"}}}"#, .providerRejected),
        (403, #"{"error":{"code":403,"message":"secret","metadata":{"error_type":"payment_required"}}}"#, .balanceRequired),
        (403, #"{"error":{"code":403,"message":"secret","metadata":{"error_type":"future_unknown"}}}"#, .providerRejected),
        (404, #"{"error":{"code":404,"message":"secret","metadata":{"error_type":"not_found"}}}"#, .endpointNotFound),
        (400, #"{"error":{"code":400,"message":"secret","metadata":{"error_type":"invalid_request"}}}"#, .incompatibleRequest)
    ])
    func openRouterMapsOnlyBoundedAllowlistedErrorSignals(
        status: Int,
        body: String,
        category: ScribeProviderFailureCategory
    ) async {
        await Self.expectFailure(
            provider: OpenRouterScribeProvider(
                model: try! ScribeModelIdentifier("openai/gpt-test"),
                credentialLoader: { "secret" },
                transport: U4RecordingTransport(results: [.success(U4Fixtures.response(
                    url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                    status: status, body: body
                ))])
            ),
            category: category
        )
    }

    @Test
    func invalidContentTypeAndEmptyCredentialFailClosedWithoutRetry() async {
        let contentTypeTransport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://api.openai.com/v1/responses")!,
            body: "{}",
            headers: ["Content-Type": "text/plain"]
        ))])
        await Self.expectFailure(
            provider: OpenAIDirectScribeProvider(
                model: try! ScribeModelIdentifier("gpt-test"),
                credentialLoader: { "secret" }, transport: contentTypeTransport
            ),
            category: .invalidResponse
        )
        #expect(await contentTypeTransport.requests.count == 1)

        let noIO = U4RecordingTransport(results: [])
        await Self.expectFailure(
            provider: OpenRouterScribeProvider(
                model: try! ScribeModelIdentifier("openai/gpt-test"),
                credentialLoader: { "" }, transport: noIO
            ),
            category: .credentialRejected
        )
        #expect(await noIO.requests.isEmpty)
    }

    @Test
    func contentFilterFinishAndOversizedErrorSignalFailClosedCoarsely() async {
        let filterTransport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            body: #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"content_filter","message":{"role":"assistant","content":""}}]}"#
        ))])
        await Self.expectFailure(
            provider: OpenRouterScribeProvider(
                model: try! ScribeModelIdentifier("openai/gpt-test"),
                credentialLoader: { "secret" }, transport: filterTransport
            ),
            category: .providerRejected
        )

        let oversizedCode = String(repeating: "p", count: 129)
        let malformedSignalTransport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://api.openai.com/v1/responses")!,
            status: 401,
            body: #"{"error":{"code":"\#(oversizedCode)","message":"never surfaced"}}"#
        ))])
        await Self.expectFailure(
            provider: OpenAIDirectScribeProvider(
                model: try! ScribeModelIdentifier("gpt-test"),
                credentialLoader: { "secret" }, transport: malformedSignalTransport
            ),
            category: .credentialRejected
        )
    }

    @Test
    func openRouterHTTP200ErrorFinishIsCoarseProviderFailure() async {
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            body: #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"error","message":{"role":"assistant","content":"provider secret"}}]}"#
        ))])
        await Self.expectFailure(
            provider: OpenRouterScribeProvider(
                model: try! ScribeModelIdentifier("openai/gpt-test"),
                credentialLoader: { "secret" }, transport: transport
            ),
            category: .providerUnavailable
        )
    }

    @Test(arguments: [
        (#"payment_required"#, ScribeProviderFailureCategory.balanceRequired),
        (#"refusal"#, .providerRejected),
        (#"provider_error"#, .providerUnavailable),
        (#"invalid_prompt"#, .incompatibleRequest),
        (#"future_unknown"#, .providerUnavailable)
    ])
    func openRouterHTTP200NestedOfficialErrorIsBoundedAndTyped(
        errorType: String,
        category: ScribeProviderFailureCategory
    ) async {
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            body: #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"error","error":{"message":"never surfaced","metadata":{"error_type":"\#(errorType)"}}}]}"#
        ))])
        await Self.expectFailure(
            provider: OpenRouterScribeProvider(
                model: try! ScribeModelIdentifier("openai/gpt-test"),
                credentialLoader: { "secret" }, transport: transport
            ),
            category: category
        )
    }

    @Test(arguments: [
        #"{"model":"other","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Draft"}}]}"#,
        #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"length","message":{"role":"assistant","content":"Draft"}}]}"#,
        #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Draft","tool_calls":[{}]}}]}"#,
        #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Draft","function_call":{}}}]}"#,
        #"{"model":"openai/gpt-test","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"one"}},{"index":1,"finish_reason":"stop","message":{"role":"assistant","content":"two"}}]}"#
    ])
    func openRouterRejectsModelMismatchToolsAndAmbiguity(body: String) async {
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, body: body
        ))])
        let provider = OpenRouterScribeProvider(
            model: try! ScribeModelIdentifier("openai/gpt-test"),
            credentialLoader: { "secret" }, transport: transport
        )
        do {
            _ = try await provider.generate(Self.request)
            Issue.record("Expected invalid response")
        } catch let failure as ScribeProviderFailure {
            #expect(failure.category == .invalidResponse)
        } catch { Issue.record("Unexpected error: \(error)") }
        #expect(await transport.requests.count == 1)
    }

    private static let request = ScribeProviderRequest(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        input: ProviderSafeScribeInput(systemMessage: "system", userMessage: "user")
    )

    private static func expectInvalidOpenAI(_ body: String) async {
        let transport = U4RecordingTransport(results: [.success(U4Fixtures.response(
            url: URL(string: "https://api.openai.com/v1/responses")!, body: body
        ))])
        let provider = OpenAIDirectScribeProvider(
            model: try! ScribeModelIdentifier("gpt-test"),
            credentialLoader: { "secret" }, transport: transport
        )
        do {
            _ = try await provider.generate(request)
            Issue.record("Expected invalid response")
        } catch let failure as ScribeProviderFailure {
            #expect(failure.category == .invalidResponse)
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    private static func expectFailure(
        provider: any ScribeProvider,
        category: ScribeProviderFailureCategory
    ) async {
        do {
            _ = try await provider.generate(request)
            Issue.record("Expected failure")
        } catch let failure as ScribeProviderFailure {
            #expect(failure.category == category)
        } catch { Issue.record("Unexpected error: \(error)") }
    }
}

actor U4RecordingTransport: ScribeHTTPTransporting {
    var requests: [URLRequest] = []
    private var results: [Result<ScribeHTTPResponse, Error>]

    init(results: [Result<ScribeHTTPResponse, Error>]) { self.results = results }

    func send(_ request: URLRequest, deadline: Duration) async throws -> ScribeHTTPResponse {
        requests.append(request)
        guard !results.isEmpty else { throw ScribeHTTPTransportError.invalidResponse }
        return try results.removeFirst().get()
    }
}

enum U4Fixtures {
    static func response(
        url: URL,
        status: Int = 200,
        body: String,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> ScribeHTTPResponse {
        ScribeHTTPResponse(
            data: Data(body.utf8),
            response: HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
        )
    }
}
