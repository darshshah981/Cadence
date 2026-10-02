import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribePersistentMemoryMaintenanceTests {
    @Test
    func absentAuthorizationAndConstructionNeverRunWork() {
        var purges = 0, invalidations = 0
        let service = ScribePersistentMemoryMaintenance(isAuthorized: { false }, purge: { purges += 1; return 0 },
            invalidate: { invalidations += 1 }, onInvalidated: { invalidations += 1 })
        service.start(); service.stop()
        #expect(!service.isRunning)
        #expect(purges == 0 && invalidations == 0)
    }

    @Test
    func startIsIdempotentAndUnchangedPassesDoNotInvalidateDrafts() async {
        let clock = MaintenanceTestSleeper()
        var purges = 0, invalidations = 0
        let service = ScribePersistentMemoryMaintenance(isAuthorized: { true }, purge: { purges += 1; return 0 },
            invalidate: { invalidations += 1 }, onInvalidated: { invalidations += 1 }, sleep: { try await clock.sleep($0) })
        service.start(); service.start()
        await clock.waitForSleep(count: 1)
        #expect(purges == 1 && invalidations == 0)
        await clock.wake()
        await clock.waitForSleep(count: 2)
        #expect(purges == 2 && invalidations == 0)
        #expect(await clock.intervals == [.seconds(60), .seconds(60)])
        service.stop(); service.stop()
        await clock.wake()
        #expect(invalidations == 2)
        #expect(!service.isRunning)
    }

    @Test
    func expiryInvalidatesReceiptsBeforeNotifyingConsumer() async {
        let clock = MaintenanceTestSleeper()
        var events: [String] = []
        let service = ScribePersistentMemoryMaintenance(isAuthorized: { true }, purge: { events.append("purge"); return 2 },
            invalidate: { events.append("invalidate") }, onInvalidated: { events.append("notify") }, sleep: { try await clock.sleep($0) })
        service.start()
        await clock.waitForSleep(count: 1)
        #expect(events == ["purge", "invalidate", "notify"])
        service.stop()
        await clock.wake()
    }

    @Test
    func authorizationLossAtWakeStopsBeforeDiskWork() async {
        let clock = MaintenanceTestSleeper()
        var authorized = true, purges = 0, invalidations = 0
        let service = ScribePersistentMemoryMaintenance(isAuthorized: { authorized }, purge: { purges += 1; return 0 },
            invalidate: { invalidations += 1 }, onInvalidated: {}, sleep: { try await clock.sleep($0) })
        service.start()
        await clock.waitForSleep(count: 1)
        authorized = false
        await clock.wake()
        while service.isRunning { await Task.yield() }
        #expect(purges == 1 && invalidations == 1)
    }

    @Test
    func oldNoncooperativeWakeCannotRestartStoppedGeneration() async {
        let clock = MaintenanceTestSleeper()
        var purges = 0
        let service = ScribePersistentMemoryMaintenance(isAuthorized: { true }, purge: { purges += 1; return 0 },
            invalidate: {}, onInvalidated: {}, sleep: { try await clock.sleep($0) })
        service.start()
        await clock.waitForSleep(count: 1)
        let oldTask = service.stop()
        service.start()
        await clock.waitForSleep(count: 2)
        await clock.wake()
        await oldTask?.value
        #expect(purges == 2)
        let currentTask = service.stop()
        await clock.wake()
        await currentTask?.value
        #expect(purges == 2)
        #expect(!service.isRunning)
    }

    @Test
    func lockContentionRetriesOnlyOnNextTickAndRecoveryClearsFailure() async {
        let clock = MaintenanceTestSleeper()
        var attempts = 0
        let service = ScribePersistentMemoryMaintenance(isAuthorized: { true }, purge: {
            attempts += 1
            if attempts == 1 { throw ScribePersistentMemoryError.storeBusy }
            return 0
        }, invalidate: {}, onInvalidated: {}, sleep: { try await clock.sleep($0) })
        service.start()
        await clock.waitForSleep(count: 1)
        #expect(attempts == 1 && service.lastFailure == .busy)
        await clock.wake()
        await clock.waitForSleep(count: 2)
        #expect(attempts == 2 && service.lastFailure == nil)
        service.stop(); await clock.wake()
    }

    @Test
    func unrecoverableFailureStopsWithoutSchedulingRetry() async {
        let clock = MaintenanceTestSleeper()
        var attempts = 0, invalidations = 0
        let service = ScribePersistentMemoryMaintenance(isAuthorized: { true }, purge: {
            attempts += 1; throw ScribePersistentMemoryError.keyUnavailable
        }, invalidate: { invalidations += 1 }, onInvalidated: {}, sleep: { try await clock.sleep($0) })
        service.start()
        #expect(!service.isRunning && service.lastFailure == .unavailable)
        #expect(attempts == 1 && invalidations == 1)
        #expect(await clock.intervals.isEmpty)
    }
}

private actor MaintenanceTestSleeper {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var intervals: [Duration] = []
    func sleep(_ duration: Duration) async throws {
        intervals.append(duration)
        await withCheckedContinuation { pending.append($0) }
    }
    func waitForSleep(count: Int) async {
        while intervals.count < count || pending.isEmpty { await Task.yield() }
    }
    func wake() { if !pending.isEmpty { pending.removeFirst().resume() } }
}
