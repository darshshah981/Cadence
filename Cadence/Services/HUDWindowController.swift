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
    static func step(current: Double, target: Double, deltaTime: TimeInterval) -> Double {
        let clampedTarget = max(0, min(1, target))
        let rate = clampedTarget > current ? HUDMotion.waveformAttackRate : HUDMotion.waveformReleaseRate
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
        return CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
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
    static func size(for presentation: HUDPresentation) -> NSSize {
        switch presentation.visualState {
        case .idle:
            return presentation.isExpanded ? HUDMetrics.expandedTraySize : HUDMetrics.idleHitSize
        case .recording(let triggerMode, let showsHint):
            switch triggerMode {
            case .tapToStartStop:
                return NSSize(width: HUDMetrics.compactWidth, height: HUDMetrics.pillHeight)
            case .holdToTalk:
                return NSSize(
                    width: showsHint ? HUDMetrics.holdHintWidth : HUDMetrics.compactWidth,
                    height: HUDMetrics.pillHeight
                )
            }
        case .preparingModel, .transcribing, .inserting, .success, .cancelled, .error:
            return NSSize(width: HUDMetrics.statusWidth, height: HUDMetrics.pillHeight)
        }
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
        let startFrame: NSRect
        let targetFrame: NSRect
        var elapsed: TimeInterval
    }

    private var pillPanel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var overlayPanel: NSPanel?
    private var tooltipPanel: NSPanel?
    private var pillHostingView: NSHostingView<HUDView>?
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
    private var morphTransition: MorphTransition?
    private static let idleCollapseSeconds: UInt64 = 8
    private var isIdleSuppressed = false

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopyLast: (() -> Void)?
    var onAddToDictionary: (() -> Void)?
    var onHide: ((HUDHideDuration) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.positionStore = HUDPositionStore(defaults: defaults)
        self.tooltipStateStore = HUDDragTooltipStateStore(defaults: defaults)
        viewModel.onLogoInteraction = { [weak self] event in
            self?.handleLogoInteraction(event)
        }
        viewModel.onExpandToggle = { [weak self] expanded in
            self?.handleExpandedChanged(expanded)
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
            size: HUDPanelLayout.size(for: viewModel.presentation)
        )
        if let subtitlePanel, subtitlePanel.isVisible {
            position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
        }
    }

    func setIdleSuppressed(_ suppressed: Bool) {
        isIdleSuppressed = suppressed
        if !suppressed {
            update(with: viewModel.state)
        } else if viewModel.state.visualState == .idle {
            pillPanel?.orderOut(nil)
            subtitlePanel?.orderOut(nil)
        }
    }

    func update(with state: HUDState) {
        let previousPresentation = viewModel.presentation
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
            viewModel.finishMorph()
            pillPanel?.orderOut(nil)
            subtitlePanel?.orderOut(nil)
            return
        }

        let pillPanel = makePillPanelIfNeeded()
        let targetSize = pillSize(for: state)

        if pillHostingView == nil {
            let hostingView = NSHostingView(rootView: HUDView(model: viewModel))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            pillPanel.contentView = hostingView
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: pillPanel.contentView!.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: pillPanel.contentView!.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: pillPanel.contentView!.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: pillPanel.contentView!.bottomAnchor)
            ])
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
                from: previousPresentation
            )
        } else if morphTransition == nil {
            setPanelFrameImmediately(pillPanel, size: targetSize)
        }
        pillPanel.orderFrontRegardless()

        if state.showsSubtitle, !state.subtitle.isEmpty {
            let subtitlePanel = makeSubtitlePanelIfNeeded()
            if subtitleHostingView == nil {
                let hostingView = NSHostingView(rootView: HUDSubtitleView(model: viewModel))
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                hostingView.wantsLayer = true
                hostingView.layer?.backgroundColor = NSColor.clear.cgColor
                subtitlePanel.contentView = hostingView
                NSLayoutConstraint.activate([
                    hostingView.leadingAnchor.constraint(equalTo: subtitlePanel.contentView!.leadingAnchor),
                    hostingView.trailingAnchor.constraint(equalTo: subtitlePanel.contentView!.trailingAnchor),
                    hostingView.topAnchor.constraint(equalTo: subtitlePanel.contentView!.topAnchor),
                    hostingView.bottomAnchor.constraint(equalTo: subtitlePanel.contentView!.bottomAnchor)
                ])
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

        let panel = makePanel(size: NSSize(width: HUDMetrics.compactWidth, height: HUDMetrics.pillHeight))
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
        return panel
    }

    private func pillSize(for state: HUDState) -> NSSize {
        HUDPanelLayout.size(
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
    }

    private func move(to position: HUDPosition, announce: Bool) {
        guard let pillPanel else { return }
        positionStore.save(position)
        viewModel.position = position
        setPanelFrameImmediately(pillPanel, size: HUDPanelLayout.size(for: viewModel.presentation))
        if let subtitlePanel, subtitlePanel.isVisible {
            self.position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
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

    private func handleExpandedChanged(_ expanded: Bool) {
        guard let pillPanel, viewModel.state.visualState == .idle else { return }
        let size = expanded ? HUDMetrics.expandedTraySize : HUDMetrics.idleHitSize
        beginPanelTransition(
            panel: pillPanel,
            targetSize: size,
            from: HUDPresentation(visualState: .idle, isExpanded: !expanded)
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
        from previousPresentation: HUDPresentation
    ) {
        let target = targetFrame(for: panel, size: targetSize)
        guard previousPresentation != viewModel.presentation || panel.frame != target else { return }
        if HUDPanelTransition.shouldAnimate(reduceMotion: viewModel.isReducedMotionEnabled) {
            viewModel.beginMorph(from: previousPresentation)
            morphTransition = MorphTransition(
                startFrame: panel.frame,
                targetFrame: target,
                elapsed: 0
            )
            displayLinkClock.requestFrames()
        } else {
            morphTransition = nil
            panel.setFrame(target, display: true)
            viewModel.finishMorph()
        }
    }

    private func setPanelFrameImmediately(_ panel: NSPanel, size: NSSize) {
        morphTransition = nil
        let target = targetFrame(for: panel, size: size)
        if panel.frame != target {
            panel.setFrame(target, display: true)
        }
        viewModel.finishMorph()
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
        if var transition = morphTransition, let pillPanel {
            transition.elapsed += deltaTime
            let linearProgress = min(1, transition.elapsed / HUDMotion.morphDuration)
            let easedProgress = HUDMotion.easeOutCubic(linearProgress)
            let frame = HUDPanelLayout.interpolate(
                from: transition.startFrame,
                to: transition.targetFrame,
                progress: easedProgress
            )
            pillPanel.setFrame(frame, display: false, animate: false)
            viewModel.setMorphProgress(easedProgress)
            if let subtitlePanel, subtitlePanel.isVisible {
                position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
            }
            if linearProgress >= 1 {
                pillPanel.setFrame(transition.targetFrame, display: true)
                viewModel.finishMorph()
                morphTransition = nil
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
        pillPanel.setFrame(transition.targetFrame, display: true)
        viewModel.finishMorph()
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
    @Published private(set) var previousPresentation: HUDPresentation?
    @Published private(set) var applicationPresentation: HUDApplicationPresentation = .cadence

    var onLogoInteraction: ((HUDLogoInteractionEvent) -> Void)?
    var onExpandToggle: ((Bool) -> Void)?
    var onCopyLast: (() -> Void)?
    var onAddToDictionary: (() -> Void)?
    var onHide: ((HUDHideDuration) -> Void)?
    var onAnimationRequested: (() -> Void)?
    var onReducedMotionChanged: ((Bool) -> Void)?
    var onMoveRequested: ((HUDPosition) -> Void)?

    private var targetBars = Array(repeating: 0.0, count: 16)
    private var reducedMotion = false
    private var hasPulsedThisSession = false

    var reduceMotionProvider: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static let activationPulseBars: [Double] = [
        0.05, 0.15, 0.30, 0.50, 0.70, 0.85, 0.95, 0.90,
        0.90, 0.95, 0.85, 0.70, 0.50, 0.30, 0.15, 0.05
    ]

    func setReducedMotion(_ reducedMotion: Bool) {
        guard self.reducedMotion != reducedMotion else { return }
        self.reducedMotion = reducedMotion

        if reducedMotion {
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
        isExpanded.toggle()
        onExpandToggle?(isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        onExpandToggle?(isExpanded)
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

    func beginMorph(from presentation: HUDPresentation) {
        previousPresentation = presentation
        morphProgress = 0
    }

    func setMorphProgress(_ progress: Double) {
        let next = max(0, min(1, progress))
        guard abs(next - morphProgress) >= 0.000_5 else { return }
        morphProgress = next
    }

    func finishMorph() {
        morphProgress = 1
        previousPresentation = nil
    }

    var hasPendingWaveformAnimation: Bool {
        !isReducedMotionEnabled && !HUDWaveformSmoother.isStable(current: displayBars, target: targetBars)
    }

    func advanceWaveform(deltaTime: TimeInterval) -> Bool {
        guard !isReducedMotionEnabled, state.isVisible else { return false }
        guard !HUDWaveformSmoother.isStable(current: displayBars, target: targetBars) else {
            displayBars = targetBars
            return false
        }
        let nextBars = zip(displayBars, targetBars).map { pair in
            HUDWaveformSmoother.step(current: pair.0, target: pair.1, deltaTime: deltaTime)
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
            return
        }

        if isReducedMotionEnabled {
            displayBars = targetBars
            return
        }

        if !wasIdle, state.visualState == .idle {
            hasPulsedThisSession = false
        }

        if wasIdle, !hasPulsedThisSession, isRecordingState, !isReducedMotionEnabled {
            displayBars = Self.activationPulseBars
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
        return bars.map { max(0, min(1, $0)) }
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
