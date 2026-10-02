#if canImport(FoundationModels)
import Foundation
import Testing
@testable import Cadence

struct OnDeviceScribeGenerationTests {
    @Test
    func availabilityStatesGiveDistinctRecoveryAndOnlyReadyHasNoError() {
        #expect(OnDeviceScribeAvailability.available.unavailableReason == nil)
        let unavailable: [OnDeviceScribeAvailability] = [
            .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady,
            .unavailable, .unsupportedOS
        ]
        #expect(Set(unavailable.compactMap(\.unavailableReason)).count == unavailable.count)
        #expect(OnDeviceScribeAvailability.deviceNotEligible.unavailableReason?.contains("does not support") == true)
        #expect(OnDeviceScribeAvailability.appleIntelligenceNotEnabled.unavailableReason?.contains("Turn on") == true)
        #expect(OnDeviceScribeAvailability.modelNotReady.unavailableReason?.contains("download is complete") == true)
        #expect(OnDeviceScribeAvailability.unavailable.unavailableReason?.contains("unavailable") == true)
        #expect(OnDeviceScribeAvailability.unsupportedOS.unavailableReason?.contains("macOS 26") == true)
    }

    @Test
    func productionSettingsHaveNoOutputTokenCapAndThirtySecondDeadline() {
        #expect(OnDeviceScribeGeneration.maximumResponseTokens == nil)
        #expect(OnDeviceScribeGeneration.generationTimeoutMilliseconds == 30_000)
    }

    @Test
    func preparedDraftReturnsExactlyWithoutStartingOperationOrTimer() async throws {
        let operation = OperationProbe()
        let timer = TimeoutProbe()
        let prepared = "  Cafe\u{301}\nDraft  "
        let result = try await OnDeviceScribeGeneration.generate(
            preparedDraft: prepared,
            sleep: { await timer.wait(milliseconds: $0) },
            operation: { await operation.run() }
        )
        #expect(Data(result.utf8) == Data(prepared.utf8))
        #expect(await operation.started == false)
        #expect(await timer.requestedMilliseconds == nil)
    }

    @Test
    func fastSuccessReturnsExactResult() async throws {
        let result = try await OnDeviceScribeGeneration.generate { "Ready.\n" }
        #expect(result == "Ready.\n")
    }

    @Test
    func generationFailurePropagatesWithoutProducingADraft() async {
        do {
            _ = try await OnDeviceScribeGeneration.generate { throw SyntheticFailure.contextWindowExceeded }
            Issue.record("A context failure must not produce a draft")
        } catch let error as SyntheticFailure {
            #expect(error == .contextWindowExceeded)
        } catch {
            Issue.record("Expected the injected generation failure")
        }
    }

    @Test
    func invalidDeadlineStartsNoOperation() async {
        let operation = OperationProbe()
        do {
            _ = try await OnDeviceScribeGeneration.generate(timeoutMilliseconds: 0) { await operation.run() }
            Issue.record("Expected timeout failure")
        } catch let error as OnDeviceScribeGenerationError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Expected the typed timeout failure")
        }
        #expect(await operation.started == false)
    }

    @Test
    func deadlineReturnsBeforeUncooperativeOperationAndDropsItsLateCompletion() async {
        let operation = OperationProbe()
        let timer = TimeoutProbe()
        let pending = Task {
            try await OnDeviceScribeGeneration.generate(
                sleep: { await timer.wait(milliseconds: $0) },
                operation: { await operation.run() }
            )
        }
        await operation.waitUntilStarted()
        await timer.waitUntilStarted()
        #expect(await timer.requestedMilliseconds == 30_000)
        await timer.expire()
        do {
            _ = try await pending.value
            Issue.record("A timed-out operation must not return a draft")
        } catch let error as OnDeviceScribeGenerationError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Expected the typed timeout failure")
        }
        #expect(await operation.finished == false)
        await operation.complete("Late result that must be discarded")
        await operation.waitUntilFinished()
        #expect(await operation.wasCancelledWhenCompleted)
    }

    @Test
    func cancellationReturnsBeforeUncooperativeOperationAndCancelsWork() async {
        let operation = OperationProbe()
        let pending = Task {
            try await OnDeviceScribeGeneration.generate { await operation.run() }
        }
        await operation.waitUntilStarted()
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("Cancelled work must not return a draft")
        } catch is CancellationError {
        } catch {
            Issue.record("Expected CancellationError")
        }
        #expect(await operation.finished == false)
        await operation.complete("Late result after cancellation")
        await operation.waitUntilFinished()
        #expect(await operation.wasCancelledWhenCompleted)
    }

    @Test
    func alreadyCancelledRequestStartsNoOperationEvenWithPreparedDraft() async {
        for preparedDraft in [String?.none, "Prepared draft"] {
            let operation = OperationProbe()
            let pending = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await OnDeviceScribeGeneration.generate(preparedDraft: preparedDraft) {
                    await operation.run()
                }
            }
            do {
                _ = try await pending.value
                Issue.record("Already-cancelled requests must not return a draft")
            } catch is CancellationError {
            } catch {
                Issue.record("Expected CancellationError")
            }
            #expect(await operation.started == false)
        }
    }

    @Test
    func operationSuccessWinsOverLateTimerCompletion() async throws {
        let operation = OperationProbe()
        let timer = TimeoutProbe()
        let pending = Task {
            try await OnDeviceScribeGeneration.generate(
                sleep: { await timer.wait(milliseconds: $0) },
                operation: { await operation.run() }
            )
        }
        await operation.waitUntilStarted()
        await timer.waitUntilStarted()
        await operation.complete("Successful draft")
        #expect(try await pending.value == "Successful draft")
        await timer.expire()
        await timer.waitUntilFinished()
        #expect(await timer.wasCancelledWhenCompleted)
    }

    @Test
    func realWallClockDeadlineReturnsWithoutWaitingForOperation() async {
        let operation = OperationProbe()
        do {
            _ = try await OnDeviceScribeGeneration.generate(timeoutMilliseconds: 20) { await operation.run() }
            Issue.record("Expected the elapsed deadline to fail")
        } catch let error as OnDeviceScribeGenerationError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Expected the typed timeout failure")
        }
        // A very busy test executor can expire the deadline before starting the
        // operation. Complete only an operation that actually suspended.
        await operation.complete("Discarded")
        if await operation.started { await operation.waitUntilFinished() }
    }

    @Test(arguments: [false, true])
    func terminalResponseKeepsGateOccupiedUntilUnderlyingOperationExits(cancelInsteadOfTimeout: Bool) async throws {
        let operation = OperationProbe()
        let timer = TimeoutProbe()
        let released = GateReleaseProbe()
        let retries = ImmediateOperationProbe()
        let gate = OnDeviceScribeGenerationGate(onReleased: {
            Task { await released.recordRelease() }
        })
        let pending = Task {
            try await OnDeviceScribeGeneration.generate(
                gate: gate,
                sleep: { await timer.wait(milliseconds: $0) },
                operation: { await operation.run() }
            )
        }
        await operation.waitUntilStarted()
        await timer.waitUntilStarted()
        if cancelInsteadOfTimeout {
            pending.cancel()
            await #expect(throws: CancellationError.self) { try await pending.value }
        } else {
            await timer.expire()
            await #expect(throws: OnDeviceScribeGenerationError.timedOut) { try await pending.value }
        }
        #expect(await operation.finished == false)
        #expect(await released.releaseCount == 0)

        for _ in 0..<3 {
            await #expect(throws: OnDeviceScribeGenerationError.busy) {
                try await OnDeviceScribeGeneration.generate(gate: gate) { await retries.run() }
            }
        }
        #expect(await retries.callCount == 0)
        #expect(await released.releaseCount == 0)

        await operation.complete("Late result must be discarded")
        // The operation probe finishes before the generator's defer releases
        // its gate. Wait for the actual release before asserting recovery.
        await released.waitUntilReleased()
        #expect(await operation.wasCancelledWhenCompleted)
        let recovered = try await OnDeviceScribeGeneration.generate(gate: gate) { "Recovered draft" }
        #expect(recovered == "Recovered draft")
        await timer.expire()
        await timer.waitUntilFinished()
    }

    @Test
    func preparedDraftBypassesOccupiedGateWithoutStartingAnotherOperationOrTimer() async throws {
        let operation = OperationProbe()
        let bypassOperation = ImmediateOperationProbe()
        let bypassTimer = TimeoutProbe()
        let released = GateReleaseProbe()
        let gate = OnDeviceScribeGenerationGate(onReleased: {
            Task { await released.recordRelease() }
        })
        let pending = Task {
            try await OnDeviceScribeGeneration.generate(gate: gate) { await operation.run() }
        }
        await operation.waitUntilStarted()
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let prepared = "  Cafe\u{301}\nPrepared draft  "
        let result = try await OnDeviceScribeGeneration.generate(
            preparedDraft: prepared,
            gate: gate,
            sleep: { await bypassTimer.wait(milliseconds: $0) },
            operation: { await bypassOperation.run() }
        )
        #expect(Data(result.utf8) == Data(prepared.utf8))
        #expect(await bypassOperation.callCount == 0)
        #expect(await bypassTimer.requestedMilliseconds == nil)
        #expect(await released.releaseCount == 0)
        await operation.complete("Discarded after prepared draft bypass")
        await released.waitUntilReleased()
    }

    @Test
    func cancellationImmediatelyAfterAcquisitionStartsNoOperationAndReleasesGate() async {
        let operation = ImmediateOperationProbe()
        let released = GateReleaseProbe()
        let gate = OnDeviceScribeGenerationGate(
            onAcquired: { withUnsafeCurrentTask { $0?.cancel() } },
            onReleased: { Task { await released.recordRelease() } }
        )
        let pending = Task {
            try await OnDeviceScribeGeneration.generate(gate: gate) { await operation.run() }
        }
        await #expect(throws: CancellationError.self) { try await pending.value }
        await released.waitUntilReleased()
        #expect(await operation.callCount == 0)
        #expect(await released.releaseCount == 1)
    }

    @Test
    func operationFinishingAfterMonotonicDeadlineCannotWinAgainstDelayedTimer() async {
        let operation = OperationProbe()
        let timer = TimeoutProbe()
        let clock = MonotonicClockProbe(nanoseconds: 1_000_000)
        let pending = Task {
            try await OnDeviceScribeGeneration.generate(
                timeoutMilliseconds: 10,
                nowNanoseconds: { clock.read() },
                sleep: { await timer.wait(milliseconds: $0) },
                operation: { await operation.run() }
            )
        }
        await operation.waitUntilStarted()
        await timer.waitUntilStarted()
        clock.advance(by: 11_000_000)
        await operation.complete("Too late even though the timer is still suspended")
        await #expect(throws: OnDeviceScribeGenerationError.timedOut) { try await pending.value }
        await timer.expire()
        await timer.waitUntilFinished()
        #expect(await timer.wasCancelledWhenCompleted)
    }

    @Test(arguments: [false, true])
    func normalCompletionReleasesPermitBeforePublishingResult(throwsFailure: Bool) async throws {
        let released = SynchronousGateReleaseProbe()
        let gate = OnDeviceScribeGenerationGate(onReleased: { released.recordRelease() })
        do {
            let result = try await OnDeviceScribeGeneration.generate(gate: gate) {
                if throwsFailure { throw SyntheticFailure.contextWindowExceeded }
                return "First draft"
            }
            #expect(released.releaseCount == 1)
            #expect(!throwsFailure)
            #expect(result == "First draft")
        } catch let error as SyntheticFailure {
            #expect(released.releaseCount == 1)
            #expect(throwsFailure)
            #expect(error == .contextWindowExceeded)
        }
        // No actor signal, wait, or yield separates caller completion from the
        // next admission. A completed operation must not cause a false busy.
        let next = try await OnDeviceScribeGeneration.generate(gate: gate) { "Next draft" }
        #expect(released.releaseCount == 2)
        #expect(next == "Next draft")
    }

    private enum SyntheticFailure: Error, Equatable { case contextWindowExceeded }

    private final class SynchronousGateReleaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var releaseCount: Int { lock.withLock { count } }

        func recordRelease() { lock.withLock { count += 1 } }
    }

    private actor ImmediateOperationProbe {
        private(set) var callCount = 0
        func run() -> String {
            callCount += 1
            return "Unexpected additional operation"
        }
    }

    private actor GateReleaseProbe {
        private(set) var releaseCount = 0
        private var observer: CheckedContinuation<Void, Never>?

        func recordRelease() {
            releaseCount += 1
            observer?.resume()
            observer = nil
        }

        func waitUntilReleased() async {
            if releaseCount > 0 { return }
            await withCheckedContinuation { observer = $0 }
        }
    }

    private final class MonotonicClockProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64

        init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

        func read() -> UInt64 { lock.withLock { nanoseconds } }

        func advance(by amount: UInt64) { lock.withLock { nanoseconds += amount } }
    }

    /// Deliberately ignores cancellation until explicitly completed, proving
    /// that the caller does not await an uncooperative generation task.
    private actor OperationProbe {
        private(set) var started = false
        private(set) var finished = false
        private(set) var wasCancelledWhenCompleted = false
        private var continuation: CheckedContinuation<String, Never>?
        private var completedValue: String?
        private var startObserver: CheckedContinuation<Void, Never>?
        private var finishObserver: CheckedContinuation<Void, Never>?

        func run() async -> String {
            started = true
            startObserver?.resume()
            startObserver = nil
            let result: String
            if let completedValue { result = completedValue }
            else { result = await withCheckedContinuation { continuation = $0 } }
            wasCancelledWhenCompleted = Task.isCancelled
            finished = true
            finishObserver?.resume()
            finishObserver = nil
            return result
        }

        func complete(_ result: String) {
            completedValue = result
            continuation?.resume(returning: result)
            continuation = nil
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startObserver = $0 }
        }

        func waitUntilFinished() async {
            if finished { return }
            await withCheckedContinuation { finishObserver = $0 }
        }
    }

    private actor TimeoutProbe {
        private(set) var requestedMilliseconds: Int?
        private(set) var wasCancelledWhenCompleted = false
        private var finished = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var startObserver: CheckedContinuation<Void, Never>?
        private var finishObserver: CheckedContinuation<Void, Never>?

        func wait(milliseconds: Int) async {
            requestedMilliseconds = milliseconds
            startObserver?.resume()
            startObserver = nil
            await withCheckedContinuation { continuation = $0 }
            wasCancelledWhenCompleted = Task.isCancelled
            finished = true
            finishObserver?.resume()
            finishObserver = nil
        }

        func expire() {
            continuation?.resume()
            continuation = nil
        }

        func waitUntilStarted() async {
            if requestedMilliseconds != nil { return }
            await withCheckedContinuation { startObserver = $0 }
        }

        func waitUntilFinished() async {
            if finished { return }
            await withCheckedContinuation { finishObserver = $0 }
        }
    }
}
#endif
