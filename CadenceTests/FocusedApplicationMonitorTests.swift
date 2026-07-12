import Foundation
import Testing
@testable import Cadence

@MainActor
struct FocusedApplicationMonitorTests {
    @Test
    func startupSamplesCursorAfterLifecycleSubscription() async {
        let source = FocusedApplicationSourceFake(sample: Self.cursor(pid: 41))
        let monitor = FocusedApplicationMonitor(
            source: source,
            cadenceBundleIdentifiers: ["com.darshshah.Cadence.debug"]
        )

        monitor.start()
        while monitor.currentExternal == nil { await Task.yield() }

        #expect(source.eventsCallCount == 1)
        #expect(source.callOrder.prefix(2) == ["events", "sample"])
        #expect(monitor.currentExternal?.process.bundleIdentifier == "com.todesktop.230313mzl4w4u92")
        #expect(monitor.history.count == 1)
        monitor.stop()
        #expect(source.stopCount == 1)
    }

    @Test
    func cadenceFocusClearsCurrentButPreservesHistoryAndHistoryIsNeverCaptureAuthority() async throws {
        let source = FocusedApplicationSourceFake(sample: Self.cursor(pid: 42))
        let monitor = FocusedApplicationMonitor(
            source: source,
            cadenceBundleIdentifiers: ["com.darshshah.Cadence.debug"]
        )
        monitor.start()
        while monitor.currentExternal == nil { await Task.yield() }
        source.sample = Self.cadence(pid: 1)
        source.send(.activated)
        while monitor.currentExternal != nil { await Task.yield() }

        #expect(monitor.history.first?.process.bundleIdentifier == "com.todesktop.230313mzl4w4u92")
        await #expect(throws: ApplicationTargetAuthorityError.noExternalTarget) {
            _ = try await monitor.captureTarget(source: .dictation)
        }
        monitor.stop()
    }

    @Test
    func terminationClearsExactIncarnationAndSamePIDRelaunchGetsNewIncarnation() async {
        let initial = Self.cursor(pid: 44, launchDate: Date(timeIntervalSince1970: 10))
        let source = FocusedApplicationSourceFake(sample: initial)
        let monitor = FocusedApplicationMonitor(source: source, cadenceBundleIdentifiers: [])
        monitor.start()
        while monitor.currentExternal == nil { await Task.yield() }
        let oldIncarnation = monitor.currentExternal?.process.incarnation
        source.sample = nil
        source.send(.terminated(
            processIdentifier: initial.processIdentifier,
            bundleIdentifier: initial.bundleIdentifier,
            bundleURL: initial.bundleURL,
            launchDate: initial.launchDate
        ))
        while monitor.currentExternal != nil { await Task.yield() }
        source.sample = Self.cursor(pid: 44, launchDate: Date(timeIntervalSince1970: 20))
        source.send(.launched(source.sample!))
        while monitor.currentExternal == nil { await Task.yield() }

        #expect(monitor.currentExternal?.process.incarnation != oldIncarnation)
        monitor.stop()
    }

    @Test
    func staleAsyncSampleCannotOverrideNewerActivation() async {
        let gate = FocusedSampleGate()
        let source = FocusedApplicationSourceFake(sample: Self.cursor(pid: 50))
        source.gate = gate
        let monitor = FocusedApplicationMonitor(source: source, cadenceBundleIdentifiers: [])
        monitor.start()
        await gate.waitUntilEntered()
        source.gate = nil
        source.sample = Self.slack(pid: 51)
        source.send(.activated)
        while monitor.currentExternal?.process.processIdentifier != 51 { await Task.yield() }
        await gate.release()
        for _ in 0..<20 { await Task.yield() }

        #expect(monitor.currentExternal?.process.processIdentifier == 51)
        monitor.stop()
    }

    @Test
    func lifecycleEventInvalidatesAuthorityBeforeReplacementSampleCompletes() async {
        let source = FocusedApplicationSourceFake(sample: Self.cursor(pid: 52))
        let monitor = FocusedApplicationMonitor(source: source, cadenceBundleIdentifiers: [])
        let authority = ApplicationTargetAuthority(monitor: monitor)
        monitor.start()
        while monitor.currentExternal == nil { await Task.yield() }
        let capture = ApplicationTargetCapture(
            process: monitor.currentExternal!.process,
            identityRevision: monitor.currentExternal!.identityRevision,
            captureRevision: 1,
            source: .dictation
        )

        let gate = FocusedSampleGate()
        source.gate = gate
        source.sample = Self.slack(pid: 53)
        source.send(.activated)
        await gate.waitUntilEntered()

        #expect(authority.matchesCurrent(capture.process) == false)
        await gate.release()
        monitor.stop()
    }

    @Test
    func atomicCaptureRejectsFocusRaceBetweenCandidateAndConfirmation() async {
        let source = FocusedApplicationSourceFake(sample: Self.cursor(pid: 60))
        let monitor = FocusedApplicationMonitor(source: source, cadenceBundleIdentifiers: [])
        monitor.start()
        while monitor.currentExternal == nil { await Task.yield() }
        source.sampleQueue = [Self.cursor(pid: 60), Self.slack(pid: 61)]

        await #expect(throws: ApplicationTargetAuthorityError.targetChanged) {
            _ = try await monitor.captureTarget(source: .dictation)
        }
        monitor.stop()
    }

    @Test
    func verificationOfUnchangedProcessDoesNotRepublishOrBumpRevisions() async throws {
        let source = FocusedApplicationSourceFake(sample: Self.cursor(pid: 62))
        let monitor = FocusedApplicationMonitor(source: source, cadenceBundleIdentifiers: [])
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        monitor.start()
        while monitor.currentExternal == nil { await Task.yield() }
        let capture = try await monitor.captureTarget(source: .dictation)
        let identityRevision = monitor.identityRevision
        let presentationRevision = monitor.presentationRevision
        let changeCount = changes

        try await monitor.verify(capture)

        #expect(monitor.identityRevision == identityRevision)
        #expect(monitor.presentationRevision == presentationRevision)
        #expect(changes == changeCount)
        monitor.stop()
    }

    @Test
    func pidOnlyTerminationClearsCurrentAndReportsExactKnownIncarnation() async {
        let source = FocusedApplicationSourceFake(sample: Self.cursor(pid: 63))
        let monitor = FocusedApplicationMonitor(source: source, cadenceBundleIdentifiers: [])
        var terminated: ApplicationProcessIdentity?
        monitor.onTermination = { identity, _, _, _ in terminated = identity }
        monitor.start()
        while monitor.currentExternal == nil { await Task.yield() }
        let expected = monitor.currentExternal?.process
        source.sample = nil
        source.send(.terminated(
            processIdentifier: 63,
            bundleIdentifier: nil,
            bundleURL: nil,
            launchDate: nil
        ))
        while monitor.currentExternal != nil { await Task.yield() }

        #expect(terminated == expected)
        monitor.stop()
    }

    private static func cursor(pid: Int32, launchDate: Date = Date(timeIntervalSince1970: 1)) -> FocusedApplicationSample {
        .init(
            processIdentifier: pid, bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            bundleURL: URL(fileURLWithPath: "/Applications/Cursor.app"),
            displayName: "Cursor", launchDate: launchDate
        )
    }

    private static func slack(pid: Int32) -> FocusedApplicationSample {
        .init(
            processIdentifier: pid, bundleIdentifier: "com.tinyspeck.slackmacgap",
            bundleURL: URL(fileURLWithPath: "/Applications/Slack.app"),
            displayName: "Slack", launchDate: Date(timeIntervalSince1970: 2)
        )
    }

    private static func cadence(pid: Int32) -> FocusedApplicationSample {
        .init(
            processIdentifier: pid, bundleIdentifier: "com.darshshah.Cadence.debug",
            bundleURL: URL(fileURLWithPath: "/Applications/Cadence Debug.app"),
            displayName: "Cadence Debug", launchDate: Date(timeIntervalSince1970: 1)
        )
    }
}

@MainActor
private final class FocusedApplicationSourceFake: FocusedApplicationSource, @unchecked Sendable {
    var sample: FocusedApplicationSample?
    var gate: FocusedSampleGate?
    var sampleQueue: [FocusedApplicationSample?] = []
    private let stream: AsyncStream<FocusedApplicationEvent>
    private let continuation: AsyncStream<FocusedApplicationEvent>.Continuation
    private(set) var eventsCallCount = 0
    private(set) var stopCount = 0
    private(set) var callOrder: [String] = []
    init(sample: FocusedApplicationSample?) {
        self.sample = sample
        let pair = AsyncStream.makeStream(of: FocusedApplicationEvent.self)
        stream = pair.stream
        continuation = pair.continuation
    }
    func events() -> AsyncStream<FocusedApplicationEvent> {
        eventsCallCount += 1
        callOrder.append("events")
        return stream
    }
    func frontmostSample() async -> FocusedApplicationSample? {
        callOrder.append("sample")
        let captured = sampleQueue.isEmpty ? sample : sampleQueue.removeFirst()
        if let gate { await gate.wait() }
        return captured
    }
    func activate(_ identity: ApplicationProcessIdentity) -> Bool { true }
    func stop() { stopCount += 1; continuation.finish() }
    func send(_ event: FocusedApplicationEvent) { continuation.yield(event) }
}

private actor FocusedSampleGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}
