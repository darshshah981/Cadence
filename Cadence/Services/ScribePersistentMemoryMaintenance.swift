import Foundation
import OSLog

private let scribeMemoryMaintenanceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribeMemoryMaintenance"
)

/// Opt-in lifecycle driver. The runtime owner must supply current authorization
/// and forward disable/revocation to stop(). No initializer installs a timer or
/// grants retention. All callbacks are content-free and remain on MainActor.
@MainActor
final class ScribePersistentMemoryMaintenance {
    enum Failure: Equatable { case busy, unavailable }
    private(set) var isRunning = false
    private(set) var lastFailure: Failure?
    private let isAuthorized: () -> Bool
    private let purge: () throws -> Int
    private let invalidate: () -> Void
    private let onInvalidated: () -> Void
    private let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var generation = UUID()

    convenience init(store: ScribePersistentMemoryStore, isAuthorized: @escaping () -> Bool,
                     onInvalidated: @escaping () -> Void) {
        self.init(isAuthorized: isAuthorized, purge: { try store.purgeExpired() },
                  invalidate: { store.invalidateOperations() }, onInvalidated: onInvalidated)
    }

    init(isAuthorized: @escaping () -> Bool, purge: @escaping () throws -> Int,
         invalidate: @escaping () -> Void, onInvalidated: @escaping () -> Void,
         interval: Duration = .seconds(60),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        precondition(interval > .zero)
        self.isAuthorized = isAuthorized
        self.purge = purge
        self.invalidate = invalidate
        self.onInvalidated = onInvalidated
        self.interval = interval
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    /// Runs one expiry pass on explicit activation, then periodic passes. An
    /// expired/disabled authorization installs no task and performs no file IO.
    func start() {
        guard !isRunning, isAuthorized() else { return }
        generation = UUID()
        let expected = generation
        isRunning = true
        lastFailure = nil
        guard runCycle(expected: expected) else { return }
        let sleep = sleep, interval = interval
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled, self?.runCycle(expected: expected) == true else { return }
            }
        }
    }

    /// Invalidate outstanding proposals/reads before notifying their consumer.
    /// Disabling maintenance does not claim to delete retained encrypted bytes.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        let wasRunning = isRunning
        let previousTask = task
        isRunning = false
        generation = UUID()
        task?.cancel()
        task = nil
        guard wasRunning else { return previousTask }
        invalidate()
        onInvalidated()
        return previousTask
    }

    private func runCycle(expected: UUID) -> Bool {
        guard isRunning, generation == expected else { return false }
        guard isAuthorized() else { stop(); return false }
        do {
            let removed = try purge()
            lastFailure = nil
            if removed > 0 {
                invalidate()
                onInvalidated()
            }
        } catch ScribePersistentMemoryError.storeBusy {
            // One attempt per interval; contention is not a repair instruction.
            lastFailure = .busy
        } catch {
            lastFailure = .unavailable
            stop()
        }
        return isRunning && generation == expected
    }
}
