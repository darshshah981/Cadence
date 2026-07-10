import AppKit
import Foundation
import Testing
@testable import Cadence

struct SelectionCaptureServiceTests {
    @Test
    @MainActor
    func accessibilitySelectionIsTrimmedAndPreferred() throws {
        let service = SelectionCaptureService(
            accessibilityReader: StubAccessibilitySelectionReader(value: "  Cadence term\n"),
            clipboardReader: StubClipboardTextReader(value: "stale clipboard")
        )

        #expect(try service.capture() == SelectionCapture(text: "Cadence term", source: .accessibility))
    }

    @Test
    @MainActor
    func clipboardFallbackIsUsedWhenAccessibilityIsEmptyOrUnavailable() throws {
        let emptyService = SelectionCaptureService(
            accessibilityReader: StubAccessibilitySelectionReader(value: " \n"),
            clipboardReader: StubClipboardTextReader(value: " Clipboard term ")
        )
        let failedService = SelectionCaptureService(
            accessibilityReader: StubAccessibilitySelectionReader(error: .unavailable),
            clipboardReader: StubClipboardTextReader(value: "Fallback")
        )

        #expect(try emptyService.capture() == SelectionCapture(text: "Clipboard term", source: .clipboard))
        #expect(try failedService.capture() == SelectionCapture(text: "Fallback", source: .clipboard))
    }

    @Test
    @MainActor
    func whitespaceAcrossBothSourcesReturnsNothing() throws {
        let service = SelectionCaptureService(
            accessibilityReader: StubAccessibilitySelectionReader(value: "  "),
            clipboardReader: StubClipboardTextReader(value: "\n\t")
        )

        #expect(try service.capture() == nil)
    }

    @Test
    @MainActor
    func bothUnavailableSurfacesCoarseFailure() {
        let service = SelectionCaptureService(
            accessibilityReader: StubAccessibilitySelectionReader(error: .unavailable),
            clipboardReader: StubClipboardTextReader(error: .unavailable)
        )

        #expect(throws: SelectionCaptureError.unavailable) {
            try service.capture()
        }
    }

    @Test
    func vocabularyAppenderPreservesExistingEntriesAndRejectsWhitespace() {
        #expect(VocabularyTextAppender.appending(" New term ", to: "Existing") == "Existing\nNew term")
        #expect(VocabularyTextAppender.appending("New term", to: " \n") == "New term")
        #expect(VocabularyTextAppender.appending(" \n", to: "Existing") == nil)
    }

    @Test
    @MainActor
    func dictionaryAnalyticsContainsOnlyCoarseOutcome() {
        let sink = HUDCapturingAnalyticsSink()
        let analytics = AnalyticsService(isEnabled: true, sink: sink)

        analytics.track(
            "dictionary_capture_completed",
            properties: DictionaryCaptureOutcome.added.analyticsProperties
        )

        #expect(sink.events.count == 1)
        #expect(sink.events.first?.properties == ["outcome": .string("added")])
    }
}

struct HUDVisibilityServiceTests {
    @Test
    @MainActor
    func timedHidePersistsExactExpiryAndRestoresOnRefresh() {
        let fixture = HUDVisibilityFixture()
        fixture.controller.hide(for: .tenMinutes)

        #expect(fixture.controller.state == .hidden(until: fixture.start.addingTimeInterval(600)))
        #expect(fixture.store.load(now: fixture.start) == fixture.controller.state)

        fixture.clock.value = fixture.start.addingTimeInterval(600)
        fixture.controller.refresh()
        #expect(fixture.controller.state == .visible)
        #expect(fixture.store.load(now: fixture.clock.value) == .visible)
    }

    @Test
    @MainActor
    func scheduledExpiryRestoresWithoutManualShow() async {
        let sleeper = ManualHUDVisibilitySleeper()
        let fixture = HUDVisibilityFixture(sleeper: sleeper)
        var states: [HUDVisibilityState] = []
        fixture.controller.onChange = { states.append($0) }
        fixture.controller.hide(for: .tenMinutes)

        await sleeper.waitUntilRequested()
        fixture.clock.value = fixture.start.addingTimeInterval(600)
        await sleeper.wake()
        for _ in 0..<10 where fixture.controller.state != .visible {
            await Task.yield()
        }

        #expect(fixture.controller.state == .visible)
        #expect(states == [.hidden(until: fixture.start.addingTimeInterval(600)), .visible])
    }

    @Test
    @MainActor
    func untilNextSessionSurvivesDictationStateButNotRelaunch() {
        let fixture = HUDVisibilityFixture()
        fixture.controller.hide(for: .untilNextSession)

        #expect(fixture.controller.state == .hiddenUntilRelaunch)
        #expect(HUDIdleVisibilityPolicy.shouldPresent(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            idleBarVisible: fixture.controller.state.showsIdleBar
        ))
        #expect(!HUDIdleVisibilityPolicy.shouldPresent(
            visualState: .idle,
            idleBarVisible: fixture.controller.state.showsIdleBar
        ))

        let relaunched = HUDVisibilityController(
            store: HUDVisibilityStore(defaults: fixture.defaults),
            clock: fixture.clock,
            sleeper: LongHUDVisibilitySleeper()
        )
        #expect(relaunched.state == .visible)
    }

    @Test
    @MainActor
    func immediateShowClearsAnyHide() {
        let fixture = HUDVisibilityFixture()
        fixture.controller.hide(for: .oneHour)
        fixture.controller.show()

        #expect(fixture.controller.state == .visible)
        #expect(fixture.store.load(now: fixture.start) == .visible)
    }

    @Test
    func permissionPolicyHidesOnlyIdleBar() {
        #expect(HUDIdleVisibilityPolicy.showsIdleBar(visibility: .visible, permissionsGranted: true))
        #expect(!HUDIdleVisibilityPolicy.showsIdleBar(visibility: .visible, permissionsGranted: false))
        #expect(!HUDIdleVisibilityPolicy.showsIdleBar(
            visibility: .hiddenUntilRelaunch,
            permissionsGranted: true
        ))
        #expect(HUDIdleVisibilityPolicy.shouldPresent(
            visualState: .transcribing,
            idleBarVisible: false
        ))
        #expect(!HUDIdleVisibilityPolicy.shouldPresent(
            visualState: .idle,
            idleBarVisible: false
        ))
    }
}

private struct StubAccessibilitySelectionReader: AccessibilitySelectionReading {
    let value: String?
    let error: SelectionCaptureError?

    init(value: String? = nil, error: SelectionCaptureError? = nil) {
        self.value = value
        self.error = error
    }

    func selectedText() throws -> String? {
        if let error { throw error }
        return value
    }
}

private struct StubClipboardTextReader: ClipboardTextReading {
    let value: String?
    let error: SelectionCaptureError?

    init(value: String? = nil, error: SelectionCaptureError? = nil) {
        self.value = value
        self.error = error
    }

    func clipboardText() throws -> String? {
        if let error { throw error }
        return value
    }
}

private final class HUDCapturingAnalyticsSink: AnalyticsSink, @unchecked Sendable {
    private(set) var events: [AnalyticsEvent] = []

    func send(_ event: AnalyticsEvent) {
        events.append(event)
    }
}

private final class MutableHUDVisibilityClock: HUDVisibilityClock, @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { value }
}

private struct LongHUDVisibilitySleeper: HUDVisibilitySleeping {
    func sleep(until date: Date) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

private actor ManualHUDVisibilitySleeper: HUDVisibilitySleeping {
    private var continuation: CheckedContinuation<Void, Error>?

    func sleep(until date: Date) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequested() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func wake() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class HUDVisibilityFixture {
    let suiteName = "HUDVisibilityServiceTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let start = Date(timeIntervalSince1970: 1_000)
    let clock: MutableHUDVisibilityClock
    let store: HUDVisibilityStore
    let controller: HUDVisibilityController

    init(sleeper: HUDVisibilitySleeping = LongHUDVisibilitySleeper()) {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        clock = MutableHUDVisibilityClock(start)
        store = HUDVisibilityStore(defaults: defaults)
        controller = HUDVisibilityController(store: store, clock: clock, sleeper: sleeper)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
