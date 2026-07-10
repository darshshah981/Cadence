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

struct HUDVisualGeometryTests {
    private let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let visible = NSRect(x: 0, y: 70, width: 1920, height: 986)

    @Test
    func visibleMarkIsThirtyPercentSmallerInsideFullHitTarget() {
        #expect(HUDMetrics.idleHitSize == NSSize(width: 44, height: 44))
        #expect(HUDMetrics.idleMarkSize == NSSize(width: 31, height: 31))
        #expect(HUDMetrics.idleMarkSize.width == (HUDMetrics.idleHitSize.width * 0.7).rounded())
    }

    @Test
    func visibleMarkRemainsFlushWithEveryAttachedEdge() {
        for position in HUDPosition.allCases {
            let panel = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDMetrics.idleHitSize
            )
            let mark = position.visibleMarkFrame(in: panel)
            #expect(mark.size == HUDMetrics.idleMarkSize)
            switch position {
            case .bottomCenter:
                #expect(mark.midX == panel.midX)
                #expect(mark.minY == visible.minY)
            case .topLeft:
                #expect(mark.minX == screen.minX)
                #expect(mark.maxY == visible.maxY)
            case .topRight:
                #expect(mark.maxX == screen.maxX)
                #expect(mark.maxY == visible.maxY)
            case .bottomLeft:
                #expect(mark.minX == screen.minX)
                #expect(mark.minY == screen.minY)
            case .bottomRight:
                #expect(mark.maxX == screen.maxX)
                #expect(mark.minY == screen.minY)
            }
        }
    }

    @Test
    func expansionPreservesEveryPositionAnchor() {
        for position in HUDPosition.allCases {
            let collapsed = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDMetrics.idleHitSize
            )
            let expanded = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDMetrics.expandedTraySize
            )
            switch position {
            case .bottomCenter:
                #expect(collapsed.midX == expanded.midX)
                #expect(collapsed.minY == expanded.minY)
                #expect(collapsed.minX - expanded.minX == expanded.maxX - collapsed.maxX)
            case .topLeft:
                #expect(collapsed.minX == expanded.minX)
                #expect(collapsed.maxY == expanded.maxY)
            case .topRight:
                #expect(collapsed.maxX == expanded.maxX)
                #expect(collapsed.maxY == expanded.maxY)
            case .bottomLeft:
                #expect(collapsed.minX == expanded.minX)
                #expect(collapsed.minY == expanded.minY)
            case .bottomRight:
                #expect(collapsed.maxX == expanded.maxX)
                #expect(collapsed.minY == expanded.minY)
            }
        }
    }

    @Test
    func interpolatedMorphFramesPreserveAttachedEdges() {
        for position in HUDPosition.allCases {
            let start = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDMetrics.idleHitSize
            )
            let end = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDMetrics.expandedTraySize
            )
            let middle = HUDPanelLayout.interpolate(from: start, to: end, progress: 0.5)
            switch position {
            case .bottomCenter:
                #expect(middle.midX == start.midX)
                #expect(middle.minY == start.minY)
            case .topLeft:
                #expect(middle.minX == start.minX)
                #expect(middle.maxY == start.maxY)
            case .topRight:
                #expect(middle.maxX == start.maxX)
                #expect(middle.maxY == start.maxY)
            case .bottomLeft:
                #expect(middle.minX == start.minX)
                #expect(middle.minY == start.minY)
            case .bottomRight:
                #expect(middle.maxX == start.maxX)
                #expect(middle.minY == start.minY)
            }
        }
    }

    @Test
    func subtitleStaysInsideScreenSideOfAttachedPill() {
        let topPill = HUDPanelLayout.targetFrame(
            position: .topLeft,
            screenFrame: screen,
            visibleFrame: visible,
            size: NSSize(width: HUDMetrics.statusWidth, height: HUDMetrics.pillHeight)
        )
        let bottomPill = HUDPanelLayout.targetFrame(
            position: .bottomCenter,
            screenFrame: screen,
            visibleFrame: visible,
            size: NSSize(width: HUDMetrics.statusWidth, height: HUDMetrics.pillHeight)
        )

        #expect(HUDPanelLayout.subtitleOrigin(position: .topLeft, pillFrame: topPill).y < topPill.minY)
        #expect(HUDPanelLayout.subtitleOrigin(position: .bottomCenter, pillFrame: bottomPill).y > bottomPill.maxY)
    }

    @Test
    func dropRectsMatchVisibleMarkAtActualSnapDestinations() {
        for position in HUDPosition.allCases {
            let rect = HUDDropZoneGeometry.canvasRect(
                for: position,
                screenFrame: screen,
                visibleFrame: visible
            )
            #expect(rect.size == HUDMetrics.idleMarkSize)
        }
        #expect(HUDDropZoneGeometry.canvasRect(
            for: .topLeft,
            screenFrame: screen,
            visibleFrame: visible
        ) == CGRect(x: 0, y: 24, width: 31, height: 31))
        #expect(HUDDropZoneGeometry.canvasRect(
            for: .bottomCenter,
            screenFrame: screen,
            visibleFrame: visible
        ) == CGRect(x: 944.5, y: 979, width: 31, height: 31))
    }

    @Test
    func dropRectConversionSupportsNegativeOriginScreens() {
        let negativeScreen = NSRect(x: -1440, y: 100, width: 1440, height: 900)
        let negativeVisible = NSRect(x: -1440, y: 100, width: 1440, height: 876)

        #expect(HUDDropZoneGeometry.canvasRect(
            for: .topRight,
            screenFrame: negativeScreen,
            visibleFrame: negativeVisible
        ) == CGRect(x: 1409, y: 24, width: 31, height: 31))
    }

    @Test
    func idleToHoldMorphPreservesAnchorsAtEveryPosition() {
        assertMorphAnchors(
            from: HUDPresentation(visualState: .idle, isExpanded: false),
            to: HUDPresentation(visualState: .recording(triggerMode: .holdToTalk, showsHint: true), isExpanded: false)
        )
    }

    @Test
    func idleToLockedMorphPreservesAnchorsAtEveryPosition() {
        assertMorphAnchors(
            from: HUDPresentation(visualState: .idle, isExpanded: false),
            to: HUDPresentation(visualState: .recording(triggerMode: .tapToStartStop, showsHint: false), isExpanded: false)
        )
    }

    @Test
    func idleToStatusMorphPreservesAnchorsAtEveryPosition() {
        assertMorphAnchors(
            from: HUDPresentation(visualState: .idle, isExpanded: false),
            to: HUDPresentation(visualState: .transcribing, isExpanded: false)
        )
    }

    @Test
    func statusToIdleMorphPreservesAnchorsAtEveryPosition() {
        assertMorphAnchors(
            from: HUDPresentation(visualState: .success, isExpanded: false),
            to: HUDPresentation(visualState: .idle, isExpanded: false)
        )
    }

    @Test
    func idleToExpandedContentStaysAttachedThroughoutMorph() {
        assertContentAttachments(
            from: HUDPresentation(visualState: .idle, isExpanded: false),
            to: HUDPresentation(visualState: .idle, isExpanded: true)
        )
    }

    @Test
    func idleToHoldContentStaysAttachedThroughoutMorph() {
        assertContentAttachments(
            from: HUDPresentation(visualState: .idle, isExpanded: false),
            to: HUDPresentation(visualState: .recording(triggerMode: .holdToTalk, showsHint: true), isExpanded: false)
        )
    }

    @Test
    func idleToLockedContentStaysAttachedThroughoutMorph() {
        assertContentAttachments(
            from: HUDPresentation(visualState: .idle, isExpanded: false),
            to: HUDPresentation(visualState: .recording(triggerMode: .tapToStartStop, showsHint: false), isExpanded: false)
        )
    }

    @Test
    func statusToIdleContentStaysAttachedThroughoutMorph() {
        assertContentAttachments(
            from: HUDPresentation(visualState: .success, isExpanded: false),
            to: HUDPresentation(visualState: .idle, isExpanded: false)
        )
    }

    @Test
    func teachingTooltipUsesInsideFacingSideAndClampsToVisibleScreen() {
        let tooltipSize = NSSize(width: 200, height: 40)
        for position in HUDPosition.allCases {
            let pill = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDMetrics.idleHitSize
            )
            let origin = HUDTooltipGeometry.origin(
                position: position,
                pillFrame: pill,
                tooltipSize: tooltipSize,
                visibleFrame: visible
            )
            #expect(origin.x >= visible.minX)
            #expect(origin.x + tooltipSize.width <= visible.maxX)
            switch position {
            case .topLeft, .topRight:
                #expect(origin.y + tooltipSize.height < pill.minY)
            case .bottomCenter, .bottomLeft, .bottomRight:
                #expect(origin.y > pill.maxY)
            }
        }

        let leftPill = HUDPanelLayout.targetFrame(
            position: .topLeft,
            screenFrame: screen,
            visibleFrame: visible,
            size: HUDMetrics.idleHitSize
        )
        let rightPill = HUDPanelLayout.targetFrame(
            position: .topRight,
            screenFrame: screen,
            visibleFrame: visible,
            size: HUDMetrics.idleHitSize
        )
        #expect(HUDTooltipGeometry.origin(
            position: .topLeft,
            pillFrame: leftPill,
            tooltipSize: tooltipSize,
            visibleFrame: visible
        ).x == visible.minX)
        #expect(HUDTooltipGeometry.origin(
            position: .topRight,
            pillFrame: rightPill,
            tooltipSize: tooltipSize,
            visibleFrame: visible
        ).x == visible.maxX - tooltipSize.width)
    }

    @Test
    func screenChangesRepositionOnlyVisibleFrameDependentAnchors() {
        #expect(HUDScreenChangePolicy.shouldReposition(.bottomCenter))
        #expect(HUDScreenChangePolicy.shouldReposition(.topLeft))
        #expect(HUDScreenChangePolicy.shouldReposition(.topRight))
        #expect(!HUDScreenChangePolicy.shouldReposition(.bottomLeft))
        #expect(!HUDScreenChangePolicy.shouldReposition(.bottomRight))
    }

    private func assertMorphAnchors(from: HUDPresentation, to: HUDPresentation) {
        for position in HUDPosition.allCases {
            let start = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDPanelLayout.size(for: from)
            )
            let end = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDPanelLayout.size(for: to)
            )
            let middle = HUDPanelLayout.interpolate(from: start, to: end, progress: 0.5)
            switch position {
            case .bottomCenter:
                #expect(start.midX == end.midX)
                #expect(middle.midX == end.midX)
                #expect(start.minY == end.minY && middle.minY == end.minY)
            case .topLeft:
                #expect(start.minX == end.minX && middle.minX == end.minX)
                #expect(start.maxY == end.maxY && middle.maxY == end.maxY)
            case .topRight:
                #expect(start.maxX == end.maxX && middle.maxX == end.maxX)
                #expect(start.maxY == end.maxY && middle.maxY == end.maxY)
            case .bottomLeft:
                #expect(start.minX == end.minX && middle.minX == end.minX)
                #expect(start.minY == end.minY && middle.minY == end.minY)
            case .bottomRight:
                #expect(start.maxX == end.maxX && middle.maxX == end.maxX)
                #expect(start.minY == end.minY && middle.minY == end.minY)
            }
        }
    }

    private func assertContentAttachments(from: HUDPresentation, to: HUDPresentation) {
        let startSize = HUDPanelLayout.size(for: from)
        let endSize = HUDPanelLayout.size(for: to)
        for position in HUDPosition.allCases {
            let start = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: startSize
            )
            let end = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: endSize
            )
            for progress in [0.0, 0.5, 1.0] {
                let panel = HUDPanelLayout.interpolate(from: start, to: end, progress: progress)
                for contentSize in [startSize, endSize] {
                    let localOrigin = HUDContentAttachment.appKitOrigin(
                        position: position,
                        contentSize: contentSize,
                        containerSize: panel.size
                    )
                    let content = NSRect(
                        x: panel.minX + localOrigin.x,
                        y: panel.minY + localOrigin.y,
                        width: contentSize.width,
                        height: contentSize.height
                    )
                    assertAttached(content: content, to: panel, at: position)
                }
            }
        }
    }

    private func assertAttached(content: NSRect, to panel: NSRect, at position: HUDPosition) {
        switch position {
        case .bottomCenter:
            #expect(content.midX == panel.midX)
            #expect(content.minY == panel.minY)
        case .topLeft:
            #expect(content.minX == panel.minX)
            #expect(content.maxY == panel.maxY)
        case .topRight:
            #expect(content.maxX == panel.maxX)
            #expect(content.maxY == panel.maxY)
        case .bottomLeft:
            #expect(content.minX == panel.minX)
            #expect(content.minY == panel.minY)
        case .bottomRight:
            #expect(content.maxX == panel.maxX)
            #expect(content.minY == panel.minY)
        }
    }
}

struct HUDAnimationClockTests {
    @Test
    func waveformAttackIsFrameRateIndependentAt60And120Hz() {
        let sixty = advanceWaveform(from: 0, to: 1, framesPerSecond: 60, seconds: 0.5)
        let oneTwenty = advanceWaveform(from: 0, to: 1, framesPerSecond: 120, seconds: 0.5)

        #expect(abs(sixty - oneTwenty) < 0.000_001)
    }

    @Test
    func waveformReleaseIsFrameRateIndependentAt60And120Hz() {
        let sixty = advanceWaveform(from: 1, to: 0, framesPerSecond: 60, seconds: 0.5)
        let oneTwenty = advanceWaveform(from: 1, to: 0, framesPerSecond: 120, seconds: 0.5)

        #expect(abs(sixty - oneTwenty) < 0.000_001)
    }

    @Test
    func displayRefreshPolicyUsesActualMaximumFrameRate() {
        let promotion = HUDDisplayRefreshPolicy.preferredRange(maximumFramesPerSecond: 120)
        let standard = HUDDisplayRefreshPolicy.preferredRange(maximumFramesPerSecond: 60)

        #expect(promotion.maximum == 120)
        #expect(promotion.preferred == 120)
        #expect(promotion.minimum == 60)
        #expect(standard.maximum == 60)
        #expect(standard.preferred == 60)
    }

    @Test
    @MainActor
    func waveformRequestsFramesOnlyUntilStable() {
        let model = HUDViewModel()
        model.reduceMotionProvider = { false }
        var requestCount = 0
        model.onAnimationRequested = { requestCount += 1 }
        model.apply(HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "",
            level: 0.5,
            waveformLevels: Array(repeating: 0.5, count: 16),
            isVisible: true,
            showsSubtitle: false
        ))

        #expect(requestCount == 1)
        var needsFrames = true
        for _ in 0..<600 where needsFrames {
            needsFrames = model.advanceWaveform(deltaTime: 1 / 120)
        }
        #expect(!needsFrames)
        #expect(!model.hasPendingWaveformAnimation)
    }

    @Test
    @MainActor
    func reducedMotionAppliesResponsiveAudioWithoutInterpolation() {
        let model = HUDViewModel()
        model.reduceMotionProvider = { true }
        model.apply(HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "",
            level: 0.7,
            waveformLevels: Array(repeating: 0.7, count: 16),
            isVisible: true,
            showsSubtitle: false
        ))

        #expect(model.displayBars == Array(repeating: 0.7, count: 16))
        #expect(!model.hasPendingWaveformAnimation)
    }

    @Test
    @MainActor
    func reducedMotionFinishesActiveContentMorphImmediately() {
        let model = HUDViewModel()
        let idle = HUDPresentation(visualState: .idle, isExpanded: false)
        model.beginMorph(from: idle)
        model.onReducedMotionChanged = { reduced in
            if reduced { model.finishMorph() }
        }

        model.setReducedMotion(true)

        #expect(model.previousPresentation == nil)
        #expect(model.morphProgress == 1)
    }

    @Test
    @MainActor
    func expandedPresentationExposesButtonAccessibilityInsteadOfRootSummary() {
        let model = HUDViewModel()
        model.apply(.logoIdle)
        #expect(!model.presentation.exposesInteractiveChildren)
        model.setExpanded(true)
        #expect(model.presentation.exposesInteractiveChildren)
    }

    private func advanceWaveform(
        from initial: Double,
        to target: Double,
        framesPerSecond: Int,
        seconds: Double
    ) -> Double {
        var value = initial
        for _ in 0..<Int(Double(framesPerSecond) * seconds) {
            value = HUDWaveformSmoother.step(
                current: value,
                target: target,
                deltaTime: 1 / Double(framesPerSecond)
            )
        }
        return value
    }
}

struct HUDReleaseHardeningTests {
    @Test
    @MainActor
    func activationFeedbackFiresOncePerListeningSessionOnly() {
        let service = HardeningCapturingFeedbackService()
        let gate = DictationActivationFeedbackGate(service: service)

        gate.handle(.listeningStarted)
        gate.handle(.audioUpdated)
        gate.handle(.audioUpdated)
        gate.handle(.listeningStarted)
        #expect(service.activationCount == 1)

        gate.handle(.stopped)
        gate.handle(.cancelled)
        gate.handle(.failed)
        #expect(service.activationCount == 1)

        gate.handle(.listeningStarted)
        #expect(service.activationCount == 2)
    }

    @Test
    @MainActor
    func soundPreferenceDefaultsOnAndPersistsIntoInjectedService() {
        let suite = "HUDReleaseHardening.sound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HardeningCapturingFeedbackService()

        #expect(DictationSoundFeedbackPreference.load(from: defaults))
        DictationSoundFeedbackPreference.set(false, defaults: defaults, service: service)
        #expect(!DictationSoundFeedbackPreference.load(from: defaults))
        #expect(defaults.object(forKey: DictationSoundFeedbackPreference.key) as? Bool == false)
        #expect(!service.isEnabled)

        DictationSoundFeedbackPreference.set(true, defaults: defaults, service: service)
        #expect(DictationSoundFeedbackPreference.load(from: defaults))
        #expect(service.isEnabled)
    }

    @Test
    func dragTooltipEligibilityCoversThresholdAndShownState() {
        #expect(!HUDDragTooltipEligibility.shouldShow(successfulDictationCount: 0, hasBeenShown: false))
        #expect(!HUDDragTooltipEligibility.shouldShow(successfulDictationCount: 2, hasBeenShown: false))
        #expect(HUDDragTooltipEligibility.shouldShow(successfulDictationCount: 3, hasBeenShown: false))
        #expect(HUDDragTooltipEligibility.shouldShow(successfulDictationCount: 4, hasBeenShown: false))
        #expect(!HUDDragTooltipEligibility.shouldShow(successfulDictationCount: 3, hasBeenShown: true))
        #expect(!HUDDragTooltipEligibility.shouldShow(successfulDictationCount: 4, hasBeenShown: true))
    }

    @Test
    func dragTooltipStorePersistsShownStateIdempotently() {
        let suite = "HUDReleaseHardening.tooltip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HUDDragTooltipStateStore(defaults: defaults)

        #expect(!store.hasBeenShown)
        store.markShown()
        #expect(store.hasBeenShown)
        store.markShown()
        #expect(store.hasBeenShown)
    }

    @Test
    @MainActor
    func copyLastUsesLatestItemPasteboardBoundaryAndConfirmationSignal() {
        let pasteboard = HardeningPasteboardWriter()
        let latest = TranscriptHistoryItem(text: "synthetic latest")
        let older = TranscriptHistoryItem(text: "synthetic older")
        var copiedID: UUID?

        let shouldConfirm = HUDCopyLastAction.perform(history: [latest, older]) { item in
            copiedID = item.id
            TranscriptPasteboardAction.copy(item.text, using: pasteboard)
        }

        #expect(shouldConfirm)
        #expect(copiedID == latest.id)
        #expect(pasteboard.value == "synthetic latest")
        #expect(pasteboard.replaceCount == 1)
    }

    @Test
    func copyLastEmptyHistoryDoesNothingAndDoesNotConfirm() {
        var copyCount = 0
        let shouldConfirm = HUDCopyLastAction.perform(history: []) { _ in copyCount += 1 }

        #expect(!shouldConfirm)
        #expect(copyCount == 0)
    }

    @Test
    @MainActor
    func trayBackgroundCollapsesWhileControlsRemainIndependent() {
        let model = HUDViewModel()
        model.apply(.logoIdle)
        model.setExpanded(true)
        model.canCopyLast = true
        var copyCount = 0
        var dictionaryCount = 0
        var hideDurations: [HUDHideDuration] = []
        model.onCopyLast = { copyCount += 1 }
        model.onAddToDictionary = { dictionaryCount += 1 }
        model.onHide = { hideDurations.append($0) }

        model.requestCopyLast()
        model.requestAddToDictionary()
        model.requestHide(.tenMinutes)

        #expect(copyCount == 1)
        #expect(dictionaryCount == 1)
        #expect(hideDurations == [.tenMinutes])
        #expect(model.isExpanded)

        model.handleTrayBackgroundTap()
        #expect(!model.isExpanded)
        #expect(copyCount == 1)
        #expect(dictionaryCount == 1)
        #expect(hideDurations == [.tenMinutes])
    }

    @Test
    @MainActor
    func disabledTrayActionsNeverFireCallbacks() {
        let model = HUDViewModel()
        var copyCount = 0
        var dictionaryCount = 0
        model.onCopyLast = { copyCount += 1 }
        model.onAddToDictionary = { dictionaryCount += 1 }
        model.canCopyLast = false
        model.dictionaryFeedback = .capturing

        model.requestCopyLast()
        model.requestAddToDictionary()

        #expect(copyCount == 0)
        #expect(dictionaryCount == 0)
    }

    @Test
    func dragRuntimeMovesSnapsAndPersistsThroughProductionStore() {
        let suite = "HUDReleaseHardening.drag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HUDPositionStore(defaults: defaults)
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let visible = NSRect(x: 0, y: 50, width: 1_000, height: 726)
        var runtime = HUDDragRuntime()

        runtime.begin(panelOrigin: NSPoint(x: 478, y: 50), pointer: NSPoint(x: 500, y: 72))
        #expect(HUDDragOverlayPolicy.shouldShow(isDragging: runtime.isActive, isOverlayVisible: false))
        #expect(!HUDDragOverlayPolicy.shouldShow(isDragging: runtime.isActive, isOverlayVisible: true))
        let movedOrigin = runtime.moved(to: NSPoint(x: 970, y: 750))
        #expect(movedOrigin == NSPoint(x: 948, y: 728))
        let movedFrame = NSRect(origin: movedOrigin!, size: HUDMetrics.idleHitSize)
        #expect(runtime.nearestPosition(
            panelFrame: movedFrame,
            screenFrame: screen,
            visibleFrame: visible
        ) == .topRight)
        let completion = runtime.complete(
            panelFrame: movedFrame,
            screenFrame: screen,
            visibleFrame: visible
        )

        #expect(completion?.position == .topRight)
        #expect(completion?.origin == NSPoint(x: 956, y: 732))
        #expect(!runtime.isActive)
        #expect(!HUDDragOverlayPolicy.shouldShow(isDragging: runtime.isActive, isOverlayVisible: false))
        if let completion { store.save(completion.position) }
        #expect(store.load() == .topRight)
    }

    @Test
    func clickAwayPolicyIgnoresControlsAndMenusButCollapsesOutside() {
        let panel = NSRect(x: 100, y: 100, width: 240, height: 38)
        #expect(!HUDClickAwayPolicy.shouldCollapse(
            isExpanded: true,
            panelFrame: panel,
            pointer: NSPoint(x: 120, y: 120),
            isMenuWindow: false
        ))
        #expect(!HUDClickAwayPolicy.shouldCollapse(
            isExpanded: true,
            panelFrame: panel,
            pointer: NSPoint(x: 500, y: 500),
            isMenuWindow: true
        ))
        #expect(HUDClickAwayPolicy.shouldCollapse(
            isExpanded: true,
            panelFrame: panel,
            pointer: NSPoint(x: 500, y: 500),
            isMenuWindow: false
        ))
        #expect(!HUDClickAwayPolicy.shouldCollapse(
            isExpanded: false,
            panelFrame: panel,
            pointer: NSPoint(x: 500, y: 500),
            isMenuWindow: false
        ))
    }
}

@MainActor
private final class HardeningCapturingFeedbackService: FeedbackServing {
    var isEnabled = true
    private(set) var activationCount = 0

    func playActivationSound() {
        guard isEnabled else { return }
        activationCount += 1
    }
}

@MainActor
private final class HardeningPasteboardWriter: TextPasteboardWriting {
    private(set) var value: String?
    private(set) var replaceCount = 0

    func replaceContents(with text: String) -> Bool {
        value = text
        replaceCount += 1
        return true
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
