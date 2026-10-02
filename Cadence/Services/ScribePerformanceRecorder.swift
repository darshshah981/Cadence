import Foundation
import OSLog

private let scribePerformanceRecorderLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ScribePerformanceRecorder"
)

/// A monotonic measurement seam. It is deliberately independent of wall-clock
/// time so tests can control it and samples reveal no time-of-day information.
protocol ScribePerformanceClock: Sendable {
    func nowNanoseconds() -> UInt64
}

struct SystemScribePerformanceClock: ScribePerformanceClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() { origin = clock.now }

    func nowNanoseconds() -> UInt64 {
        let components = origin.duration(to: clock.now).components
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}

/// An explicit developer/test destination. Production callers receive no
/// persistence, analytics, logging, or network behavior from this protocol.
@MainActor
protocol ScribePerformanceSampleSink: AnyObject {
    func record(_ sample: ScribePerformanceSample)
}

@MainActor
final class ScribePerformanceSampleBuffer: ScribePerformanceSampleSink {
    private(set) var samples: [ScribePerformanceSample] = []
    private let maximumSamples: Int

    init(maximumSamples: Int = 200) {
        self.maximumSamples = max(1, maximumSamples)
    }

    func record(_ sample: ScribePerformanceSample) {
        samples.append(sample)
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    func summary() -> ScribePerformanceTimingSummary {
        let totals = samples.map(\.totalElapsedNanoseconds).sorted()
        guard !totals.isEmpty else {
            return .init(sampleCount: 0, p50Nanoseconds: nil, p95Nanoseconds: nil)
        }
        func percentile(_ fraction: Double) -> UInt64 {
            totals[min(totals.count - 1, Int(ceil(Double(totals.count) * fraction)) - 1)]
        }
        return .init(sampleCount: totals.count, p50Nanoseconds: percentile(0.5), p95Nanoseconds: percentile(0.95))
    }
}

/// Records action-local timing samples when an explicit sink is supplied.
/// A recorder with no sink is a no-op. These measurements are a verification
/// seam, not evidence that a performance target or user-visible improvement met.
@MainActor
final class ScribePerformanceRecorder {
    private struct ActiveAction {
        let startedAt: UInt64
        var lastStageIndex = -1
        var timings: [ScribePerformanceStageTiming] = []
    }

    private let clock: any ScribePerformanceClock
    private weak var sink: (any ScribePerformanceSampleSink)?
    private var activeActions: [UUID: ActiveAction] = [:]

    init(
        clock: any ScribePerformanceClock = SystemScribePerformanceClock(),
        sink: (any ScribePerformanceSampleSink)? = nil
    ) {
        self.clock = clock
        self.sink = sink
    }

    var isEnabled: Bool { sink != nil }

    func begin(actionID: UUID) {
        guard isEnabled else { return }
        // Compose owns one acquisition at a time. Preserve an interrupted
        // action as cancellation instead of retaining timing state that a
        // later callback could contaminate.
        if activeActions[actionID] != nil { return }
        if let previousActionID = activeActions.keys.first {
            finish(actionID: previousActionID, outcome: .cancelled)
        }
        activeActions[actionID] = ActiveAction(startedAt: clock.nowNanoseconds())
    }

    func mark(_ stage: ScribePerformanceStage, actionID: UUID) {
        guard var active = activeActions[actionID],
              let stageIndex = ScribePerformanceStage.allCases.firstIndex(of: stage),
              stageIndex > active.lastStageIndex else {
            return
        }
        active.timings.append(.init(stage: stage, elapsedNanoseconds: elapsed(since: active.startedAt)))
        active.lastStageIndex = stageIndex
        activeActions[actionID] = active
    }

    func finish(actionID: UUID, outcome: ScribePerformanceTerminalOutcome) {
        guard let active = activeActions.removeValue(forKey: actionID) else { return }
        guard let sink else { return }
        sink.record(.init(actionID: actionID, stages: active.timings, terminalOutcome: outcome,
                          totalElapsedNanoseconds: elapsed(since: active.startedAt)))
    }

    func elapsedNanoseconds(for stage: ScribePerformanceStage, actionID: UUID) -> UInt64? {
        activeActions[actionID]?.timings.first(where: { $0.stage == stage })?.elapsedNanoseconds
    }

    func cancel(actionID: UUID) {
        finish(actionID: actionID, outcome: .cancelled)
    }

    private func elapsed(since start: UInt64) -> UInt64 {
        let now = clock.nowNanoseconds()
        if now < start {
            scribePerformanceRecorderLogger.debug("Ignoring monotonic clock regression in content-free timing sample")
            return 0
        }
        return now - start
    }
}
