import AppKit
import SwiftUI

enum HUDMetrics {
    static let pillHeight: CGFloat = 38
    static let compactWidth: CGFloat = 176
    static let holdHintWidth: CGFloat = 260
    static let statusWidth: CGFloat = 236
}

@MainActor
final class HUDWindowController {
    private enum Metrics {
        static let logoIdleSize = NSSize(width: 44, height: 44)
        static let holdSize = NSSize(width: HUDMetrics.compactWidth, height: HUDMetrics.pillHeight)
        static let holdHintSize = NSSize(width: HUDMetrics.holdHintWidth, height: HUDMetrics.pillHeight)
        static let lockedSize = NSSize(width: HUDMetrics.compactWidth, height: HUDMetrics.pillHeight)
        static let statusSize = NSSize(width: HUDMetrics.statusWidth, height: HUDMetrics.pillHeight)
        static let subtitleSize = NSSize(width: 320, height: 36)
        static let subtitleGap: CGFloat = 8
    }

    private enum PreferenceKey {
        static let hudPosition = "Cadence.hudPosition"
    }

    private var pillPanel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var pillHostingView: NSHostingView<HUDView>?
    private var subtitleHostingView: NSHostingView<HUDSubtitleView>?
    private let viewModel = HUDViewModel()
    private let defaults = UserDefaults.standard
    private var dragStartOrigin: NSPoint?
    private var screenChangeObserver: NSObjectProtocol?

    init() {
        viewModel.onDrag = { [weak self] translation in
            self?.handleDragChanged(translation)
        }
        viewModel.onDragEnded = { [weak self] in
            self?.handleDragEnded()
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenParametersChanged()
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

    func update(with state: HUDState) {
        viewModel.apply(state)

        guard state.isVisible else {
            pillPanel?.orderOut(nil)
            subtitlePanel?.orderOut(nil)
            return
        }

        let pillPanel = makePillPanelIfNeeded()
        pillPanel.setContentSize(pillSize(for: state))

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

        position(pillPanel: pillPanel)
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
            return Metrics.logoIdleSize
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
        let screen = targetScreen()
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

    private func persistedPosition() -> HUDPosition {
        let raw = defaults.string(forKey: PreferenceKey.hudPosition) ?? HUDPosition.bottomCenter.rawValue
        return HUDPosition(rawValue: raw) ?? .bottomCenter
    }

    private func handleDragChanged(_ translation: CGSize) {
        guard let pillPanel else { return }

        if dragStartOrigin == nil {
            dragStartOrigin = pillPanel.frame.origin
        }

        guard let dragStartOrigin else { return }
        let newOrigin = NSPoint(
            x: dragStartOrigin.x + translation.width,
            y: dragStartOrigin.y + translation.height
        )
        pillPanel.setFrameOrigin(newOrigin)

        if let subtitlePanel, subtitlePanel.isVisible {
            position(subtitlePanel: subtitlePanel, relativeTo: pillPanel)
        }
    }

    private func handleDragEnded() {
        guard let pillPanel else { return }
        let screen = targetScreen()
        let screenFrame = screen?.frame ?? .zero
        let visibleFrame = screen?.visibleFrame ?? .zero
        let hudCenter = NSPoint(x: pillPanel.frame.midX, y: pillPanel.frame.midY)
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
        defaults.set(snapPosition.rawValue, forKey: PreferenceKey.hudPosition)
        dragStartOrigin = nil
    }
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state = HUDState.idle
    @Published private(set) var displayBars = Array(repeating: 0.0, count: 16)
    @Published var position: HUDPosition = .bottomCenter

    var onDrag: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var targetBars = Array(repeating: 0.0, count: 16)
    private var smoothingTask: Task<Void, Never>?
    private var reducedMotion = false

    func setReducedMotion(_ reducedMotion: Bool) {
        guard self.reducedMotion != reducedMotion else { return }
        self.reducedMotion = reducedMotion

        if reducedMotion {
            smoothingTask?.cancel()
            smoothingTask = nil
            displayBars = targetBars
        }
    }

    func apply(_ state: HUDState) {
        self.state = state
        targetBars = normalizedBars(from: state.waveformLevels)

        guard state.isVisible else {
            displayBars = Array(repeating: 0.0, count: 16)
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
