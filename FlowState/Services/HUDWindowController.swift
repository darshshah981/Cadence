import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDWindowController {
    private static let compactPillSize = NSSize(width: 108, height: 34)
    private static let controlsPillSize = NSSize(width: 164, height: 34)
    private static let subtitleSize = NSSize(width: 520, height: 72)
    private static let bottomInset: CGFloat = 20
    private static let subtitleGap: CGFloat = 12

    private var pillPanel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var pillHostingView: NSHostingView<HUDView>?
    private var subtitleHostingView: NSHostingView<HUDSubtitleView>?
    private let viewModel = HUDViewModel()
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    init() {
        viewModel.onStop = { [weak self] in self?.onStop?() }
        viewModel.onCancel = { [weak self] in self?.onCancel?() }
    }

    func update(with state: HUDState) {
        if !state.isVisible {
            viewModel.apply(state)
            pillPanel?.orderOut(nil)
            subtitlePanel?.orderOut(nil)
            return
        }

        viewModel.apply(state)
        let pillPanel = makePillPanelIfNeeded()
        pillPanel.setContentSize(state.showsControls ? Self.controlsPillSize : Self.compactPillSize)
        pillPanel.ignoresMouseEvents = !state.showsControls

        if pillHostingView == nil {
            let hostingView = NSHostingView(rootView: HUDView(model: viewModel))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            pillPanel.contentView = hostingView
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: pillPanel.contentView!.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: pillPanel.contentView!.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: pillPanel.contentView!.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: pillPanel.contentView!.bottomAnchor)
            ])
            self.pillHostingView = hostingView
        }

        position(pillPanel: pillPanel)
        pillPanel.orderFrontRegardless()

        if state.showsSubtitle, !state.subtitle.isEmpty {
            let subtitlePanel = makeSubtitlePanelIfNeeded()
            if subtitleHostingView == nil {
                let hostingView = NSHostingView(rootView: HUDSubtitleView(model: viewModel))
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                subtitlePanel.contentView = hostingView
                NSLayoutConstraint.activate([
                    hostingView.leadingAnchor.constraint(equalTo: subtitlePanel.contentView!.leadingAnchor),
                    hostingView.trailingAnchor.constraint(equalTo: subtitlePanel.contentView!.trailingAnchor),
                    hostingView.topAnchor.constraint(equalTo: subtitlePanel.contentView!.topAnchor),
                    hostingView.bottomAnchor.constraint(equalTo: subtitlePanel.contentView!.bottomAnchor)
                ])
                self.subtitleHostingView = hostingView
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

        let panel = makePanel(size: Self.compactPillSize)
        self.pillPanel = panel
        return panel
    }

    private func makeSubtitlePanelIfNeeded() -> NSPanel {
        if let subtitlePanel {
            return subtitlePanel
        }

        let panel = makePanel(size: Self.subtitleSize)
        self.subtitlePanel = panel
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
        panel.ignoresMouseEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        return panel
    }

    private func position(pillPanel: NSPanel) {
        let frame = targetScreenFrame()
        let pillSize = pillPanel.frame.size
        let origin = NSPoint(
            x: frame.midX - pillSize.width / 2,
            y: frame.minY + Self.bottomInset
        )
        pillPanel.setFrameOrigin(origin)
    }

    private func position(subtitlePanel: NSPanel, relativeTo pillPanel: NSPanel) {
        let origin = NSPoint(
            x: pillPanel.frame.midX - Self.subtitleSize.width / 2,
            y: pillPanel.frame.maxY + Self.subtitleGap
        )
        subtitlePanel.setFrameOrigin(origin)
    }

    private func targetScreenFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        return (screen ?? NSScreen.main)?.visibleFrame ?? .zero
    }
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published private(set) var state = HUDState.idle
    @Published private(set) var displayLevel = 0.0
    @Published private(set) var wavePhase = 0.0

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?

    private var targetLevel = 0.0
    private var smoothingTask: Task<Void, Never>?

    func apply(_ state: HUDState) {
        self.state = state
        targetLevel = state.level

        if !state.isVisible {
            displayLevel = 0
            smoothingTask?.cancel()
            smoothingTask = nil
            return
        }

        guard smoothingTask == nil else { return }

        smoothingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let delta = targetLevel - displayLevel
                if abs(delta) < 0.003 {
                    displayLevel = targetLevel
                    break
                }

                // Fast attack with a slower decay keeps the meter lively without flicker.
                let factor = delta > 0 ? 0.38 : 0.18
                displayLevel = min(1, max(0, displayLevel + delta * factor))
                wavePhase += 0.36 + displayLevel * 0.18
                try? await Task.sleep(for: .milliseconds(16))
            }

            smoothingTask = nil
        }
    }
}

struct HUDSubtitleView: View {
    @ObservedObject var model: HUDViewModel

    var body: some View {
        Text(model.state.subtitle)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(width: 520, height: 72)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.52))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
    }
}
