import AppKit
import SwiftUI

@MainActor
final class HUDWindowController {
    private enum Metrics {
        static let pillHeight: CGFloat = 38
        static let holdSize = NSSize(width: 140, height: pillHeight)
        static let holdHintSize = NSSize(width: 228, height: pillHeight)
        static let controlsSize = NSSize(width: 188, height: pillHeight)
        static let statusSize = NSSize(width: 196, height: pillHeight)
        static let subtitleSize = NSSize(width: 320, height: 36)
        static let bottomInset: CGFloat = 32
        static let subtitleGap: CGFloat = 8
    }

    private enum PreferenceKey {
        static let offsetX = "FlowState.hudOffsetX"
        static let offsetY = "FlowState.hudOffsetY"
    }

    private var pillPanel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var pillHostingView: NSHostingView<HUDView>?
    private var subtitleHostingView: NSHostingView<HUDSubtitleView>?
    private let viewModel = HUDViewModel()
    private let defaults = UserDefaults.standard
    private var dragStartOrigin: NSPoint?

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        viewModel.onStop = { [weak self] in self?.onStop?() }
        viewModel.onCancel = { [weak self] in self?.onCancel?() }
        viewModel.onDrag = { [weak self] translation in
            self?.handleDragChanged(translation)
        }
        viewModel.onDragEnded = { [weak self] in
            self?.handleDragEnded()
        }
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
        case .recording(let triggerMode, let showsHint):
            switch triggerMode {
            case .tapToStartStop:
                return Metrics.controlsSize
            case .holdToTalk:
                return showsHint ? Metrics.holdHintSize : Metrics.holdSize
            }
        case .transcribing, .error:
            return Metrics.statusSize
        }
    }

    private func position(pillPanel: NSPanel) {
        let defaultOrigin = centeredOrigin(for: pillPanel.frame.size)
        let offset = persistedOffset()
        let frame = targetScreenFrame()

        var origin = NSPoint(x: defaultOrigin.x + offset.x, y: defaultOrigin.y + offset.y)
        origin.x = min(max(origin.x, frame.minX), frame.maxX - pillPanel.frame.width)
        origin.y = min(max(origin.y, frame.minY), frame.maxY - pillPanel.frame.height)
        pillPanel.setFrameOrigin(origin)
    }

    private func position(subtitlePanel: NSPanel, relativeTo pillPanel: NSPanel) {
        let origin = NSPoint(
            x: pillPanel.frame.midX - Metrics.subtitleSize.width / 2,
            y: pillPanel.frame.maxY + Metrics.subtitleGap
        )
        subtitlePanel.setFrameOrigin(origin)
    }

    private func centeredOrigin(for size: NSSize) -> NSPoint {
        let frame = targetScreenFrame()
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + Metrics.bottomInset
        )
    }

    private func targetScreenFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        return (screen ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    private func persistedOffset() -> CGPoint {
        CGPoint(
            x: defaults.double(forKey: PreferenceKey.offsetX),
            y: defaults.double(forKey: PreferenceKey.offsetY)
        )
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
        let defaultOrigin = centeredOrigin(for: pillPanel.frame.size)
        let offsetX = pillPanel.frame.origin.x - defaultOrigin.x
        let offsetY = pillPanel.frame.origin.y - defaultOrigin.y
        defaults.set(offsetX, forKey: PreferenceKey.offsetX)
        defaults.set(offsetY, forKey: PreferenceKey.offsetY)
        dragStartOrigin = nil
    }
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state = HUDState.idle
    @Published private(set) var displayBars = Array(repeating: 0.0, count: 16)

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    private var targetBars = Array(repeating: 0.0, count: 16)
    private var smoothingTask: Task<Void, Never>?

    func apply(_ state: HUDState) {
        self.state = state
        targetBars = normalizedBars(from: state.waveformLevels)

        guard state.isVisible else {
            displayBars = Array(repeating: 0.0, count: 16)
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
