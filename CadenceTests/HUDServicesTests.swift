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
    func idlePillFitsInsideFullHitTarget() {
        #expect(HUDMetrics.idleHitSize == NSSize(width: 44, height: 44))
        #expect(HUDMetrics.idleMarkSize == NSSize(width: 44, height: 38))
        #expect(HUDMetrics.idleMarkSize.width == HUDMetrics.idleHitSize.width)
        #expect(HUDMetrics.idleMarkSize.height < HUDMetrics.idleHitSize.height)
    }

    @Test
    func everyPillPresentationUsesAStablePanelHeight() {
        let presentations = [
            HUDPresentation(visualState: .idle, isExpanded: false),
            HUDPresentation(visualState: .idle, isExpanded: true),
            HUDPresentation(
                visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
                isExpanded: false
            ),
            HUDPresentation(visualState: .transcribing, isExpanded: false)
        ]

        for presentation in presentations {
            #expect(HUDPanelLayout.size(for: presentation).height == HUDMetrics.panelHeight)
        }
    }

    @Test
    func errorFeedbackReusesTheRecordingPillWidth() {
        let recording = HUDPresentation(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            isExpanded: false
        )
        let error = HUDPresentation(
            visualState: .error(message: "Nothing picked up"),
            isExpanded: false
        )

        #expect(HUDPanelLayout.size(for: recording).width < HUDMetrics.compactWidth)
        #expect(HUDPanelLayout.size(for: error).width == HUDPanelLayout.size(for: recording).width)
    }

    @Test
    func activeDictationPhasesKeepTheRecordingPillWidth() {
        let applicationName = "Microsoft Word"
        let recording = HUDPresentation(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            isExpanded: false
        )
        let expectedWidth = HUDPanelLayout.size(
            for: recording,
            applicationName: applicationName
        ).width
        let phases: [HUDVisualState] = [
            .preparingModel,
            .transcribing,
            .inserting,
            .copying,
            .copied,
            .success,
            .cancelled,
            .error(message: "Nothing captured")
        ]

        for phase in phases {
            let presentation = HUDPresentation(visualState: phase, isExpanded: false)
            #expect(HUDPanelLayout.size(
                for: presentation,
                applicationName: applicationName
            ).width == expectedWidth)
        }
    }

    @Test
    func recordingWidthTracksAppNameUntilTheMarqueeCap() {
        let recording = HUDPresentation(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            isExpanded: false
        )
        let short = HUDPanelLayout.size(for: recording, applicationName: "Dia").width
        let medium = HUDPanelLayout.size(for: recording, applicationName: "Microsoft Word").width
        let long = HUDPanelLayout.size(
            for: recording,
            applicationName: "An Extremely Long Application Name"
        ).width

        #expect(short < medium)
        #expect(medium <= long)
        #expect(HUDContentSizing.applicationNameWidth(
            "An Extremely Long Application Name"
        ) == HUDContentSizing.applicationNameMaximumWidth)
    }

    @Test
    func lockedListeningUsesTheSameMainPillWidthAsOrdinaryRecording() {
        let applicationName = "Dia"
        let ordinary = HUDPresentation(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            isExpanded: false
        )
        let locked = HUDPresentation(
            visualState: .recording(triggerMode: .tapToStartStop, showsHint: false),
            isExpanded: false
        )

        #expect(HUDPanelLayout.size(
            for: locked,
            applicationName: applicationName
        ).width == HUDPanelLayout.size(
            for: ordinary,
            applicationName: applicationName
        ).width)
    }

    @Test
    func lockAccessoryOnlyAppearsForLockedListening() {
        #expect(HUDLockIndicatorLayout.shouldShow(
            for: .recording(triggerMode: .tapToStartStop, showsHint: false)
        ))
        #expect(!HUDLockIndicatorLayout.shouldShow(
            for: .recording(triggerMode: .holdToTalk, showsHint: false)
        ))
        #expect(!HUDLockIndicatorLayout.shouldShow(for: .transcribing))
        #expect(!HUDLockIndicatorLayout.shouldShow(for: .idle))
    }

    @Test
    func lockAccessoryWaitsOnlyWhenTheListeningPillIsStillExpanding() {
        let idle = HUDPresentation(visualState: .idle, isExpanded: false)
        let held = HUDPresentation(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            isExpanded: false
        )
        let locked = HUDPresentation(
            visualState: .recording(triggerMode: .tapToStartStop, showsHint: false),
            isExpanded: false
        )

        #expect(HUDLockIndicatorLayout.waitsForPillExpansion(
            previous: idle,
            current: locked,
            hasActiveMorph: true
        ))
        #expect(!HUDLockIndicatorLayout.waitsForPillExpansion(
            previous: held,
            current: locked,
            hasActiveMorph: true
        ))
        #expect(!HUDLockIndicatorLayout.waitsForPillExpansion(
            previous: idle,
            current: locked,
            hasActiveMorph: false
        ))
    }

    @Test
    func lockAccessorySplitsTowardTheInsideOfTheScreen() {
        let pillFrame = NSRect(x: 100, y: 200, width: 220, height: HUDMetrics.panelHeight)

        for position in [HUDPosition.bottomCenter, .topLeft, .bottomLeft] {
            let origin = HUDLockIndicatorLayout.origin(position: position, pillFrame: pillFrame)
            let start = HUDLockIndicatorLayout.emergenceFrame(position: position, pillFrame: pillFrame)
            #expect(origin.x == pillFrame.maxX + HUDMetrics.lockIndicatorGap)
            #expect(start.midX < origin.x + HUDMetrics.lockIndicatorSize.width / 2)
            #expect(origin.y + HUDMetrics.lockIndicatorSize.height / 2 == pillFrame.midY)
        }

        for position in [HUDPosition.topRight, .bottomRight] {
            let origin = HUDLockIndicatorLayout.origin(position: position, pillFrame: pillFrame)
            let start = HUDLockIndicatorLayout.emergenceFrame(position: position, pillFrame: pillFrame)
            #expect(origin.x + HUDMetrics.lockIndicatorSize.width + HUDMetrics.lockIndicatorGap == pillFrame.minX)
            #expect(start.midX > origin.x + HUDMetrics.lockIndicatorSize.width / 2)
            #expect(origin.y + HUDMetrics.lockIndicatorSize.height / 2 == pillFrame.midY)
        }
    }

    @Test
    func motionProgressStartsAndEndsSmoothly() {
        #expect(HUDMotion.smoothProgress(elapsed: 0, duration: 0.34) == 0)
        #expect(HUDMotion.smoothProgress(elapsed: 0.34, duration: 0.34) == 1)
        #expect(HUDMotion.smoothProgress(elapsed: 0.17, duration: 0.34) == 0.5)
        #expect(HUDMotion.interpolateWidth(from: 44, to: 280, progress: 0) == 44)
        #expect(HUDMotion.interpolateWidth(from: 44, to: 280, progress: 0.5) == 162)
        #expect(HUDMotion.interpolateWidth(from: 44, to: 280, progress: 1) == 280)
    }

    @Test
    func activationWaveTravelsLeftToRightThenSettlesToLiveLevels() {
        let target = Array(repeating: 0.08, count: 16)
        let starting = HUDMotion.activationSweepLevels(progress: 0, target: target)
        let early = HUDMotion.activationSweepLevels(progress: 0.15, target: target)
        let late = HUDMotion.activationSweepLevels(progress: 0.72, target: target)
        let settled = HUDMotion.activationSweepLevels(progress: 1, target: target)

        #expect(starting[0] > 0.5)
        #expect(Set(starting.map { Int(($0 * 100).rounded()) }).count > 2)
        let earlyPeak = early.enumerated().max(by: { $0.element < $1.element })?.offset
        let latePeak = late.enumerated().max(by: { $0.element < $1.element })?.offset
        #expect(earlyPeak != nil)
        #expect(latePeak != nil)
        #expect(earlyPeak! < latePeak!)
        #expect(settled == target)
    }

    @Test
    func uniformVoiceEnergyProducesAStableUnevenWaveform() {
        let input = Array(repeating: 0.6, count: 16)
        let first = HUDMotion.characterizedWaveformLevels(input)
        let second = HUDMotion.characterizedWaveformLevels(input)

        #expect(first == second)
        #expect((first.max() ?? 0) - (first.min() ?? 0) > 0.15)
        #expect(first.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test
    func errorTimingLeavesEnoughTimeForOneMarqueePass() {
        #expect(HUDTerminalTiming.displayMilliseconds(for: .success) == 900)
        #expect(HUDTerminalTiming.displayMilliseconds(
            for: .error(message: "Nothing captured")
        ) >= 1_500)
        #expect(HUDTerminalTiming.displayMilliseconds(
            for: .error(message: String(repeating: "x", count: 200))
        ) == 6_000)
    }

    @Test
    func collapsedMicRemainsVisibleThroughoutReturnTransition() {
        let idle = HUDPresentation(visualState: .idle, isExpanded: false)
        #expect(HUDMotion.incomingOpacity(
            for: idle,
            hasPreviousPresentation: true,
            elapsed: 0,
            duration: 0.16
        ) == 1)
        #expect(HUDMotion.incomingOpacity(
            for: idle,
            hasPreviousPresentation: true,
            elapsed: 0.16,
            duration: 0.16
        ) == 1)
    }

    @Test
    func collapsingTextAndWaveformFadeBeforeTheIconHandoffCompletes() {
        let response: TimeInterval = 0.34
        #expect(HUDMotion.collapsingContentOpacity(
            elapsed: 0,
            pillResponse: response
        ) == 1)
        #expect(HUDMotion.collapsingContentOpacity(
            elapsed: 0.14,
            pillResponse: response
        ) == 0)

        let iconHandoffDuration = min(0.22, response * 0.72)
        #expect(iconHandoffDuration > 0.14)
    }

    @Test
    func activeContentUsesAShortNonStackingFadeSequence() {
        #expect(HUDActiveContentTransition.outgoingOpacity(elapsed: 0) == 1)
        #expect(HUDActiveContentTransition.incomingOpacity(elapsed: 0) == 0)
        #expect(HUDActiveContentTransition.outgoingOpacity(elapsed: 0.075) == 0)
        #expect(HUDActiveContentTransition.incomingOpacity(elapsed: 0.14) == 1)

        for elapsed in stride(from: 0.0, through: 0.14, by: 0.01) {
            let combined = HUDActiveContentTransition.outgoingOpacity(elapsed: elapsed)
                + HUDActiveContentTransition.incomingOpacity(elapsed: elapsed)
            #expect(combined <= 1.05)
        }
    }

    @Test
    func activeContentReplacementUsesItsOwnDurationAndCoalescesFastStatuses() {
        let recording = HUDPresentation(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            isExpanded: false
        )
        let transcribing = HUDPresentation(visualState: .transcribing, isExpanded: false)
        let inserted = HUDPresentation(visualState: .success, isExpanded: false)
        let idle = HUDPresentation(visualState: .idle, isExpanded: false)

        #expect(HUDPanelTransition.duration(
            from: recording,
            to: transcribing,
            motionTuning: .default
        ) == HUDActiveContentTransition.duration)
        #expect(HUDPanelTransition.duration(
            from: inserted,
            to: idle,
            motionTuning: .default
        ) == HUDMotionTuning.default.pillResponse)
        #expect(HUDActiveContentTransition.shouldDefer(
            current: transcribing,
            requested: inserted,
            isReplacementAnimating: true
        ))
        #expect(!HUDActiveContentTransition.shouldDefer(
            current: inserted,
            requested: recording,
            isReplacementAnimating: true
        ))
    }

    @Test
    func spinnerPhaseComesFromSharedTimeInsteadOfViewLifetime() {
        #expect(HUDSpinnerMotion.degrees(at: 0) == 0)
        #expect(HUDSpinnerMotion.degrees(at: 0.45) == 180)
        #expect(HUDSpinnerMotion.degrees(at: 0.9) == 0)
        #expect(HUDSpinnerMotion.degrees(at: 12.345) == HUDSpinnerMotion.degrees(at: 12.345))
    }

    @Test
    func panelBoundsExpandBeforeMorphButCollapseAfterContentFinishes() {
        #expect(HUDPanelBoundsPolicy.appliesTargetBeforeMorph(currentWidth: 44, targetWidth: 252))
        #expect(!HUDPanelBoundsPolicy.appliesTargetBeforeMorph(currentWidth: 252, targetWidth: 44))
    }

    @Test
    func collapsingForegroundWipesAtTheInsidePaddingEdge() {
        let targetWidth: CGFloat = 252
        let renderedWidth: CGFloat = 180
        let padding = HUDContentSizing.horizontalPadding

        let left = HUDForegroundMaskLayout.frame(
            position: .bottomLeft,
            targetWidth: targetWidth,
            renderedWidth: renderedWidth
        )
        #expect(left.minX == 0)
        #expect(left.maxX == renderedWidth - padding)

        let right = HUDForegroundMaskLayout.frame(
            position: .bottomRight,
            targetWidth: targetWidth,
            renderedWidth: renderedWidth
        )
        #expect(right.minX == targetWidth - renderedWidth + padding)
        #expect(right.maxX == targetWidth)

        let center = HUDForegroundMaskLayout.frame(
            position: .bottomCenter,
            targetWidth: targetWidth,
            renderedWidth: renderedWidth
        )
        #expect(center.minX == (targetWidth - renderedWidth) / 2)
        #expect(center.maxX == (targetWidth + renderedWidth) / 2 - padding)
    }

    @Test
    func animatedMicrophoneEndsAtThePermanentRestingMicrophoneCenter() {
        let sourceSize = NSSize(width: 252, height: HUDMetrics.panelHeight)

        for position in HUDPosition.allCases {
            let restingOrigin = HUDContentAttachment.appKitOrigin(
                position: position,
                contentSize: HUDMetrics.idleHitSize,
                containerSize: sourceSize
            )
            let permanentCenterX = restingOrigin.x + HUDMetrics.idleHitSize.width / 2

            #expect(HUDRestingMicrophoneLayout.centerX(
                position: position,
                containerWidth: sourceSize.width
            ) == permanentCenterX)
        }
    }

    @Test
    func visibleMarkIsCenteredInsideEveryPaddedHitTarget() {
        for position in HUDPosition.allCases {
            let panel = HUDPanelLayout.targetFrame(
                position: position,
                screenFrame: screen,
                visibleFrame: visible,
                size: HUDMetrics.idleHitSize
            )
            let mark = position.visibleMarkFrame(in: panel)
            #expect(mark.size == HUDMetrics.idleMarkSize)
            #expect(mark.midX == panel.midX)
            #expect(mark.midY == panel.midY)
            #expect(panel.minX >= visible.minX + HUDMetrics.screenInset)
            #expect(panel.minY >= visible.minY + HUDMetrics.screenInset)
            #expect(panel.maxX <= visible.maxX - HUDMetrics.screenInset)
            #expect(panel.maxY <= visible.maxY - HUDMetrics.screenInset)
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
        ) == CGRect(x: 16, y: 43, width: 44, height: 38))
        #expect(HUDDropZoneGeometry.canvasRect(
            for: .bottomRight,
            screenFrame: screen,
            visibleFrame: visible
        ) == CGRect(x: 1860, y: 953, width: 44, height: 38))
        #expect(HUDDropZoneGeometry.canvasRect(
            for: .bottomCenter,
            screenFrame: screen,
            visibleFrame: visible
        ) == CGRect(x: 938, y: 953, width: 44, height: 38))
    }

    @Test
    func dropRectConversionSupportsNegativeOriginScreens() {
        let negativeScreen = NSRect(x: -1440, y: 100, width: 1440, height: 900)
        let negativeVisible = NSRect(x: -1440, y: 100, width: 1440, height: 876)

        #expect(HUDDropZoneGeometry.canvasRect(
            for: .topRight,
            screenFrame: negativeScreen,
            visibleFrame: negativeVisible
        ) == CGRect(x: 1380, y: 43, width: 44, height: 38))
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
        for position in HUDPosition.allCases {
            #expect(HUDScreenChangePolicy.shouldReposition(position))
        }
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
    func darkChromeUsesStableGraphiteAndAccessibilityFallbacks() {
        let standard = HUDChromeStyle.resolve(
            isDark: true,
            reduceTransparency: false,
            increasedContrast: false
        )
        let accessible = HUDChromeStyle.resolve(
            isDark: true,
            reduceTransparency: true,
            increasedContrast: true
        )

        #expect(standard.surfaceHex == 0x202124)
        #expect(standard.surfaceOpacity >= 0.85)
        #expect(accessible.surfaceOpacity == 1)
        #expect(accessible.borderOpacity > standard.borderOpacity)
    }

    @Test
    func menuBarMarkKeepsCadenceDotSubtleUntilRecording() {
        #expect(CadenceMenuBarIconMetrics.frameSize == 18)
        #expect(CadenceMenuBarIconMetrics.dotCenter.x
            < CadenceMenuBarIconMetrics.frameSize)
        #expect(CadenceMenuBarIconMetrics.dotDiameter(isRecording: true)
            > CadenceMenuBarIconMetrics.dotDiameter(isRecording: false))
    }

    @Test
    func diagnosticsMeasureAHealthy120HzSample() {
        let diagnostics = HUDFrameDiagnostics(warmUpDuration: 0)
        diagnostics.begin(targetFramesPerSecond: 120)
        for _ in 0..<1_200 {
            diagnostics.record(deltaTime: 1 / 120)
        }
        let summary = diagnostics.summary()
        #expect(summary?.targetFramesPerSecond == 120)
        #expect(abs((summary?.deliveredFramesPerSecond ?? 0) - 120) < 0.001)
        #expect((summary?.p95DeltaMilliseconds ?? .infinity) < 8.34)
        #expect(summary?.lateFramePercentage == 0)
    }

    @Test
    func diagnosticsClassifyCallbacksOverOneAndAHalfIntervalsAsLate() {
        let diagnostics = HUDFrameDiagnostics(warmUpDuration: 0)
        diagnostics.begin(targetFramesPerSecond: 120)
        for _ in 0..<99 { diagnostics.record(deltaTime: 1 / 120) }
        diagnostics.record(deltaTime: 1 / 60)
        #expect(abs((diagnostics.summary()?.lateFramePercentage ?? 0) - 1) < 0.001)
    }

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
    func adjacentBarsDoNotRespondInLockstep() {
        let first = HUDWaveformSmoother.step(
            current: 0,
            target: 1,
            deltaTime: 1 / 60,
            responseScale: HUDMotion.waveformResponseScale(forBar: 0)
        )
        let second = HUDWaveformSmoother.step(
            current: 0,
            target: 1,
            deltaTime: 1 / 60,
            responseScale: HUDMotion.waveformResponseScale(forBar: 1)
        )

        #expect(abs(first - second) > 0.01)
    }

    @Test
    func displayRefreshPolicyUsesActualMaximumFrameRate() {
        let promotion = HUDDisplayRefreshPolicy.preferredRange(maximumFramesPerSecond: 120)
        let standard = HUDDisplayRefreshPolicy.preferredRange(maximumFramesPerSecond: 60)

        #expect(promotion.maximum == 120)
        #expect(promotion.preferred == 120)
        #expect(promotion.minimum == 120)
        #expect(standard.maximum == 60)
        #expect(standard.preferred == 60)
        #expect(standard.minimum == 60)
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

        #expect(model.displayBars == HUDMotion.characterizedWaveformLevels(
            Array(repeating: 0.7, count: 16)
        ))
        #expect(!model.hasPendingWaveformAnimation)
    }

    @Test
    @MainActor
    func reducedMotionFinishesActiveContentMorphImmediately() {
        let model = HUDViewModel()
        let idle = HUDPresentation(visualState: .idle, isExpanded: false)
        model.beginMorph(from: idle, startWidth: HUDMetrics.idleHitSize.width)
        model.onReducedMotionChanged = { reduced in
            if reduced { model.finishMorph() }
        }

        model.setReducedMotion(true)

        #expect(model.previousPresentation == nil)
        #expect(model.morphProgress == 1)
    }

    @Test
    @MainActor
    func interruptedMorphContinuesFromCurrentlyRenderedWidth() {
        let model = HUDViewModel()
        model.apply(.logoIdle)
        let idle = model.presentation
        model.apply(HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "",
            level: 0.5,
            waveformLevels: Array(repeating: 0.5, count: 16),
            isVisible: true,
            showsSubtitle: false
        ))
        model.beginMorph(from: idle, startWidth: HUDMetrics.idleHitSize.width)
        model.setMorphProgress(0.5, elapsed: 0.17)
        let interruptedWidth = model.renderedWidth

        let recording = model.presentation
        model.apply(.logoIdle)
        model.beginMorph(from: recording, startWidth: interruptedWidth)

        #expect(model.renderedWidth == interruptedWidth)
        model.setMorphProgress(0.5, elapsed: 0.17)
        #expect(model.renderedWidth == HUDMotion.interpolateWidth(
            from: interruptedWidth,
            to: HUDMetrics.idleHitSize.width,
            progress: 0.5
        ))
    }

    @Test
    @MainActor
    func applicationIconMorphRunsOnlyFromTheRestingMic() {
        let recordingState = HUDState(
            visualState: .recording(triggerMode: .holdToTalk, showsHint: false),
            subtitle: "",
            level: 0.5,
            waveformLevels: Array(repeating: 0.5, count: 16),
            isVisible: true,
            showsSubtitle: false
        )

        let fromIdle = HUDViewModel()
        fromIdle.apply(.logoIdle)
        let idle = fromIdle.presentation
        fromIdle.apply(recordingState)
        fromIdle.beginMorph(from: idle, startWidth: HUDMetrics.idleHitSize.width)
        #expect(fromIdle.shouldMorphApplicationMark)

        let fromError = HUDViewModel()
        fromError.apply(HUDState(
            visualState: .error(message: "Try again"),
            subtitle: "",
            level: 0,
            waveformLevels: Array(repeating: 0, count: 16),
            isVisible: true,
            showsSubtitle: false
        ))
        let error = fromError.presentation
        fromError.apply(recordingState)
        fromError.beginMorph(from: error, startWidth: fromError.targetWidth(for: error))
        #expect(!fromError.shouldMorphApplicationMark)
    }

    @Test
    @MainActor
    func terminalPresentationReversesIntoTheRestingMic() {
        let model = HUDViewModel()
        model.apply(HUDState(
            visualState: .success,
            subtitle: "",
            level: 0,
            waveformLevels: Array(repeating: 0, count: 16),
            isVisible: true,
            showsSubtitle: false
        ))
        let success = model.presentation
        model.apply(.logoIdle)
        model.beginMorph(from: success, startWidth: model.targetWidth(for: success))

        #expect(model.isCollapsingToRestingMic)

        model.finishMorph()
        #expect(!model.isCollapsingToRestingMic)
    }

    @Test
    @MainActor
    func activeStatusReplacementUsesTheDedicatedContentTransition() {
        let model = HUDViewModel()
        model.apply(HUDState(
            visualState: .transcribing,
            subtitle: "",
            level: 0,
            waveformLevels: Array(repeating: 0, count: 16),
            isVisible: true,
            showsSubtitle: false
        ))
        let transcribing = model.presentation
        model.apply(HUDState(
            visualState: .copied,
            subtitle: "",
            level: 0,
            waveformLevels: Array(repeating: 0, count: 16),
            isVisible: true,
            showsSubtitle: false
        ))
        model.beginMorph(
            from: transcribing,
            startWidth: model.targetWidth(for: transcribing)
        )

        #expect(model.isReplacingActiveContent)
        #expect(model.isReplacingStatusContent)
        #expect(!model.isCollapsingToRestingMic)
    }

    @Test
    func appCueStaysPersistentOnlyAcrossStatusToStatusReplacement() {
        #expect(HUDApplicationCueTransition.keepsCueStable(
            from: .transcribing,
            to: .success
        ))
        #expect(HUDApplicationCueTransition.keepsCueStable(
            from: .transcribing,
            to: .copied
        ))
        #expect(!HUDApplicationCueTransition.keepsCueStable(
            from: .recording(triggerMode: .holdToTalk, showsHint: false),
            to: .transcribing
        ))
        #expect(!HUDApplicationCueTransition.keepsCueStable(
            from: .success,
            to: .idle
        ))
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
    func soundPreferencesDefaultOnMigrateAndPersistIndependently() {
        let suite = "HUDReleaseHardening.sound.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HardeningCapturingFeedbackService()

        #expect(DictationSoundFeedbackPreference.loadActivation(from: defaults))
        #expect(DictationSoundFeedbackPreference.loadCompletion(from: defaults))

        defaults.set(false, forKey: DictationSoundFeedbackPreference.legacyKey)
        #expect(!DictationSoundFeedbackPreference.loadActivation(from: defaults))
        #expect(!DictationSoundFeedbackPreference.loadCompletion(from: defaults))

        DictationSoundFeedbackPreference.setActivation(true, defaults: defaults, service: service)
        #expect(DictationSoundFeedbackPreference.loadActivation(from: defaults))
        #expect(!DictationSoundFeedbackPreference.loadCompletion(from: defaults))
        #expect(service.isActivationEnabled)
        #expect(service.isCompletionEnabled)

        DictationSoundFeedbackPreference.setCompletion(false, defaults: defaults, service: service)
        #expect(!DictationSoundFeedbackPreference.loadCompletion(from: defaults))
        #expect(!service.isCompletionEnabled)
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
            TranscriptCopyCommit.perform(item.text, using: pasteboard) {
                copiedID = item.id
            }
        }

        #expect(shouldConfirm)
        #expect(copiedID == latest.id)
        #expect(pasteboard.value == "synthetic latest")
        #expect(pasteboard.replaceCount == 1)
    }

    @Test
    func copyLastEmptyHistoryDoesNothingAndDoesNotConfirm() {
        var copyCount = 0
        let shouldConfirm = HUDCopyLastAction.perform(history: []) { _ in
            copyCount += 1
            return true
        }

        #expect(!shouldConfirm)
        #expect(copyCount == 0)
    }

    @Test
    @MainActor
    func failedPasteboardWriteDoesNotCommitCopiedStateAnalyticsOrConfirmation() {
        let pasteboard = HardeningPasteboardWriter(succeeds: false)
        let item = TranscriptHistoryItem(text: "synthetic failure")
        var copiedStateID: UUID?
        var successAnalyticsCount = 0

        let shouldConfirm = HUDCopyLastAction.perform(history: [item]) { latest in
            TranscriptCopyCommit.perform(latest.text, using: pasteboard) {
                copiedStateID = latest.id
                successAnalyticsCount += 1
            }
        }

        #expect(!shouldConfirm)
        #expect(copiedStateID == nil)
        #expect(successAnalyticsCount == 0)
        #expect(pasteboard.replaceCount == 1)
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
        #expect(completion?.origin == NSPoint(x: 940, y: 716))
        #expect(!runtime.isActive)
        #expect(!HUDDragOverlayPolicy.shouldShow(isDragging: runtime.isActive, isOverlayVisible: false))
        if let completion { store.save(completion.position) }
        #expect(store.load() == .topRight)
    }

    @Test
    func bottomCenterPersistsAsAFirstClassPosition() {
        let suite = "HUDPositionStoreMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(HUDPosition.bottomCenter.rawValue, forKey: "Cadence.hudPosition")

        let store = HUDPositionStore(defaults: defaults)
        #expect(store.load() == .bottomCenter)
        store.save(.topLeft)
        #expect(store.load() == .topLeft)
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
struct HUDApplicationPresentationTests {
    @Test
    func viewModelDistinguishesCadenceFromKnownApplicationPlaceholder() {
        let model = HUDViewModel()
        #expect(model.applicationPresentation.kind == .cadence)
        let identity = ApplicationProcessIdentity(
            processIdentifier: 7, bundleIdentifier: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"), incarnation: UUID()
        )
        model.applyApplicationPresentation(.init(
            identity: identity, displayName: "Codex", icon: nil,
            iconSource: .genericApplication, kind: .knownApplication,
            presentationRevision: 1, pinID: UUID()
        ))

        #expect(model.applicationPresentation.kind == .knownApplication)
        #expect(model.applicationPresentation.displayName == "Codex")
        #expect(model.applicationPresentation.icon == nil)
    }

    @Test
    func accessibilityLabelsRemainAppAwareAcrossActiveAndTerminalStates() {
        let identity = ApplicationProcessIdentity(
            processIdentifier: 8,
            bundleIdentifier: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            incarnation: UUID(),
            launchDate: Date(timeIntervalSince1970: 1)
        )
        let application = HUDApplicationPresentation(
            identity: identity,
            displayName: "Codex",
            icon: nil,
            iconSource: .genericApplication,
            kind: .knownApplication,
            presentationRevision: 1,
            pinID: UUID()
        )
        let states: [HUDVisualState] = [
            .idle,
            .recording(triggerMode: .tapToStartStop, showsHint: false),
            .recording(triggerMode: .holdToTalk, showsHint: true),
            .preparingModel,
            .transcribing,
            .inserting,
            .success,
            .cancelled,
            .error(message: "Insertion failed")
        ]

        for state in states where state != .idle {
            #expect(HUDAccessibilityLabelResolver.label(
                visualState: state,
                application: application
            ).contains("Codex"))
        }
        #expect(HUDAccessibilityLabelResolver.label(
            visualState: .idle,
            application: application
        ) == "Cadence is ready")
        #expect(HUDAccessibilityLabelResolver.label(
            visualState: .transcribing,
            application: .cadence
        ) == "Transcribing dictation")
    }
}

@MainActor
private final class HardeningCapturingFeedbackService: FeedbackServing {
    var isActivationEnabled = true
    var isCompletionEnabled = true
    private(set) var activationCount = 0

    func playActivationSound() {
        guard isActivationEnabled else { return }
        activationCount += 1
    }
}

@MainActor
private final class HardeningPasteboardWriter: TextPasteboardWriting {
    private let succeeds: Bool
    private(set) var value: String?
    private(set) var replaceCount = 0

    init(succeeds: Bool = true) {
        self.succeeds = succeeds
    }

    func replaceContents(with text: String) -> Bool {
        value = text
        replaceCount += 1
        return succeeds
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
