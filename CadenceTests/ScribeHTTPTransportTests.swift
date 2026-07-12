import Foundation
import Testing
@testable import Cadence

struct ScribeHTTPTransportTests {
    @Test
    func productionConfigurationIsEphemeralAndHasNoPersistenceSinks() {
        let configuration = ScribeHTTPTransport.ephemeralConfiguration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!configuration.waitsForConnectivity)
    }

    @Test
    func transportCapsStreamingBodyBeforeCompletion() async {
        let configuration = ScribeHTTPTransport.ephemeralConfiguration()
        configuration.protocolClasses = [FixtureURLProtocol.self]
        FixtureURLProtocol.handler = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data(repeating: 0x41, count: 8))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }
        let transport = ScribeHTTPTransport(configuration: configuration, maximumResponseBytes: 4)
        let request = URLRequest(url: URL(string: "https://fixture.example/test")!)

        await #expect(throws: ScribeHTTPTransportError.bodyTooLarge) {
            try await transport.send(request, deadline: .seconds(1))
        }
        FixtureURLProtocol.handler = nil
    }

    @Test
    func absoluteDeadlineCancelsARequestThatNeverCompletes() async {
        let configuration = ScribeHTTPTransport.ephemeralConfiguration()
        configuration.protocolClasses = [FixtureURLProtocol.self]
        FixtureURLProtocol.handler = { _ in }
        let transport = ScribeHTTPTransport(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://fixture.example/hangs")!)

        await #expect(throws: ScribeHTTPTransportError.timedOut) {
            try await transport.send(request, deadline: .milliseconds(10))
        }
        FixtureURLProtocol.handler = nil
    }

    @Test
    func explicitCancellationCompletesWithoutWaitingForTheDeadline() async {
        let configuration = ScribeHTTPTransport.ephemeralConfiguration()
        configuration.protocolClasses = [FixtureURLProtocol.self]
        FixtureURLProtocol.handler = { _ in }
        let transport = ScribeHTTPTransport(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://fixture.example/cancel")!)
        let task = Task {
            try await transport.send(request, deadline: .seconds(10))
        }

        task.cancel()

        await #expect(throws: ScribeHTTPTransportError.cancelled) {
            try await task.value
        }
        FixtureURLProtocol.handler = nil
    }

    @Test
    func lateProtocolCompletionAfterDeadlineIsSuppressed() async throws {
        let configuration = ScribeHTTPTransport.ephemeralConfiguration()
        configuration.protocolClasses = [FixtureURLProtocol.self]
        FixtureURLProtocol.handler = { protocolInstance in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                let response = HTTPURLResponse(
                    url: protocolInstance.request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                protocolInstance.client?.urlProtocol(
                    protocolInstance,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed
                )
                protocolInstance.client?.urlProtocol(
                    protocolInstance,
                    didLoad: Data("{}".utf8)
                )
                protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
            }
        }
        let transport = ScribeHTTPTransport(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://fixture.example/late")!)

        await #expect(throws: ScribeHTTPTransportError.timedOut) {
            try await transport.send(request, deadline: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(100))
        FixtureURLProtocol.handler = nil
    }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedHandler: ((FixtureURLProtocol) -> Void)?

    static var handler: ((FixtureURLProtocol) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handler?(self)
    }

    override func stopLoading() {}
}
