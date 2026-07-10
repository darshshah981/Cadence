import AppKit
import SwiftUI

enum HUDMetrics {
    static let pillHeight: CGFloat = 38
    static let compactWidth: CGFloat = 176
    static let holdHintWidth: CGFloat = 260
    static let statusWidth: CGFloat = 236
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
        guard let raw = defaults.string(forKey: Self.key) else { return .bottomCenter }
        return HUDPosition(rawValue: raw) ?? .bottomCenter
    }

    func save(_ position: HUDPosition) {
        defaults.set(position.rawValue, forKey: Self.key)
    }
}

@MainActor
final class HUDWindowController {
    private enum Metrics {
        static let logoIdleSize = NSSize(width: 44, height: 44)
        static let expandedTraySize = NSSize(width: 240, height: HUDMetrics.pillHeight)
        static let controlsSize = NSSize(width: 188, height: HUDMetrics.pillHeight)
        static let holdSize = NSSize(width: HUDMetrics.compactWidth, height: HUDMetrics.pillHeight)
        static let holdHintSize = NSSize(width: HUDMetrics.holdHintWidth, height: HUDMetrics.pillHeight)
        static let lockedSize = NSSize(width: HUDMetrics.compactWidth, height: HUDMetrics.pillHeight)
        static let statusSize = NSSize(width: HUDMetrics.statusWidth, height: HUDMetrics.pillHeight)
        static let subtitleSize = NSSize(width: 320, height: 36)
        static let subtitleGap: CGFloat = 8
    }

    private var pillPanel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var overlayPanel: NSPanel?
    private var tooltipPanel: NSPanel?
    private var pillHostingView: NSHostingView<HUDView>?
    private var subtitleHostingView: NSHostingView<HUDSubtitleView>?
    let viewModel = HUDViewModel()
    private let dropZoneViewModel = HUDDropZoneViewModel()
    private let defaults: UserDefaults
    private let positionStore: HUDPositionStore
    private var dragStartOrigin: NSPoint?
    private var dragStartPointer: NSPoint?
    private var screenChangeObserver: NSObjectProtocol?
    private var tooltipDismissTask: Task<Void, Never>?
    private var clickAwayMonitor: Any?
    private var idleCollapseTask: Task<Void, Never>?
    private static let idleCollapseSeconds: UInt64 = 8
    private var isSuppressed = false

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCopyLast: (() -> Void)?
    var onAddToDictionary: (() -> Void)?
    var onHide: ((HUDHideDuration) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.positionStore = HUDPositionStore(defaults: defaults)
        viewModel.onLogoInteraction = { [weak self] event in
            self?.handleLogoInteraction(event)
        }
        viewModel.onExpandToggle = { [weak self] expanded in
            self?.handleExpandedChanged(expanded)
        }
        viewModel.onCopyLast = { [weak self] in self?.onCopyLast?() }
        viewModel.onAddToDictionary = { [weak self] in self?.onAddToDictionary?() }
        viewModel.onHide = { [weak self] duration in self?.onHide?(duration) }

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
        guard current == .bottomCenter else { return }
        position(pillPanel: pillPanel)
    }

    func setSuppressed(_ suppressed: Bool) {
        isSuppressed = suppressed
        if !suppressed {
            update(with: viewModel.state)
        }
    }

    func update(with state: HUDState) {
        viewModel.apply(state)

        guard state.isVisible, !isSuppressed else {
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
        } else {
            pillHostingView?.rootView = HUDView(model: viewModel)
        }

        setPanelFrame(pillPanel, size: targetSize, animated: false)
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
            } else {
                subtitleHostingView?.rootView = HUDSubtitleView(model: viewModel)
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

        let panel = makePanel(size: Metrics.holdSize)
        pillPanel = panel
        return panel
    }

    private func makeSubtitlePanelIfNeeded() -> NSPanel {
        if let subtitlePanel {
            return subtitlePanel
        }

        let panel = makePanel(size: Metrics.subtitleSize)
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
        switch state.visualState {
        case .idle:
            return viewModel.isExpanded ? Metrics.expandedTraySize : Metrics.logoIdleSize
        case .recording(let triggerMode, let showsHint):
            switch triggerMode {
            case .tapToStartStop:
                return Metrics.lockedSize
            case .holdToTalk:
                return showsHint ? Metrics.holdHintSize : Metrics.holdSize
            }
        case .preparingModel, .transcribing, .inserting, .success, .cancelled, .error:
            return Metrics.statusSize
        }
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
        let origin = NSPoint(
            x: pillPanel.frame.midX - Metrics.subtitleSize.width / 2,
            y: pillPanel.frame.maxY + Metrics.subtitleGap
        )
        subtitlePanel.setFrameOrigin(origin)
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
            dragStartOrigin = nil
            dragStartPointer = nil
            viewModel.toggleExpanded()
        }
    }

    private func beginDragSequence(at pointer: NSPoint) {
        guard let pillPanel, !viewModel.isExpanded, viewModel.state.visualState == .idle else { return }
        dragStartOrigin = pillPanel.frame.origin
        dragStartPointer = pointer
    }

    private func handleDragChanged(pointer: NSPoint) {
        guard let pillPanel else { return }
        guard let dragStartOrigin, let dragStartPointer else { return }
        if overlayPanel?.isVisible != true {
            dismissDragTooltipForDrag()
            showDropZoneOverlay()
        }
        let newOrigin = HUDDragGeometry.origin(
            startOrigin: dragStartOrigin,
            startPointer: dragStartPointer,
            currentPointer: pointer
        )
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
        let snapPosition = HUDPosition.nearest(
            to: hudCenter,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hudSize: pillPanel.frame.size
        )
        let origin = snapPosition.origin(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hudSize: pillPanel.frame.size
        )
        pillPanel.setFrameOrigin(origin)
        viewModel.position = snapPosition
        positionStore.save(snapPosition)
        hideDropZoneOverlay()
        markDragTooltipShown()
        dragStartOrigin = nil
        dragStartPointer = nil
    }

    private func showDropZoneOverlay() {
        guard let screen = targetScreen() else { return }
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
        overlayPanel?.setFrame(frame, display: true)
        overlayPanel?.orderFrontRegardless()
    }

    private func hideDropZoneOverlay() {
        dropZoneViewModel.nearestZone = nil
        overlayPanel?.orderOut(nil)
    }

    private func updateDropZoneNearest(to point: NSPoint) {
        guard let screen = targetScreen() else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let hudSize = pillPanel?.frame.size ?? Metrics.logoIdleSize
        dropZoneViewModel.nearestZone = HUDPosition.nearest(
            to: point,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hudSize: hudSize
        )
    }

    func showDragTooltip() {
        guard !defaults.bool(forKey: "Cadence.dragTooltipShown") else { return }
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
        if let pillPanel {
            let origin = NSPoint(
                x: pillPanel.frame.midX - 100,
                y: pillPanel.frame.maxY + 12
            )
            tooltipPanel?.setFrameOrigin(origin)
        }
        tooltipPanel?.orderFrontRegardless()
        tooltipDismissTask?.cancel()
        tooltipDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.hideDragTooltip() }
        }
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
        defaults.set(true, forKey: "Cadence.dragTooltipShown")
    }

    // MARK: - Expandable Tray

    private func handleExpandedChanged(_ expanded: Bool) {
        guard let pillPanel, viewModel.state.visualState == .idle else { return }
        let size = expanded ? Metrics.expandedTraySize : Metrics.logoIdleSize
        setPanelFrame(
            pillPanel,
            size: size,
            animated: HUDPanelTransition.shouldAnimate(reduceMotion: viewModel.isReducedMotionEnabled)
        )
        if expanded {
            installClickAwayMonitor()
            startIdleCollapseTimer()
        } else {
            removeClickAwayMonitor()
            cancelIdleCollapseTimer()
        }
    }

    private func setPanelFrame(_ panel: NSPanel, size: NSSize, animated: Bool) {
        let position = persistedPosition()
        let screen = screen(for: panel)
        let target = HUDPanelLayout.targetFrame(
            position: position,
            screenFrame: screen?.frame ?? .zero,
            visibleFrame: screen?.visibleFrame ?? .zero,
            size: size
        )
        viewModel.position = position
        guard animated else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0, 0, 1)
            panel.animator().setFrame(target, display: true)
        }
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
            if pillPanel.frame.contains(locationInWindow) { return event }
            if event.window !== pillPanel, Self.isMenuWindow(event.window) { return event }
            self.viewModel.setExpanded(false)
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

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state = HUDState.idle
    @Published private(set) var displayBars = Array(repeating: 0.0, count: 16)
    @Published var position: HUDPosition = .bottomCenter
    @Published var isExpanded = false
    @Published var canCopyLast = false
    @Published var showCopyConfirmation = false
    @Published var dictionaryFeedback: DictionaryFeedback = .idle

    var onLogoInteraction: ((HUDLogoInteractionEvent) -> Void)?
    var onExpandToggle: ((Bool) -> Void)?
    var onCopyLast: (() -> Void)?
    var onAddToDictionary: (() -> Void)?
    var onHide: ((HUDHideDuration) -> Void)?

    private var targetBars = Array(repeating: 0.0, count: 16)
    private var smoothingTask: Task<Void, Never>?
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
            smoothingTask?.cancel()
            smoothingTask = nil
            displayBars = targetBars
        }
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

    func apply(_ state: HUDState) {
        let wasIdle = self.state.visualState == .idle
        self.state = state
        if state.visualState != .idle, wasIdle, isExpanded {
            setExpanded(false)
        }
        targetBars = normalizedBars(from: state.waveformLevels)

        guard state.isVisible else {
            displayBars = Array(repeating: 0.0, count: 16)
            hasPulsedThisSession = false
            smoothingTask?.cancel()
            smoothingTask = nil
            return
        }

        if reducedMotion {
            displayBars = targetBars
            smoothingTask?.cancel()
            smoothingTask = nil
            return
        }

        if !wasIdle, state.visualState == .idle {
            hasPulsedThisSession = false
        }

        if wasIdle, !hasPulsedThisSession, isRecordingState, !isReducedMotionEnabled {
            displayBars = Self.activationPulseBars
            hasPulsedThisSession = true
        }

        guard smoothingTask == nil else { return }
        smoothingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                var changed = false
                for index in displayBars.indices {
                    let target = targetBars.indices.contains(index) ? targetBars[index] : 0
                    let current = displayBars[index]
                    let delta = target - current
                    if abs(delta) > 0.001 {
                        let factor = delta > 0 ? 0.4 : 0.08
                        displayBars[index] = max(0, min(1, current + delta * factor))
                        changed = true
                    } else {
                        displayBars[index] = target
                    }
                }

                if !state.isVisible {
                    break
                }

                if !changed, !isRecordingState {
                    break
                }

                try? await Task.sleep(for: .milliseconds(16))
            }

            smoothingTask = nil
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
