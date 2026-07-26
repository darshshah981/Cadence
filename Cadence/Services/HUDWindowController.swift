import AppKit
import OSLog
import QuartzCore
import SwiftUI

private let hudLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "HUD")

struct HUDFrameDiagnosticSummary: Equatable {
    let targetFramesPerSecond: Int
    let deliveredFramesPerSecond: Double
    let p95DeltaMilliseconds: Double
    let lateFramePercentage: Double
    let maximumDeltaMilliseconds: Double
}

final class HUDFrameDiagnostics {
    private(set) var targetFramesPerSecond = 60
    private var deltas: [TimeInterval] = []
    private let warmUpDuration: TimeInterval
    private var elapsed: TimeInterval = 0

    init(warmUpDuration: TimeInterval = 2) {
        self.warmUpDuration = warmUpDuration
    }

    func begin(targetFramesPerSecond: Int) {
        self.targetFramesPerSecond = max(1, targetFramesPerSecond)
        deltas.removeAll(keepingCapacity: true)
        elapsed = 0
    }

    func record(deltaTime: TimeInterval) {
        guard deltaTime > 0 else { return }
        elapsed += deltaTime
        guard elapsed > warmUpDuration else { return }
        deltas.append(deltaTime)
    }

    func summary() -> HUDFrameDiagnosticSummary? {
        guard !deltas.isEmpty else { return nil }
        let sorted = deltas.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let requestedInterval = 1 / Double(targetFramesPerSecond)
        let lateCount = deltas.filter { $0 > requestedInterval * 1.5 }.count
        let totalDuration = deltas.reduce(0, +)
        return HUDFrameDiagnosticSummary(
            targetFramesPerSecond: targetFramesPerSecond,
            deliveredFramesPerSecond: totalDuration > 0 ? Double(deltas.count) / totalDuration : 0,
            p95DeltaMilliseconds: sorted[index] * 1_000,
            lateFramePercentage: Double(lateCount) / Double(deltas.count) * 100,
            maximumDeltaMilliseconds: (sorted.last ?? 0) * 1_000
        )
    }
}

enum HUDWaveformSmoother {
    static func step(
        current: Double,
        target: Double,
        deltaTime: TimeInterval,
        responseScale: Double = 1
    ) -> Double {
        let clampedTarget = max(0, min(1, target))
        let baseRate = clampedTarget > current
            ? HUDMotion.waveformAttackRate
            : HUDMotion.waveformReleaseRate
        let rate = baseRate * max(0.5, min(1.5, responseScale))
        let factor = 1 - exp(-rate * max(0, deltaTime))
        let next = current + (clampedTarget - current) * factor
        return abs(next - clampedTarget) <= HUDMotion.stableTolerance ? clampedTarget : max(0, min(1, next))
    }

    static func isStable(current: [Double], target: [Double]) -> Bool {
        guard current.count == target.count else { return false }
        return zip(current, target).allSatisfy { abs($0 - $1) <= HUDMotion.stableTolerance }
    }
}

enum HUDDisplayRefreshPolicy {
    static func preferredRange(maximumFramesPerSecond: Int) -> CAFrameRateRange {
        let maximum = Float(max(1, maximumFramesPerSecond))
        return CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
    }
}

@MainActor
final class HUDDisplayLinkClock: NSObject {
    var onFrame: ((TimeInterval) -> Bool)?

    private weak var view: NSView?
    private var displayLink: CADisplayLink?
    private var previousTimestamp: TimeInterval?
    private lazy var callbackTarget = HUDDisplayLinkCallbackTarget(owner: self)
    let diagnostics = HUDFrameDiagnostics()

    func attach(to view: NSView) {
        guard self.view !== view else { return }
        invalidate()
        self.view = view
        let link = view.displayLink(
            target: callbackTarget,
            selector: #selector(HUDDisplayLinkCallbackTarget.displayLinkDidFire(_:))
        )
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func requestFrames() {
        guard let displayLink else { return }
        let maximumFPS = view?.window?.screen?.maximumFramesPerSecond ?? 60
        diagnostics.begin(targetFramesPerSecond: maximumFPS)
        displayLink.preferredFrameRateRange = HUDDisplayRefreshPolicy.preferredRange(
            maximumFramesPerSecond: maximumFPS
        )
        previousTimestamp = nil
        displayLink.isPaused = false
    }

    func invalidate() {
        displayLink?.invalidate()
        displayLink = nil
        previousTimestamp = nil
    }

    deinit {
        displayLink?.invalidate()
    }

    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        let deltaTime: TimeInterval
        if let previousTimestamp {
            deltaTime = min(0.1, max(0, link.timestamp - previousTimestamp))
        } else {
            deltaTime = link.duration > 0 ? link.duration : 1 / 60
        }
        previousTimestamp = link.timestamp
        diagnostics.record(deltaTime: deltaTime)
        if onFrame?(deltaTime) != true {
#if DEBUG
            if let summary = diagnostics.summary() {
                hudLogger.debug(
                    "HUD frames target=\(summary.targetFramesPerSecond, privacy: .public) delivered=\(summary.deliveredFramesPerSecond, privacy: .public) p95_ms=\(summary.p95DeltaMilliseconds, privacy: .public) late_pct=\(summary.lateFramePercentage, privacy: .public) max_ms=\(summary.maximumDeltaMilliseconds, privacy: .public)"
                )
            }
#endif
            link.isPaused = true
            previousTimestamp = nil
        }
    }
}

@MainActor
private final class HUDDisplayLinkCallbackTarget: NSObject {
    weak var owner: HUDDisplayLinkClock?

    init(owner: HUDDisplayLinkClock) {
        self.owner = owner
    }

    @objc func displayLinkDidFire(_ link: CADisplayLink) {
        owner?.displayLinkDidFire(link)
    }
}

enum HUDLogoInteractionEvent: Equatable {
    case began(NSPoint)
    case moved(NSPoint)
    case ended(NSPoint)
    case clicked
}

struct HUDLogoPointerTracker {
    enum Completion: Equatable {
        case click
        case drag
    }

    static let dragThreshold: CGFloat = 4
    private(set) var startPoint: NSPoint?
    private(set) var isDragging = false

    mutating func begin(at point: NSPoint) {
        startPoint = point
        isDragging = false
    }

    mutating func update(to point: NSPoint) -> Bool {
        guard let startPoint else { return false }
        if !isDragging {
            let distance = hypot(point.x - startPoint.x, point.y - startPoint.y)
            guard distance >= Self.dragThreshold else { return false }
            isDragging = true
        }
        return true
    }

    mutating func end(at point: NSPoint) -> Completion? {
        guard startPoint != nil else { return nil }
        _ = update(to: point)
        let result: Completion = isDragging ? .drag : .click
        startPoint = nil
        isDragging = false
        return result
    }
}

enum HUDPanelLayout {
    static func size(
        for presentation: HUDPresentation,
        applicationName: String = "Cadence"
    ) -> NSSize {
        NSSize(
            width: HUDContentSizing.width(
                for: presentation,
                applicationName: applicationName
            ),
            height: HUDMetrics.panelHeight
        )
    }

    static func targetFrame(
        position: HUDPosition,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        size: NSSize
    ) -> NSRect {
        NSRect(
            origin: position.origin(screenFrame: screenFrame, visibleFrame: visibleFrame, hudSize: size),
            size: size
        )
    }

    static func interpolate(from: NSRect, to: NSRect, progress: Double) -> NSRect {
        let progress = CGFloat(max(0, min(1, progress)))
        return NSRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress
        )
    }

    static func subtitleOrigin(
        position: HUDPosition,
        pillFrame: NSRect,
        subtitleSize: NSSize = HUDMetrics.subtitleSize
    ) -> NSPoint {
        let x = pillFrame.midX - subtitleSize.width / 2
        switch position {
        case .topLeft, .topRight:
            return NSPoint(x: x, y: pillFrame.minY - HUDMetrics.subtitleGap - subtitleSize.height)
        case .bottomCenter, .bottomLeft, .bottomRight:
            return NSPoint(x: x, y: pillFrame.maxY + HUDMetrics.subtitleGap)
        }
    }
}

enum HUDLockIndicatorLayout {
    static let animationDuration: TimeInterval = 0.13

    static func shouldShow(for state: HUDVisualState) -> Bool {
        guard case .recording(let triggerMode, _) = state else { return false }
        return triggerMode.showsLockIndicator
    }

    static func waitsForPillExpansion(
        previous: HUDPresentation,
        current: HUDPresentation,
        hasActiveMorph: Bool
    ) -> Bool {
        guard hasActiveMorph, shouldShow(for: current.visualState) else { return false }
        guard case .idle = previous.visualState else { return false }
        return true
    }

    static func origin(
        position: HUDPosition,
        pillFrame: NSRect,
        indicatorSize: NSSize = HUDMetrics.lockIndicatorSize
    ) -> NSPoint {
        let x: CGFloat
        switch position {
        case .bottomCenter, .topLeft, .bottomLeft:
            x = pillFrame.maxX + HUDMetrics.lockIndicatorGap
        case .topRight, .bottomRight:
            x = pillFrame.minX - HUDMetrics.lockIndicatorGap - indicatorSize.width
        }
        return NSPoint(
            x: x,
            y: pillFrame.midY - indicatorSize.height / 2
        )
    }

    static func emergenceFrame(
        position: HUDPosition,
        pillFrame: NSRect,
        indicatorSize: NSSize = HUDMetrics.lockIndicatorSize
    ) -> NSRect {
        let startSize = NSSize(
            width: indicatorSize.width * 0.5,
            height: indicatorSize.height * 0.5
        )
        let centerX: CGFloat
        switch position {
        case .bottomCenter, .topLeft, .bottomLeft:
            centerX = pillFrame.maxX - startSize.width * 0.15
        case .topRight, .bottomRight:
            centerX = pillFrame.minX + startSize.width * 0.15
        }
        return NSRect(
            x: centerX - startSize.width / 2,
            y: pillFrame.midY - startSize.height / 2,
            width: startSize.width,
            height: startSize.height
        )
    }
}

enum HUDTooltipGeometry {
    static let gap: CGFloat = 12

    static func origin(
        position: HUDPosition,
        pillFrame: NSRect,
        tooltipSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let centeredX = pillFrame.midX - tooltipSize.width / 2
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - tooltipSize.width)
        let x = min(max(centeredX, visibleFrame.minX), maximumX)
        let y: CGFloat
        switch position {
        case .topLeft, .topRight:
            y = pillFrame.minY - gap - tooltipSize.height
        case .bottomCenter, .bottomLeft, .bottomRight:
            y = pillFrame.maxY + gap
        }
        return NSPoint(x: x, y: y)
    }
}

enum HUDScreenChangePolicy {
    static func shouldReposition(_ position: HUDPosition) -> Bool {
        true
    }
}

enum HUDDragGeometry {
    static func origin(
        startOrigin: NSPoint,
        startPointer: NSPoint,
        currentPointer: NSPoint
    ) -> NSPoint {
        NSPoint(
            x: startOrigin.x + currentPointer.x - startPointer.x,
            y: startOrigin.y + currentPointer.y - startPointer.y
        )
    }
}

struct HUDDragCompletion: Equatable {
    let position: HUDPosition
    let origin: NSPoint
}

struct HUDDragRuntime {
    private var startOrigin: NSPoint?
    private var startPointer: NSPoint?

    var isActive: Bool {
        startOrigin != nil && startPointer != nil
    }

    mutating func begin(panelOrigin: NSPoint, pointer: NSPoint) {
        startOrigin = panelOrigin
        startPointer = pointer
    }

    func moved(to pointer: NSPoint) -> NSPoint? {
        guard let startOrigin, let startPointer else { return nil }
        return HUDDragGeometry.origin(
            startOrigin: startOrigin,
            startPointer: startPointer,
            currentPointer: pointer
        )
    }

    func nearestPosition(
        panelFrame: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> HUDPosition? {
        guard isActive else { return nil }
        return HUDPosition.nearest(
            to: NSPoint(x: panelFrame.midX, y: panelFrame.midY),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hudSize: panelFrame.size
        )
    }

    mutating func complete(
        panelFrame: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> HUDDragCompletion? {
        guard isActive else { return nil }
        guard let position = nearestPosition(
            panelFrame: panelFrame,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ) else { return nil }
        let origin = position.origin(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hudSize: panelFrame.size
        )
        startOrigin = nil
        startPointer = nil
        return HUDDragCompletion(position: position, origin: origin)
    }

    mutating func cancel() {
        startOrigin = nil
        startPointer = nil
    }
}

enum HUDClickAwayPolicy {
    static func shouldCollapse(
        isExpanded: Bool,
        panelFrame: NSRect,
        pointer: NSPoint,
        isMenuWindow: Bool
    ) -> Bool {
        isExpanded && !panelFrame.contains(pointer) && !isMenuWindow
    }
}

enum HUDDragOverlayPolicy {
    static func shouldShow(isDragging: Bool, isOverlayVisible: Bool) -> Bool {
        isDragging && !isOverlayVisible
    }
}

enum HUDDragTooltipEligibility {
    static func shouldShow(successfulDictationCount: Int, hasBeenShown: Bool) -> Bool {
        successfulDictationCount >= 3 && !hasBeenShown
    }
}

final class HUDDragTooltipStateStore {
    static let key = "Cadence.dragTooltipShown"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hasBeenShown: Bool {
        defaults.bool(forKey: Self.key)
    }

    func markShown() {
        defaults.set(true, forKey: Self.key)
    }
}

enum HUDPanelTransition {
    static func shouldAnimate(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func duration(
        from previous: HUDPresentation,
        to current: HUDPresentation,
        motionTuning: HUDMotionTuning
    ) -> TimeInterval {
        if HUDActiveContentTransition.isActive(previous),
           HUDActiveContentTransition.isActive(current) {
            return HUDActiveContentTransition.duration
        }
        return motionTuning.pillResponse
    }
}

enum HUDPanelBoundsPolicy {
    static func appliesTargetBeforeMorph(currentWidth: CGFloat, targetWidth: CGFloat) -> Bool {
        targetWidth >= currentWidth
    }
}

final class HUDPositionStore {
    private static let key = "Cadence.hudPosition"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> HUDPosition {
        guard let raw = defaults.string(forKey: Self.key) else { return .bottomRight }
        return HUDPosition(rawValue: raw) ?? .bottomRight
    }

    func save(_ position: HUDPosition) {
        defaults.set(position.rawValue, forKey: Self.key)
    }
}

@MainActor
final class HUDWindowController {
    private struct MorphTransition {
        let targetFrame: NSRect
        let duration: TimeInterval
        var elapsed: TimeInterval
    }

    private var pillPanel: NSPanel?
    private var lockIndicatorPanel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var overlayPanel: NSPanel?
    private var tooltipPanel: NSPanel?
    private var pillHostingView: NSHostingView<HUDView>?
    private var lockIndicatorHostingView: NSHostingView<HUDLockIndicatorView>?
    private var subtitleHostingView: NSHostingView<HUDSubtitleView>?
    let viewModel = HUDViewModel()
    private let dropZoneViewModel = HUDDropZoneViewModel()
    private let positionStore: HUDPositionStore
    private let tooltipStateStore: HUDDragTooltipStateStore
    private var dragRuntime = HUDDragRuntime()
    private var screenChangeObserver: NSObjectProtocol?
    private var tooltipDismissTask: Task<Void, Never>?
    private var clickAwayMonitor: Any?
    private var idleCollapseTask: Task<Void, Never>?
    private let displayLinkClock = HUDDisplayLinkClock()
    private var appearancePreference: AppearancePreference
    private var morphTransition: MorphTransition?
    private var lockIndicatorWaitsForPillExpansion = false
    private var pendingActiveReplacementState: HUDState?
    private static let idleCollapseSeconds: UInt64 = 8
    private var isIdleSuppressed = false

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopyLast: (() -> Void)?
    var onAddToDictionary: (() -> Void)?
    var onHide: ((HUDHideDuration) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        appearancePreference: AppearancePreference = .system
    ) {
        self.positionStore = HUDPositionStore(defaults: defaults)
        self.tooltipStateStore = HUDDragTooltipStateStore(defaults: defaults)
        self.appearancePreference = appearancePreference
        viewModel.onLogoInteraction = { [weak self] event in
            self?.handleLogoInteraction(event)
        }
        viewModel.onExpandToggle = { [weak self] expanded, startWidth in
            self?.handleExpandedChanged(expanded, startWidth: startWidth)
        }
        viewModel.onCopyLast = { [weak self] in self?.onCopyLast?() }
        viewModel.onAddToDictionary = { [weak self] in self?.onAddToDictionary?() }
        viewModel.onHide = { [weak self] duration in self?.onHide?(duration) }
        viewModel.onMoveRequested = { [weak self] position in self?.move(to: position, announce: true) }
        viewModel.onAnimationRequested = { [weak self] in
            self?.displayLinkClock.requestFrames()
        }
        viewModel.onReducedMotionChanged = { [weak self] reduced in
            guard reduced else { return }
            self?.finishMorphImmediately()
        }
        displayLinkClock.onFrame = { [weak self] deltaTime in
            self?.advanceAnimations(deltaTime: deltaTime) ?? false
        }

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    private func handleScreenParametersChanged() {
        guard let pillPanel, pillPanel.isVisible else { return }
        let current = persistedPosition()
        guard HUDScreenChangePolicy.shouldReposition(current) else { return }
        setPanelFrameImmediately(
            pillPanel,
            size: viewModel.targetSize(for: viewModel.presentation)
        )
        if let subtitlePanel, subtitlePanel.isVisible {
            position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
        }
        if let lockIndicatorPanel, lockIndicatorPanel.isVisible {
            position(lockIndicatorPanel: lockIndicatorPanel, relativeTo: pillPanel)
        }
    }

    func setIdleSuppressed(_ suppressed: Bool) {
        isIdleSuppressed = suppressed
        if !suppressed {
            update(with: viewModel.state)
        } else if viewModel.state.visualState == .idle {
            pillPanel?.orderOut(nil)
            lockIndicatorPanel?.orderOut(nil)
            subtitlePanel?.orderOut(nil)
        }
    }

    func update(with state: HUDState) {
        applyAppearanceToPanels()
        let requestedPresentation = HUDPresentation(
            visualState: state.visualState,
            isExpanded: viewModel.isExpanded
        )
        if HUDActiveContentTransition.shouldDefer(
            current: viewModel.presentation,
            requested: requestedPresentation,
            isReplacementAnimating: morphTransition != nil && viewModel.isReplacingActiveContent
        ) {
            pendingActiveReplacementState = state
            return
        }
        let startsRecording: Bool
        if case .recording = requestedPresentation.visualState {
            startsRecording = true
        } else {
            startsRecording = false
        }
        if !HUDActiveContentTransition.isActive(requestedPresentation) || startsRecording {
            pendingActiveReplacementState = nil
        }

        let previousPresentation = viewModel.presentation
        let previousRenderedWidth = viewModel.renderedWidth
        let wasPresented = pillPanel?.isVisible == true
        let wasExpanded = viewModel.isExpanded
        viewModel.apply(state)
        if wasExpanded, !viewModel.isExpanded {
            removeClickAwayMonitor()
            cancelIdleCollapseTimer()
        }

        let idleBarVisible = HUDIdleVisibilityPolicy.shouldPresent(
            visualState: state.visualState,
            idleBarVisible: !isIdleSuppressed
        )
        guard state.isVisible, idleBarVisible else {
            morphTransition = nil
            pendingActiveReplacementState = nil
            lockIndicatorWaitsForPillExpansion = false
            viewModel.finishMorph()
            pillPanel?.orderOut(nil)
            lockIndicatorPanel?.orderOut(nil)
            subtitlePanel?.orderOut(nil)
            return
        }

        let pillPanel = makePillPanelIfNeeded()
        let targetSize = pillSize(for: state)

        if pillHostingView == nil {
            let hostingView = NSHostingView(rootView: HUDView(model: viewModel))
            // The panel owns the HUD's bounds. Leaving NSHostingView's default
            // intrinsic-content sizing enabled lets SwiftUI pull the host back
            // to the compact mic's 44 pt ideal width after the panel expands,
            // clipping the recording presentation inside a 280 pt window.
            hostingView.sizingOptions = []
            hostingView.frame = NSRect(
                origin: .zero,
                size: pillPanel.contentRect(forFrameRect: pillPanel.frame).size
            )
            hostingView.autoresizingMask = [.width, .height]
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            pillPanel.contentView = hostingView
            pillHostingView = hostingView
            displayLinkClock.attach(to: hostingView)
            if viewModel.hasPendingWaveformAnimation {
                displayLinkClock.requestFrames()
            }
        }

        let currentPresentation = viewModel.presentation
        if wasPresented, previousPresentation != currentPresentation {
            beginPanelTransition(
                panel: pillPanel,
                targetSize: targetSize,
                from: previousPresentation,
                startWidth: previousRenderedWidth
            )
        } else if morphTransition == nil {
            setPanelFrameImmediately(pillPanel, size: targetSize)
        }
        pillPanel.orderFrontRegardless()
        if !HUDLockIndicatorLayout.shouldShow(for: state.visualState) {
            lockIndicatorWaitsForPillExpansion = false
        } else if HUDLockIndicatorLayout.waitsForPillExpansion(
            previous: previousPresentation,
            current: currentPresentation,
            hasActiveMorph: morphTransition != nil
        ) {
            lockIndicatorWaitsForPillExpansion = true
        }
        if lockIndicatorWaitsForPillExpansion {
            lockIndicatorPanel?.orderOut(nil)
        } else {
            updateLockIndicator(for: state.visualState, relativeTo: pillPanel)
        }

        if state.showsSubtitle, !state.subtitle.isEmpty {
            let subtitlePanel = makeSubtitlePanelIfNeeded()
            if subtitleHostingView == nil {
                let hostingView = NSHostingView(rootView: HUDSubtitleView(model: viewModel))
                hostingView.frame = subtitlePanel.contentView?.bounds ?? .zero
                hostingView.autoresizingMask = [.width, .height]
                hostingView.wantsLayer = true
                hostingView.layer?.backgroundColor = NSColor.clear.cgColor
                subtitlePanel.contentView = hostingView
                subtitleHostingView = hostingView
            }

            position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
            subtitlePanel.orderFrontRegardless()
        } else {
            subtitlePanel?.orderOut(nil)
        }
    }

    private func makePillPanelIfNeeded() -> NSPanel {
        if let pillPanel {
            return pillPanel
        }

        let panel = makePanel(size: NSSize(width: HUDMetrics.compactWidth, height: HUDMetrics.panelHeight))
        pillPanel = panel
        return panel
    }

    private func makeSubtitlePanelIfNeeded() -> NSPanel {
        if let subtitlePanel {
            return subtitlePanel
        }

        let panel = makePanel(size: HUDMetrics.subtitleSize)
        subtitlePanel = panel
        return panel
    }

    private func makeLockIndicatorPanelIfNeeded() -> NSPanel {
        if let lockIndicatorPanel {
            return lockIndicatorPanel
        }

        let panel = makePanel(size: HUDMetrics.lockIndicatorSize)
        panel.ignoresMouseEvents = true
        let hostingView = NSHostingView(rootView: HUDLockIndicatorView())
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: HUDMetrics.lockIndicatorSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        lockIndicatorPanel = panel
        lockIndicatorHostingView = hostingView
        return panel
    }

    private func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = resolvedAppearance
        return panel
    }

    func setAppearancePreference(_ preference: AppearancePreference) {
        appearancePreference = preference
        applyAppearanceToPanels()
        pillHostingView?.needsDisplay = true
        lockIndicatorHostingView?.needsDisplay = true
        subtitleHostingView?.needsDisplay = true
    }

    private var resolvedAppearance: NSAppearance {
        appearancePreference.nsAppearance ?? NSApp.effectiveAppearance
    }

    private func applyAppearanceToPanels() {
        let appearance = resolvedAppearance
        pillPanel?.appearance = appearance
        lockIndicatorPanel?.appearance = appearance
        subtitlePanel?.appearance = appearance
        overlayPanel?.appearance = appearance
        tooltipPanel?.appearance = appearance
    }

    private func pillSize(for state: HUDState) -> NSSize {
        viewModel.targetSize(
            for: HUDPresentation(visualState: state.visualState, isExpanded: viewModel.isExpanded)
        )
    }

    private func position(pillPanel: NSPanel) {
        let hudPosition = persistedPosition()
        let screen = screen(for: pillPanel)
        let screenFrame = screen?.frame ?? .zero
        let visibleFrame = screen?.visibleFrame ?? .zero
        let origin = hudPosition.origin(screenFrame: screenFrame, visibleFrame: visibleFrame, hudSize: pillPanel.frame.size)
        pillPanel.setFrameOrigin(origin)
        viewModel.position = hudPosition
    }

    private func position(subtitlePanel: NSPanel, relativeTo pillPanel: NSPanel) {
        subtitlePanel.setFrameOrigin(
            HUDPanelLayout.subtitleOrigin(
                position: viewModel.position,
                pillFrame: pillPanel.frame
            )
        )
    }

    private func position(lockIndicatorPanel: NSPanel, relativeTo pillPanel: NSPanel) {
        let origin = HUDLockIndicatorLayout.origin(
            position: viewModel.position,
            pillFrame: pillPanel.frame,
            indicatorSize: HUDMetrics.lockIndicatorSize
        )
        lockIndicatorPanel.setFrame(
            NSRect(origin: origin, size: HUDMetrics.lockIndicatorSize),
            display: true
        )
    }

    private func updateLockIndicator(
        for state: HUDVisualState,
        relativeTo pillPanel: NSPanel
    ) {
        guard HUDLockIndicatorLayout.shouldShow(for: state) else {
            lockIndicatorPanel?.orderOut(nil)
            return
        }

        let panel = makeLockIndicatorPanelIfNeeded()
        let wasVisible = panel.isVisible
        let finalOrigin = HUDLockIndicatorLayout.origin(
            position: viewModel.position,
            pillFrame: pillPanel.frame
        )
        let finalFrame = NSRect(origin: finalOrigin, size: HUDMetrics.lockIndicatorSize)
        guard !wasVisible else {
            if panel.frame != finalFrame {
                panel.setFrame(finalFrame, display: true)
            }
            return
        }

        panel.setFrame(
            HUDLockIndicatorLayout.emergenceFrame(
                position: viewModel.position,
                pillFrame: pillPanel.frame
            ),
            display: true
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if viewModel.isReducedMotionEnabled {
            panel.setFrame(finalFrame, display: true)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = HUDLockIndicatorLayout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func targetScreen() -> NSScreen? {
        WindowPlacement.screen()
    }

    private func screen(for panel: NSPanel) -> NSScreen? {
        guard panel.isVisible else { return targetScreen() }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return WindowPlacement.screen(containing: center) ?? targetScreen()
    }

    private func persistedPosition() -> HUDPosition {
        positionStore.load()
    }

    private func handleLogoInteraction(_ event: HUDLogoInteractionEvent) {
        switch event {
        case .began(let point):
            beginDragSequence(at: point)
        case .moved(let point):
            handleDragChanged(pointer: point)
        case .ended:
            handleDragEnded()
        case .clicked:
            dragRuntime.cancel()
            viewModel.toggleExpanded()
        }
    }

    private func beginDragSequence(at pointer: NSPoint) {
        guard let pillPanel, !viewModel.isExpanded, viewModel.state.visualState == .idle else { return }
        dragRuntime.begin(panelOrigin: pillPanel.frame.origin, pointer: pointer)
    }

    private func handleDragChanged(pointer: NSPoint) {
        guard let pillPanel else { return }
        guard let newOrigin = dragRuntime.moved(to: pointer) else { return }
        if HUDDragOverlayPolicy.shouldShow(
            isDragging: dragRuntime.isActive,
            isOverlayVisible: overlayPanel?.isVisible == true
        ) {
            dismissDragTooltipForDrag()
            showDropZoneOverlay()
        }
        pillPanel.setFrameOrigin(newOrigin)
        updateDropZoneNearest(to: NSPoint(x: pillPanel.frame.midX, y: pillPanel.frame.midY))

        if let subtitlePanel, subtitlePanel.isVisible {
            position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
        }
        if let lockIndicatorPanel, lockIndicatorPanel.isVisible {
            position(lockIndicatorPanel: lockIndicatorPanel, relativeTo: pillPanel)
        }
    }

    private func handleDragEnded() {
        guard let pillPanel else { return }
        let hudCenter = NSPoint(x: pillPanel.frame.midX, y: pillPanel.frame.midY)
        let screen = WindowPlacement.screen(containing: hudCenter) ?? targetScreen()
        let screenFrame = screen?.frame ?? .zero
        let visibleFrame = screen?.visibleFrame ?? .zero
        guard let completion = dragRuntime.complete(
            panelFrame: pillPanel.frame,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ) else { return }
        pillPanel.setFrameOrigin(completion.origin)
        viewModel.position = completion.position
        positionStore.save(completion.position)
        hideDropZoneOverlay()
        markDragTooltipShown()
        if let lockIndicatorPanel, lockIndicatorPanel.isVisible {
            position(lockIndicatorPanel: lockIndicatorPanel, relativeTo: pillPanel)
        }
    }

    private func move(to position: HUDPosition, announce: Bool) {
        guard let pillPanel else { return }
        positionStore.save(position)
        viewModel.position = position
        setPanelFrameImmediately(pillPanel, size: viewModel.targetSize(for: viewModel.presentation))
        if let subtitlePanel, subtitlePanel.isVisible {
            self.position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
        }
        if let lockIndicatorPanel, lockIndicatorPanel.isVisible {
            self.position(lockIndicatorPanel: lockIndicatorPanel, relativeTo: pillPanel)
        }
        if announce {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: "Cadence moved to \(position.accessibilityName.lowercased())"]
            )
        }
    }

    private func showDropZoneOverlay() {
        guard let screen = pillPanel.flatMap({ screen(for: $0) }) ?? targetScreen() else { return }
        showDropZoneOverlay(on: screen)
    }

    private func showDropZoneOverlay(on screen: NSScreen) {
        let frame = screen.frame
        if overlayPanel == nil {
            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = true
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            let hostingView = NSHostingView(rootView: HUDDropZoneOverlay(model: dropZoneViewModel))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hostingView
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
            ])
            overlayPanel = panel
        }
        dropZoneViewModel.configure(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        overlayPanel?.setFrame(frame, display: true)
        overlayPanel?.orderFrontRegardless()
    }

    private func hideDropZoneOverlay() {
        dropZoneViewModel.nearestZone = nil
        overlayPanel?.orderOut(nil)
    }

    private func updateDropZoneNearest(to point: NSPoint) {
        guard let screen = WindowPlacement.screen(containing: point) ?? targetScreen() else { return }
        if dropZoneViewModel.screenFrame != screen.frame {
            showDropZoneOverlay(on: screen)
        }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        dropZoneViewModel.nearestZone = dragRuntime.nearestPosition(
            panelFrame: pillPanel?.frame ?? NSRect(origin: point, size: HUDMetrics.idleHitSize),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        )
    }

    func showDragTooltipIfEligible(successfulDictationCount: Int) {
        guard HUDDragTooltipEligibility.shouldShow(
            successfulDictationCount: successfulDictationCount,
            hasBeenShown: tooltipStateStore.hasBeenShown
        ) else { return }
        if showDragTooltip() {
            markDragTooltipShown()
        }
    }

    @discardableResult
    private func showDragTooltip() -> Bool {
        guard let pillPanel else { return false }
        let targetScreen = screen(for: pillPanel)
        showDropZoneOverlay()
        if tooltipPanel == nil {
            let panel = makePanel(size: NSSize(width: 200, height: 40))
            panel.level = .statusBar
            let hostingView = NSHostingView(rootView: HUDTooltipView(text: "Drag to any corner"))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hostingView
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
            ])
            tooltipPanel = panel
        }
        let tooltipSize = tooltipPanel?.frame.size ?? NSSize(width: 200, height: 40)
        let origin = HUDTooltipGeometry.origin(
            position: persistedPosition(),
            pillFrame: pillPanel.frame,
            tooltipSize: tooltipSize,
            visibleFrame: targetScreen?.visibleFrame ?? .zero
        )
        tooltipPanel?.setFrameOrigin(origin)
        tooltipPanel?.orderFrontRegardless()
        tooltipDismissTask?.cancel()
        tooltipDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.hideDragTooltip() }
        }
        return true
    }

    func hideDragTooltip() {
        tooltipPanel?.orderOut(nil)
        hideDropZoneOverlay()
        markDragTooltipShown()
        tooltipDismissTask?.cancel()
        tooltipDismissTask = nil
    }

    private func dismissDragTooltipForDrag() {
        tooltipPanel?.orderOut(nil)
        markDragTooltipShown()
        tooltipDismissTask?.cancel()
        tooltipDismissTask = nil
    }

    private func markDragTooltipShown() {
        tooltipStateStore.markShown()
    }

    // MARK: - Expandable Tray

    private func handleExpandedChanged(_ expanded: Bool, startWidth: CGFloat) {
        guard let pillPanel, viewModel.state.visualState == .idle else { return }
        let size = expanded ? HUDMetrics.expandedTraySize : HUDMetrics.idleHitSize
        beginPanelTransition(
            panel: pillPanel,
            targetSize: size,
            from: HUDPresentation(visualState: .idle, isExpanded: !expanded),
            startWidth: startWidth
        )
        if expanded {
            installClickAwayMonitor()
            startIdleCollapseTimer()
        } else {
            removeClickAwayMonitor()
            cancelIdleCollapseTimer()
        }
    }

    private func beginPanelTransition(
        panel: NSPanel,
        targetSize: NSSize,
        from previousPresentation: HUDPresentation,
        startWidth: CGFloat
    ) {
        let target = targetFrame(for: panel, size: targetSize)
        guard previousPresentation != viewModel.presentation || panel.frame != target else { return }
        if HUDPanelTransition.shouldAnimate(reduceMotion: viewModel.isReducedMotionEnabled) {
            viewModel.beginMorph(from: previousPresentation, startWidth: startWidth)
            let transitionDuration = HUDPanelTransition.duration(
                from: previousPresentation,
                to: viewModel.presentation,
                motionTuning: viewModel.motionTuning
            )
            // Resizing a translucent AppKit panel on every display-link callback is
            // substantially more expensive than animating its SwiftUI contents.
            // Move to the final transparent bounds once; anchored content preserves
            // the visible edge while the lightweight cross-fade runs at full refresh.
            let expandsBounds = HUDPanelBoundsPolicy.appliesTargetBeforeMorph(
                currentWidth: panel.frame.width,
                targetWidth: target.width
            )
            let changesPanelFrame = panel.frame != target
            if expandsBounds, changesPanelFrame {
                setPanelFrame(target, on: panel, display: true)
            }
            morphTransition = MorphTransition(
                targetFrame: target,
                duration: transitionDuration,
                elapsed: 0
            )
            if expandsBounds,
               changesPanelFrame,
               let subtitlePanel,
               subtitlePanel.isVisible {
                position(subtitlePanel: subtitlePanel, relativeTo: panel)
            }
            displayLinkClock.requestFrames()
        } else {
            morphTransition = nil
            setPanelFrame(target, on: panel, display: true)
            viewModel.finishMorph()
            restoreRestingMicIfNeeded()
        }
    }

    private func setPanelFrameImmediately(_ panel: NSPanel, size: NSSize) {
        morphTransition = nil
        let target = targetFrame(for: panel, size: size)
        if panel.frame != target {
            setPanelFrame(target, on: panel, display: true)
        }
        viewModel.finishMorph()
        restoreRestingMicIfNeeded()
    }

    private func setPanelFrame(_ frame: NSRect, on panel: NSPanel, display: Bool) {
        panel.setFrame(frame, display: display)
        guard panel === pillPanel, let pillHostingView else { return }
        pillHostingView.frame = NSRect(
            origin: .zero,
            size: panel.contentRect(forFrameRect: panel.frame).size
        )
        if let lockIndicatorPanel, lockIndicatorPanel.isVisible {
            position(lockIndicatorPanel: lockIndicatorPanel, relativeTo: panel)
        }
    }

    private func targetFrame(for panel: NSPanel, size: NSSize) -> NSRect {
        let position = persistedPosition()
        let screen = screen(for: panel)
        viewModel.position = position
        return HUDPanelLayout.targetFrame(
            position: position,
            screenFrame: screen?.frame ?? .zero,
            visibleFrame: screen?.visibleFrame ?? .zero,
            size: size
        )
    }

    private func advanceAnimations(deltaTime: TimeInterval) -> Bool {
        let waveformNeedsFrames = viewModel.advanceWaveform(deltaTime: deltaTime)
        var morphNeedsFrames = false
        if var transition = morphTransition {
            transition.elapsed += deltaTime
            let duration = transition.duration
            let linearProgress = min(1, transition.elapsed / duration)
            let easedProgress = HUDMotion.smoothProgress(
                elapsed: transition.elapsed,
                duration: duration
            )
            viewModel.setMorphProgress(easedProgress, elapsed: transition.elapsed)
            if linearProgress >= 1 {
                // Commit the resting SwiftUI presentation while the panel is
                // still using the wider frame. Its microphone occupies the
                // same screen-space anchor as the morphing microphone, so the
                // panel can then contract without a blank handoff frame.
                viewModel.finishMorph()
                pillHostingView?.needsLayout = true
                pillHostingView?.layoutSubtreeIfNeeded()
                if let pillPanel, pillPanel.frame != transition.targetFrame {
                    setPanelFrame(transition.targetFrame, on: pillPanel, display: true)
                    if let subtitlePanel, subtitlePanel.isVisible {
                        position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
                    }
                }
                morphTransition = nil
                restoreRestingMicIfNeeded()
                revealPendingLockIndicatorIfNeeded()
                presentPendingActiveReplacementIfNeeded()
            } else {
                morphTransition = transition
                morphNeedsFrames = true
            }
        }
        return waveformNeedsFrames || morphNeedsFrames
    }

    private func finishMorphImmediately() {
        guard let transition = morphTransition, let pillPanel else { return }
        morphTransition = nil
        viewModel.finishMorph()
        pillHostingView?.needsLayout = true
        pillHostingView?.layoutSubtreeIfNeeded()
        setPanelFrame(transition.targetFrame, on: pillPanel, display: true)
        restoreRestingMicIfNeeded()
        revealPendingLockIndicatorIfNeeded()
        presentPendingActiveReplacementIfNeeded()
    }

    private func presentPendingActiveReplacementIfNeeded() {
        guard let pendingActiveReplacementState else { return }
        self.pendingActiveReplacementState = nil
        update(with: pendingActiveReplacementState)
    }

    private func revealPendingLockIndicatorIfNeeded() {
        guard lockIndicatorWaitsForPillExpansion,
              let pillPanel,
              HUDLockIndicatorLayout.shouldShow(for: viewModel.state.visualState) else {
            return
        }
        lockIndicatorWaitsForPillExpansion = false
        updateLockIndicator(for: viewModel.state.visualState, relativeTo: pillPanel)
    }

    private func restoreRestingMicIfNeeded() {
        guard !isIdleSuppressed,
              viewModel.state.isVisible,
              viewModel.state.visualState == .idle,
              !viewModel.isExpanded,
              let pillPanel,
              let pillHostingView else {
            return
        }

        // Rebuild the resting SwiftUI tree after a completed AppKit/SwiftUI
        // morph. This clears any cached clipping or compositing state from the
        // wider presentation before the compact panel becomes stationary.
        pillHostingView.rootView = HUDView(model: viewModel)
        pillHostingView.alphaValue = 1
        pillHostingView.layer?.opacity = 1
        pillHostingView.needsLayout = true
        pillHostingView.layoutSubtreeIfNeeded()
        pillHostingView.needsDisplay = true
        pillPanel.alphaValue = 1
        pillPanel.orderFrontRegardless()
    }

    func showCopyConfirmation() {
        viewModel.showCopyConfirmation = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.viewModel.showCopyConfirmation = false
        }
    }

    private func installClickAwayMonitor() {
        removeClickAwayMonitor()
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let pillPanel = self.pillPanel, self.viewModel.isExpanded else { return event }
            let locationInWindow = NSEvent.mouseLocation
            if HUDClickAwayPolicy.shouldCollapse(
                isExpanded: self.viewModel.isExpanded,
                panelFrame: pillPanel.frame,
                pointer: locationInWindow,
                isMenuWindow: event.window !== pillPanel && Self.isMenuWindow(event.window)
            ) {
                self.viewModel.setExpanded(false)
            }
            return event
        }
    }

    private func removeClickAwayMonitor() {
        if let clickAwayMonitor {
            NSEvent.removeMonitor(clickAwayMonitor)
            self.clickAwayMonitor = nil
        }
    }

    private static func isMenuWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.className.contains("NSMenu")
    }

    private func startIdleCollapseTimer() {
        cancelIdleCollapseTimer()
        idleCollapseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleCollapseSeconds))
            guard !Task.isCancelled, let self else { return }
            self.viewModel.setExpanded(false)
        }
    }

    private func cancelIdleCollapseTimer() {
        idleCollapseTask?.cancel()
        idleCollapseTask = nil
    }
}

struct HUDTooltipView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.7))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

enum DictionaryFeedback: Equatable {
    case idle
    case capturing
    case added
    case nothingSelected
    case failed
}

struct HUDPresentation: Equatable {
    let visualState: HUDVisualState
    let isExpanded: Bool

    var exposesInteractiveChildren: Bool {
        visualState == .idle && isExpanded
    }
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state = HUDState.idle
    @Published private(set) var displayBars = Array(repeating: 0.0, count: 16)
    @Published var position: HUDPosition = .bottomCenter
    @Published var isExpanded = false
    @Published var canCopyLast = false
    @Published var showCopyConfirmation = false
    @Published var dictionaryFeedback: DictionaryFeedback = .idle
    @Published private(set) var morphProgress = 1.0
    @Published private(set) var morphElapsed: TimeInterval = 0
    @Published private(set) var morphStartWidth = HUDMetrics.statusWidth
    @Published private(set) var previousPresentation: HUDPresentation?
    @Published private(set) var applicationPresentation: HUDApplicationPresentation = .cadence
    @Published private(set) var motionTuning = HUDMotionTuning.default

    var onLogoInteraction: ((HUDLogoInteractionEvent) -> Void)?
    var onExpandToggle: ((Bool, CGFloat) -> Void)?
    var onCopyLast: (() -> Void)?
    var onAddToDictionary: (() -> Void)?
    var onHide: ((HUDHideDuration) -> Void)?
    var onAnimationRequested: (() -> Void)?
    var onReducedMotionChanged: ((Bool) -> Void)?
    var onMoveRequested: ((HUDPosition) -> Void)?

    private var targetBars = Array(repeating: 0.0, count: 16)
    private var reducedMotion = false
    private var hasPulsedThisSession = false
    private var activationSweepElapsed: TimeInterval?

    var reduceMotionProvider: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func setReducedMotion(_ reducedMotion: Bool) {
        guard self.reducedMotion != reducedMotion else { return }
        self.reducedMotion = reducedMotion

        if reducedMotion {
            activationSweepElapsed = nil
            displayBars = targetBars
        }
        onReducedMotionChanged?(reducedMotion)
    }

    func applyApplicationPresentation(_ presentation: HUDApplicationPresentation) {
        applicationPresentation = presentation
    }

    var isReducedMotionEnabled: Bool {
        reducedMotion || reduceMotionProvider()
    }

    func handleLogoInteraction(_ event: HUDLogoInteractionEvent) {
        guard state.visualState == .idle, !isExpanded else { return }
        onLogoInteraction?(event)
    }

    func toggleExpanded() {
        let startWidth = renderedWidth
        isExpanded.toggle()
        onExpandToggle?(isExpanded, startWidth)
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        let startWidth = renderedWidth
        isExpanded = expanded
        onExpandToggle?(isExpanded, startWidth)
    }

    func handleTrayBackgroundTap() {
        guard state.visualState == .idle, isExpanded else { return }
        setExpanded(false)
    }

    func requestCopyLast() {
        guard canCopyLast else { return }
        onCopyLast?()
    }

    func requestAddToDictionary() {
        guard dictionaryFeedback != .capturing else { return }
        onAddToDictionary?()
    }

    func requestHide(_ duration: HUDHideDuration) {
        onHide?(duration)
    }

    func requestMove(to position: HUDPosition) {
        onMoveRequested?(position)
    }

    var presentation: HUDPresentation {
        HUDPresentation(visualState: state.visualState, isExpanded: isExpanded)
    }

    var shouldMorphApplicationMark: Bool {
        guard previousPresentation?.visualState == .idle else { return false }
        if case .recording = presentation.visualState { return true }
        return false
    }

    var isCollapsingToRestingMic: Bool {
        guard presentation.visualState == .idle,
              !presentation.isExpanded,
              let previousPresentation else {
            return false
        }
        return previousPresentation.visualState != .idle
    }

    var isReplacingActiveContent: Bool {
        guard let previousPresentation else { return false }
        return previousPresentation.visualState != .idle
            && presentation.visualState != .idle
    }

    var isReplacingStatusContent: Bool {
        guard let previousPresentation else { return false }
        return HUDApplicationCueTransition.keepsCueStable(
            from: previousPresentation.visualState,
            to: presentation.visualState
        )
    }

    var renderedWidth: CGFloat {
        let targetWidth = targetWidth(for: presentation)
        guard previousPresentation != nil else { return targetWidth }
        return HUDMotion.interpolateWidth(
            from: morphStartWidth,
            to: targetWidth,
            progress: morphProgress
        )
    }

    func targetWidth(for presentation: HUDPresentation) -> CGFloat {
        HUDContentSizing.width(
            for: presentation,
            applicationName: applicationPresentation.displayName
        )
    }

    func targetSize(for presentation: HUDPresentation) -> NSSize {
        NSSize(width: targetWidth(for: presentation), height: HUDMetrics.panelHeight)
    }

    func beginMorph(from presentation: HUDPresentation, startWidth: CGFloat) {
        previousPresentation = presentation
        morphStartWidth = startWidth
        morphProgress = 0
        morphElapsed = 0
    }

    func setMorphProgress(_ progress: Double, elapsed: TimeInterval) {
        let next = max(0, min(1, progress))
        morphElapsed = max(0, elapsed)
        guard abs(next - morphProgress) >= 0.000_5 else { return }
        morphProgress = next
    }

    func finishMorph() {
        morphProgress = 1
        morphElapsed = 0
        previousPresentation = nil
        morphStartWidth = targetWidth(for: presentation)
    }

    func setMotionTuning(_ tuning: HUDMotionTuning) {
        motionTuning = tuning
    }

    var hasPendingWaveformAnimation: Bool {
        !isReducedMotionEnabled && (
            activationSweepElapsed != nil ||
            !HUDWaveformSmoother.isStable(current: displayBars, target: targetBars)
        )
    }

    func advanceWaveform(deltaTime: TimeInterval) -> Bool {
        guard !isReducedMotionEnabled, state.isVisible else { return false }
        if let elapsed = activationSweepElapsed {
            let nextElapsed = elapsed + deltaTime
            let revealDelay = motionTuning.pillResponse * 0.72
            if nextElapsed < revealDelay {
                activationSweepElapsed = nextElapsed
                displayBars = Array(repeating: 0.0, count: targetBars.count)
                return true
            }

            let sweepElapsed = nextElapsed - revealDelay
            let sweepProgress = min(1, sweepElapsed / HUDMotion.activationSweepDuration)
            displayBars = HUDMotion.activationSweepLevels(
                progress: sweepProgress,
                target: targetBars
            )
            if sweepProgress < 1 {
                activationSweepElapsed = nextElapsed
                return true
            }
            activationSweepElapsed = nil
            displayBars = targetBars
        }
        guard !HUDWaveformSmoother.isStable(current: displayBars, target: targetBars) else {
            displayBars = targetBars
            return false
        }
        let nextBars = zip(displayBars, targetBars).enumerated().map { index, pair in
            HUDWaveformSmoother.step(
                current: pair.0,
                target: pair.1,
                deltaTime: deltaTime,
                responseScale: HUDMotion.waveformResponseScale(forBar: index)
            )
        }
        if HUDWaveformSmoother.isStable(current: nextBars, target: targetBars) {
            displayBars = targetBars
            return false
        }
        displayBars = nextBars
        return true
    }

    func apply(_ state: HUDState) {
        let wasIdle = self.state.visualState == .idle
        self.state = state
        if state.visualState != .idle, wasIdle, isExpanded {
            isExpanded = false
        }
        targetBars = normalizedBars(from: state.waveformLevels)

        guard state.isVisible else {
            displayBars = Array(repeating: 0.0, count: 16)
            hasPulsedThisSession = false
            activationSweepElapsed = nil
            return
        }

        if isReducedMotionEnabled {
            displayBars = targetBars
            return
        }

        if !wasIdle, state.visualState == .idle {
            hasPulsedThisSession = false
            activationSweepElapsed = nil
        }

        if wasIdle, !hasPulsedThisSession, isRecordingState, !isReducedMotionEnabled {
            displayBars = Array(repeating: 0.0, count: targetBars.count)
            activationSweepElapsed = 0
            hasPulsedThisSession = true
        }
        if hasPendingWaveformAnimation {
            onAnimationRequested?()
        }
    }

    private var isRecordingState: Bool {
        if case .recording = state.visualState {
            return true
        }
        return false
    }

    private func normalizedBars(from levels: [Double]) -> [Double] {
        let bars = levels.isEmpty ? Array(repeating: 0.0, count: 16) : levels
        return HUDMotion.characterizedWaveformLevels(
            bars.map { max(0, min(1, $0)) }
        )
    }
}

struct HUDSubtitleView: View {
    @ObservedObject var model: HUDViewModel

    var body: some View {
        Text(model.state.subtitle)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.85))
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 320, height: 36, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 30 / 255, green: 28 / 255, blue: 26 / 255, opacity: 0.78))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }
}
