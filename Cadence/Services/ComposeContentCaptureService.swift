import Foundation

protocol ComposeSelectedTextReading: Sendable {
    func readSelectedText(
        from target: ComposeContentCaptureTarget,
        budget: ComposeContentCaptureBudget
    ) async throws -> ComposeSelectedTextRead
}

/// Opt-in invocation capture only. No caller is installed by this service.
/// A slow reader runs outside the recording path and a late result is dropped.
@MainActor
final class ComposeContentCaptureService {
    private let reader: any ComposeSelectedTextReading
    private let policy: @MainActor () -> ScribeContextPolicySnapshot
    private let permissions: @MainActor () -> ScribeContextPlatformPermissions
    private let currentTarget: @MainActor () -> ComposeContentCaptureTarget?
    private let now: @MainActor () -> Date
    private let uptimeNanoseconds: @Sendable () -> UInt64

    init(
        reader: any ComposeSelectedTextReading,
        policy: @escaping @MainActor () -> ScribeContextPolicySnapshot = { .init() },
        permissions: @escaping @MainActor () -> ScribeContextPlatformPermissions = { .init() },
        currentTarget: @escaping @MainActor () -> ComposeContentCaptureTarget? = { nil },
        now: @escaping @MainActor () -> Date = Date.init,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.reader = reader
        self.policy = policy
        self.permissions = permissions
        self.currentTarget = currentTarget
        self.now = now
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    func captureSelectedText(
        from target: ComposeContentCaptureTarget,
        budget: ComposeContentCaptureBudget = .init()
    ) async -> ComposeContentCaptureOutcome {
        do {
            try Task.checkCancellation()
            guard budget.isValid else { throw ComposeContentCaptureFailure.invalidBudget }
            let request = ScribeContextPolicyRequest(action: target.action, operation: .capture(.selectedText))
            let authorization = try ScribeContextPolicy.authorize(
                request, using: policy(), permissions: permissions(), at: now()
            )
            try validateTarget(target)
            let startedAt = uptimeNanoseconds()
            let race = ComposeSelectedTextReadRace()
            let read = try await withTaskCancellationHandler {
                try await race.read(from: target, budget: budget, using: reader)
            } onCancel: {
                Task { await race.cancel() }
            }
            try Task.checkCancellation()
            let finishedAt = uptimeNanoseconds()
            guard finishedAt >= startedAt,
                  finishedAt - startedAt <= UInt64(budget.timeoutMilliseconds) * 1_000_000 else {
                throw ComposeContentCaptureFailure.timedOut
            }
            try validateTarget(target)
            try ScribeContextPolicy.revalidate(
                authorization, for: request, using: policy(), permissions: permissions(), at: now()
            )
            guard read.identityBefore == target.source, read.identityAfter == target.source else {
                throw ComposeContentCaptureFailure.targetChanged
            }
            guard read.rangeBefore.isValid, read.rangeAfter.isValid else {
                throw ComposeContentCaptureFailure.invalidSelection
            }
            guard read.rangeBefore == read.rangeAfter else {
                throw ComposeContentCaptureFailure.selectionChanged
            }
            guard read.rangeBefore.length > 0, !read.text.isEmpty else {
                throw ComposeContentCaptureFailure.noSelection
            }
            guard read.text.utf8.count <= budget.maximumUTF8Bytes else {
                throw ComposeContentCaptureFailure.contextTooLarge
            }
            guard read.text.utf16.count == read.rangeBefore.length else {
                throw ComposeContentCaptureFailure.invalidSelection
            }
            guard !read.text.unicodeScalars.contains(where: {
                ($0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t") || $0.value == 0x7F
            }) else { throw ComposeContentCaptureFailure.invalidContent }
            return .captured(ComposeContextSnapshot(
                id: UUID(), target: target, selectedRange: read.rangeBefore,
                selectedText: read.text, capturedAt: now(), completeness: .completeSelectedRange,
                authorization: authorization
            ))
        } catch let rejection as ScribeContextPolicyRejection {
            return .unavailable(.policy(rejection))
        } catch let failure as ComposeContentCaptureFailure {
            return .unavailable(failure)
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch {
            return .unavailable(.readFailed)
        }
    }

    /// A future replacement path must call this before any write. The method
    /// only verifies; it neither inserts text nor changes the selected range.
    func revalidateSelectedText(
        _ snapshot: ComposeContextSnapshot,
        budget: ComposeContentCaptureBudget = .init()
    ) async -> ComposeSelectionRevalidationOutcome {
        do {
            try Task.checkCancellation()
            try validateTarget(snapshot.target)
            try ScribeContextPolicy.revalidate(
                snapshot.authorization,
                for: .init(action: snapshot.target.action, operation: .capture(.selectedText)),
                using: policy(), permissions: permissions(), at: now()
            )
        } catch let rejection as ScribeContextPolicyRejection {
            return .unavailable(.policy(rejection))
        } catch let failure as ComposeContentCaptureFailure {
            return .unavailable(failure)
        } catch {
            return .unavailable(.cancelled)
        }
        switch await captureSelectedText(from: snapshot.target, budget: budget) {
        case .unavailable(let failure): return .unavailable(failure)
        case .captured(let current):
            guard current.selectedRange == snapshot.selectedRange,
                  Data(current.selectedText.utf8) == Data(snapshot.selectedText.utf8) else {
                return .unavailable(.selectionChanged)
            }
            return .current
        }
    }

    private func validateTarget(_ target: ComposeContentCaptureTarget) throws {
        guard currentTarget() == target,
              target.action.captureID == target.source.captureID,
              target.action.target == target.source.target,
              target.source.target.processIdentifier == target.source.process.processIdentifier,
              target.source.target.bundleIdentifier == target.source.process.bundleIdentifier,
              !target.source.verificationToken.isEmpty else {
            throw ComposeContentCaptureFailure.targetChanged
        }
    }
}

/// The race deliberately does not await a cancelled reader before returning.
/// A misbehaving adapter cannot hold up the caller after the deadline. The
/// system reader additionally bounds each AX message and polls cancellation.
private actor ComposeSelectedTextReadRace {
    private var continuation: CheckedContinuation<ComposeSelectedTextRead, any Error>?
    private var terminal: Result<ComposeSelectedTextRead, any Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func read(
        from target: ComposeContentCaptureTarget,
        budget: ComposeContentCaptureBudget,
        using reader: any ComposeSelectedTextReading
    ) async throws -> ComposeSelectedTextRead {
        try await withCheckedThrowingContinuation { continuation in
            if let terminal {
                continuation.resume(with: terminal)
                return
            }
            self.continuation = continuation
            work = Task {
                do {
                    let value = try await reader.readSelectedText(from: target, budget: budget)
                    finish(.success(value))
                } catch {
                    finish(.failure(error))
                }
            }
            timer = Task {
                do {
                    try await Task.sleep(for: .milliseconds(budget.timeoutMilliseconds))
                    finish(.failure(ComposeContentCaptureFailure.timedOut))
                } catch {}
            }
        }
    }

    func cancel() { finish(.failure(ComposeContentCaptureFailure.cancelled)) }

    private func finish(_ result: Result<ComposeSelectedTextRead, any Error>) {
        guard terminal == nil else { return }
        terminal = result
        continuation?.resume(with: result)
        continuation = nil
        work?.cancel()
        timer?.cancel()
        work = nil
        timer = nil
    }
}
