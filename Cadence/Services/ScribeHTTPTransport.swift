import Foundation

struct ScribeHTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse
}

enum ScribeHTTPTransportError: Error, Equatable, Sendable {
    case cancelled
    case timedOut
    case redirected
    case bodyTooLarge
    case invalidResponse
    case url(URLError.Code)
}

protocol ScribeHTTPTransporting: Sendable {
    func send(_ request: URLRequest, deadline: Duration) async throws -> ScribeHTTPResponse
}

final class ScribeHTTPTransport: ScribeHTTPTransporting, @unchecked Sendable {
    static let maximumResponseBytes = 1_024 * 1_024

    private let delegate: ScribeHTTPTransportDelegate
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(
        configuration: configuration,
        delegate: delegate,
        delegateQueue: nil
    )

    init(
        configuration: URLSessionConfiguration = ScribeHTTPTransport.ephemeralConfiguration(),
        maximumResponseBytes: Int = ScribeHTTPTransport.maximumResponseBytes
    ) {
        self.configuration = configuration
        self.delegate = ScribeHTTPTransportDelegate(maximumResponseBytes: maximumResponseBytes)
    }

    func send(_ request: URLRequest, deadline: Duration) async throws -> ScribeHTTPResponse {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(task: task, deadline: deadline, continuation: continuation)
                if Task.isCancelled {
                    delegate.cancel(task: task, error: .cancelled)
                }
            }
        } onCancel: {
            self.delegate.cancel(task: task, error: .cancelled)
        }
    }

    static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return configuration
    }
}

private final class ScribeHTTPTransportDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        var data = Data()
        var response: HTTPURLResponse?
        let continuation: CheckedContinuation<ScribeHTTPResponse, Error>
        var deadlineTask: Task<Void, Never>?

        init(continuation: CheckedContinuation<ScribeHTTPResponse, Error>) {
            self.continuation = continuation
        }
    }

    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func register(
        task: URLSessionDataTask,
        deadline: Duration,
        continuation: CheckedContinuation<ScribeHTTPResponse, Error>
    ) {
        let item = Pending(continuation: continuation)
        lock.withLock { pending[task.taskIdentifier] = item }
        item.deadlineTask = Task { [weak self, weak task] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return
            }
            guard let self, let task else { return }
            self.cancel(task: task, error: .timedOut)
        }
        task.resume()
    }

    func cancel(task: URLSessionTask, error: ScribeHTTPTransportError) {
        let item = take(taskIdentifier: task.taskIdentifier)
        task.cancel()
        item?.deadlineTask?.cancel()
        item?.continuation.resume(throwing: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        cancel(task: task, error: .redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            cancel(task: dataTask, error: .invalidResponse)
            return
        }
        lock.withLock { pending[dataTask.taskIdentifier]?.response = response }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var overflowed = false
        lock.withLock {
            guard let item = pending[dataTask.taskIdentifier] else { return }
            if item.data.count + data.count > maximumResponseBytes {
                overflowed = true
            } else {
                item.data.append(data)
            }
        }
        if overflowed {
            cancel(task: dataTask, error: .bodyTooLarge)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let item = take(taskIdentifier: task.taskIdentifier) else { return }
        item.deadlineTask?.cancel()
        if let error {
            let code = (error as? URLError)?.code ?? URLError.Code(rawValue: (error as NSError).code)
            let transportError: ScribeHTTPTransportError = code == .cancelled
                ? .cancelled
                : .url(code)
            item.continuation.resume(throwing: transportError)
            return
        }
        guard let response = item.response else {
            item.continuation.resume(throwing: ScribeHTTPTransportError.invalidResponse)
            return
        }
        item.continuation.resume(returning: ScribeHTTPResponse(data: item.data, response: response))
    }

    private func take(taskIdentifier: Int) -> Pending? {
        lock.withLock { pending.removeValue(forKey: taskIdentifier) }
    }
}
