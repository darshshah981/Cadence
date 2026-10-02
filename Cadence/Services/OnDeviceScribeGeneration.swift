#if canImport(FoundationModels)
import Foundation
import FoundationModels
import OSLog

private let onDeviceScribeGenerationLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "OnDeviceScribeGeneration")

enum OnDeviceScribeGenerationError: Error, Equatable, Sendable {
    case timedOut
    case busy
}

enum OnDeviceScribeGeneration {
    // A fixed output-token ceiling can return a truncated String without a
    // completion signal on macOS 26. Bound caller waiting and admission of
    // model work instead; task cancellation does not guarantee a hard stop.
    static let maximumResponseTokens: Int? = nil
    static let generationTimeoutMilliseconds: Int = 30_000
    private static let productionGate = OnDeviceScribeGenerationGate()

    @available(macOS 26.0, *)
    static func generate(systemMessage: String, userMessage: String, preparedDraft: String? = nil) async throws -> String {
        try await generate(preparedDraft: preparedDraft, gate: productionGate) {
            let session = LanguageModelSession(instructions: systemMessage)
            let response = try await session.respond(
                to: userMessage,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
            )
            return response.content
        }
    }

    /// The injected operation is also the deterministic test seam. Prepared
    /// drafts return before starting either the operation or its timeout task.
    /// The default gate isolates injected tests. Production explicitly passes
    /// its process-wide gate; concurrency tests share an injected gate too.
    /// Keeping this helper here binds the CLI evaluation hash to admission and
    /// timeout behavior as well as the model's generation settings.
    static func generate(
        preparedDraft: String? = nil,
        timeoutMilliseconds: Int = generationTimeoutMilliseconds,
        gate: OnDeviceScribeGenerationGate = OnDeviceScribeGenerationGate(),
        nowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (@Sendable (Int) async throws -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try Task.checkCancellation()
        if let preparedDraft { return preparedDraft }
        guard timeoutMilliseconds > 0 else { throw OnDeviceScribeGenerationError.timedOut }
        let race = OnDeviceScribeResponseRace(timeoutMilliseconds: timeoutMilliseconds, nowNanoseconds: nowNanoseconds)
        guard let permit = gate.acquire() else {
            try Task.checkCancellation()
            throw OnDeviceScribeGenerationError.busy
        }
        let draft = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let operationTask = Task {
                    // The actual operation owns this permit. A caller deadline
                    // or cancellation must never release it while work remains.
                    // The defer also covers cancellation before operation start.
                    defer { gate.release(permit) }
                    do {
                        try Task.checkCancellation()
                        guard race.canStartOperation else { return }
                        let draft = try await operation()
                        // Release before publication so an immediately chained
                        // request cannot see busy after completed model work.
                        gate.release(permit)
                        try Task.checkCancellation()
                        race.resolve(.success(draft))
                    } catch {
                        gate.release(permit)
                        race.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        if let sleep {
                            try await sleep(timeoutMilliseconds)
                        } else {
                            // Scheduling this timer late does not restart its
                            // budget. Injected sleeps retain their manual seam.
                            try await Task.sleep(nanoseconds: race.remainingNanoseconds)
                        }
                        try Task.checkCancellation()
                        race.resolve(.failure(OnDeviceScribeGenerationError.timedOut))
                    } catch {}
                }
                race.installTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.cancel()
        }
        try Task.checkCancellation()
        return draft
    }
}

/// One admitted model operation, without a waiting queue. The permit survives
/// caller cancellation until the operation actually exits, even when the
/// injected/platform operation ignores cancellation. A hung operation keeps
/// local generation busy rather than allowing abandoned work to accumulate.
final class OnDeviceScribeGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var activePermit: UUID?
    private let onAcquired: @Sendable () -> Void
    private let onReleased: @Sendable () -> Void

    /// Synchronous, nonblocking lifecycle observers are a deterministic test
    /// seam. Production does not supply them; they receive no request content.
    init(onAcquired: @escaping @Sendable () -> Void = {}, onReleased: @escaping @Sendable () -> Void = {}) {
        self.onAcquired = onAcquired
        self.onReleased = onReleased
    }

    fileprivate func acquire() -> UUID? {
        let permit = lock.withLock { () -> UUID? in
            guard activePermit == nil else { return nil }
            let permit = UUID()
            activePermit = permit
            return permit
        }
        if permit != nil { onAcquired() }
        return permit
    }

    fileprivate func release(_ permit: UUID) {
        let didRelease = lock.withLock {
            guard activePermit == permit else { return false }
            activePermit = nil
            return true
        }
        if didRelease { onReleased() }
    }
}

/// Exactly one terminal result wins. Cancellation and deadline expiration
/// return immediately without waiting for an operation that ignores its task's
/// cancellation. Late results are discarded and never become usable drafts.
private final class OnDeviceScribeResponseRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, any Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var terminal: Result<String, any Error>?
    private let nowNanoseconds: @Sendable () -> UInt64
    private let deadlineNanoseconds: UInt64

    init(timeoutMilliseconds: Int, nowNanoseconds: @escaping @Sendable () -> UInt64) {
        self.nowNanoseconds = nowNanoseconds
        let duration = UInt64(timeoutMilliseconds).multipliedReportingOverflow(by: 1_000_000)
        let deadline = nowNanoseconds().addingReportingOverflow(duration.partialValue)
        deadlineNanoseconds = duration.overflow || deadline.overflow ? UInt64.max : deadline.partialValue
    }

    var remainingNanoseconds: UInt64 {
        let now = nowNanoseconds()
        return now < deadlineNanoseconds ? deadlineNanoseconds - now : 0
    }

    var canStartOperation: Bool {
        let pending = lock.withLock { terminal == nil }
        guard pending else { return false }
        guard nowNanoseconds() < deadlineNanoseconds else {
            resolve(.failure(OnDeviceScribeGenerationError.timedOut))
            return false
        }
        return lock.withLock { terminal == nil }
    }

    func install(_ continuation: CheckedContinuation<String, any Error>) {
        let completed = lock.withLock { () -> Result<String, any Error>? in
            if let terminal { return terminal }
            self.continuation = continuation
            return nil
        }
        if let completed { continuation.resume(with: completed) }
    }

    func installTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard terminal == nil else { return true }
            operationTask = operation
            timeoutTask = timeout
            return false
        }
        if shouldCancel {
            operation.cancel()
            timeout.cancel()
        }
    }

    func resolve(_ result: Result<String, any Error>, enforceDeadline: Bool = true) {
        let pending = lock.withLock { () -> (
            CheckedContinuation<String, any Error>?, Task<Void, Never>?, Task<Void, Never>?, Result<String, any Error>?
        ) in
            guard terminal == nil else { return (nil, nil, nil, nil) }
            // A delayed timeout task cannot publish a response completed after
            // the monotonic deadline. Explicit cancellation retains its type.
            let finalResult: Result<String, any Error> = enforceDeadline && nowNanoseconds() >= deadlineNanoseconds
                ? .failure(OnDeviceScribeGenerationError.timedOut)
                : result
            terminal = finalResult
            let pending = (continuation, operationTask, timeoutTask, finalResult)
            continuation = nil
            operationTask = nil
            timeoutTask = nil
            return pending
        }
        pending.1?.cancel()
        pending.2?.cancel()
        if let finalResult = pending.3 { pending.0?.resume(with: finalResult) }
    }

    func cancel() { resolve(.failure(CancellationError()), enforceDeadline: false) }
}
#endif
