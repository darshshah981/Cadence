import AppKit
import SwiftUI

@MainActor
final class ScribePanelViewModel: ObservableObject {
    @Published private(set) var state = ScribeSessionState.choosingIntent
    @Published private(set) var failureMessage: String?
    @Published private(set) var literalTranscript: String?
    @Published private(set) var providerStatus = "Private preview"

    var onChooseIntent: ((ScribeIntent) -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onUseLiteral: (() -> Void)?
    var onInsert: (() -> Void)?
    var onCopy: (() -> Void)?

    func presentPicker(providerStatus: String) {
        self.providerStatus = providerStatus
        failureMessage = nil
        literalTranscript = nil
        state = .choosingIntent
    }

    func apply(
        state: ScribeSessionState,
        failureMessage: String?,
        literalTranscript: String?
    ) {
        self.state = state
        self.failureMessage = failureMessage
        self.literalTranscript = literalTranscript
    }
}

struct ScribePanelView: View {
    @ObservedObject var model: ScribePanelViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FlowTheme.elevated)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FlowTheme.borderStrong, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(reduceMotion ? nil : FlowMotion.quick, value: model.state)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Scribe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                Text(model.providerStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textTertiary)
            }
            Spacer()
            Button {
                model.onCancel?()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel Scribe")
            .accessibilityHint("Discard this Scribe request and close the panel.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .choosingIntent:
            intentPicker
        case let .listening(_, intent):
            listening(intent: intent)
        case .transcribing:
            statusView(icon: "waveform", title: "Transcribing request…", detail: "Your speech stays on this Mac.")
        case .generating:
            statusView(icon: "sparkles", title: "Drafting…", detail: "You can cancel generation at any time.")
        case let .reviewing(result):
            review(result)
        case .inserting:
            statusView(icon: "keyboard", title: "Inserting draft…", detail: "Cadence is writing into the original app.")
        case .succeeded:
            statusView(icon: "checkmark.circle.fill", title: "Draft inserted", detail: "Scribe finished without changing your meeting data.")
        case .cancelled:
            statusView(icon: "xmark.circle", title: "Scribe cancelled", detail: "No text was inserted.")
        case .failed:
            failureView
        }
    }

    private var intentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How should Scribe help?")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text("Selected text is read only after you choose Respond or Edit.")
                .font(.system(size: 12))
                .foregroundStyle(FlowTheme.textSecondary)

            ForEach(ScribeIntent.allCases) { intent in
                Button {
                    model.onChooseIntent?(intent)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: intentIcon(intent))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(intent.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Text(intent.shortDescription)
                                .font(.system(size: 11))
                                .foregroundStyle(FlowTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(10)
                }
                .buttonStyle(.plain)
                .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(intent.displayName)
                .accessibilityHint(intent.shortDescription)
            }
        }
    }

    private func listening(intent: ScribeIntent) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            statusView(
                icon: "waveform.circle.fill",
                title: "Listening for \(intent.displayName.lowercased())",
                detail: intent.requiresSelectedText ? "Using the selected text for this request." : "No app text is being read."
            )
            HStack {
                Button("Cancel request") { model.onCancel?() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Stop and draft") { model.onStop?() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private func review(_ result: ScribeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draft ready")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text("Review the result before it affects the original app.")
                .font(.system(size: 11))
                .foregroundStyle(FlowTheme.textSecondary)

            ScrollView {
                Text(result.text)
                    .font(.system(size: 13))
                    .foregroundStyle(FlowTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                Button("Discard draft", role: .destructive) { model.onCancel?() }
                    .buttonStyle(.bordered)
                Button("Try again") { model.onRetry?() }
                    .buttonStyle(.bordered)
                Button("Copy draft") { model.onCopy?() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Insert into original app") { model.onInsert?() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusView(
                icon: "exclamationmark.triangle",
                title: "Scribe needs attention",
                detail: model.failureMessage ?? "Scribe could not finish this request."
            )
            HStack(spacing: 8) {
                Button("Discard request", role: .destructive) { model.onCancel?() }
                    .buttonStyle(.bordered)
                if model.literalTranscript?.isEmpty == false {
                    Button("Use spoken words") { model.onUseLiteral?() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button("Try Scribe again") { model.onRetry?() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func statusView(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(FlowTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func intentIcon(_ intent: ScribeIntent) -> String {
        switch intent {
        case .compose: return "square.and.pencil"
        case .respond: return "arrowshape.turn.up.left"
        case .edit: return "text.cursor"
        }
    }
}

@MainActor
final class ScribePanelWindowController {
    private enum Metrics {
        static let picker = NSSize(width: 440, height: 330)
        static let status = NSSize(width: 400, height: 170)
        static let review = NSSize(width: 580, height: 390)
        static let bottomInset: CGFloat = 42
    }

    let viewModel = ScribePanelViewModel()
    private var panel: NSPanel?

    func presentIntentPicker(providerStatus: String) {
        viewModel.presentPicker(providerStatus: providerStatus)
        show(size: Metrics.picker)
    }

    func update(state: ScribeSessionState, failureMessage: String?, literalTranscript: String?) {
        viewModel.apply(state: state, failureMessage: failureMessage, literalTranscript: literalTranscript)
        switch state {
        case .idle:
            panel?.orderOut(nil)
        case .choosingIntent:
            show(size: Metrics.picker)
        case .reviewing:
            show(size: Metrics.review)
        default:
            show(size: Metrics.status)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func show(size: NSSize) {
        let panel = makePanelIfNeeded(size: size)
        panel.setContentSize(size)
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanelIfNeeded(size: NSSize) -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let hostingView = NSHostingView(rootView: ScribePanelView(model: viewModel))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hostingView
        if let contentView = panel.contentView {
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let frame = WindowPlacement.visibleFrame()
        let origin = NSPoint(
            x: min(max(frame.midX - panel.frame.width / 2, frame.minX), frame.maxX - panel.frame.width),
            y: min(max(frame.minY + Metrics.bottomInset, frame.minY), frame.maxY - panel.frame.height)
        )
        panel.setFrameOrigin(origin)
    }
}
