import AppKit
import SwiftUI

enum ScribePanelLaunchSequence {
    static func launch(
        prepareTarget: () throws -> Void,
        presentPicker: (ScribeIntent) -> Void
    ) rethrows {
        try prepareTarget()
        presentPicker(.compose)
    }
}

@MainActor
final class ScribePanelViewModel: ObservableObject {
    @Published private(set) var state = ScribeSessionState.choosingIntent
    @Published private(set) var failureMessage: String?
    @Published private(set) var literalTranscript: String?
    @Published private(set) var providerStatus = "Private preview"
    @Published private(set) var requestedIntentFocus: ScribeIntent?
    @Published private(set) var environmentCue: String?
    @Published private(set) var exactLiteralSummary: String?
    @Published private(set) var selectedTextDisclosure = "Selected text is used only after you choose Respond or Edit."
    @Published private(set) var canRetryGeneration = false

    var onChooseIntent: ((ScribeIntent) -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onUseLiteral: (() -> Void)?
    var onInsert: (() -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    func presentPicker(
        providerStatus: String,
        selectedTextDisclosure: String = "Selected text is used only after you choose Respond or Edit.",
        initialFocus: ScribeIntent
    ) {
        self.providerStatus = providerStatus
        self.selectedTextDisclosure = selectedTextDisclosure
        requestedIntentFocus = initialFocus
        failureMessage = nil
        literalTranscript = nil
        environmentCue = nil
        exactLiteralSummary = nil
        canRetryGeneration = false
        state = .choosingIntent
    }

    func apply(
        state: ScribeSessionState,
        failureMessage: String?,
        literalTranscript: String?,
        environmentCue: String?,
        exactLiterals: [ScribeExactLiteral],
        canRetryGeneration: Bool
    ) {
        self.state = state
        self.failureMessage = failureMessage
        self.literalTranscript = literalTranscript
        self.environmentCue = environmentCue
        self.exactLiteralSummary = exactLiterals.isEmpty
            ? nil
            : "Exact literals: " + exactLiterals.map { "`\($0.value)`" }.joined(separator: ", ")
        self.canRetryGeneration = canRetryGeneration
    }
}

struct ScribePanelView: View {
    @ObservedObject var model: ScribePanelViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedIntent: ScribeIntent?

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
        .onAppear { focusFirstIntentIfNeeded() }
        .onChange(of: model.state) { _, _ in focusFirstIntentIfNeeded() }
        .onChange(of: model.requestedIntentFocus) { _, intent in focusedIntent = intent }
        .onExitCommand { model.onCancel?() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Scribe")
                    .font(.headline)
                    .foregroundStyle(FlowTheme.textPrimary)
                Text(model.providerStatus)
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textTertiary)
                if showsEnvironmentCue, let environmentCue = model.environmentCue {
                    Text(environmentCue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FlowTheme.textSecondary)
                        .accessibilityLabel("Writing environment")
                        .accessibilityValue(environmentCue)
                        .accessibilityIdentifier("scribe-environment-cue")
                }
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
            cancellableStatus(
                icon: "waveform",
                title: "Transcribing request…",
                detail: "Your speech stays on this Mac."
            )
        case .generating:
            cancellableStatus(
                icon: "sparkles",
                title: "Drafting…",
                detail: "You can cancel generation at any time."
            )
        case .generatingSlow:
            cancellableStatus(
                icon: "clock.arrow.circlepath",
                title: "Still drafting…",
                detail: "The provider is taking longer than usual. You can keep waiting or cancel safely."
            )
        case let .reviewing(result):
            review(result)
        case let .insertionRecovery(result):
            insertionRecovery(result)
        case .inserting:
            statusView(icon: "keyboard", title: "Inserting draft…", detail: "Cadence is writing into the original app.")
        case .succeeded:
            successView
        case .cancelled:
            statusView(icon: "xmark.circle", title: "Scribe cancelled", detail: "No text was inserted.")
        case .failed:
            failureView
        }
    }

    private var intentPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How should Scribe help?")
                .font(.title3.weight(.semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text(model.selectedTextDisclosure)
                .font(.body)
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
                                .font(.headline)
                            Text(intent.shortDescription)
                                .font(.caption)
                                .foregroundStyle(FlowTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(10)
                }
                .buttonStyle(.plain)
                .focused($focusedIntent, equals: intent)
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
                CadenceActionButton(title: "Cancel request", role: .destructive) { model.onCancel?() }
                Spacer()
                CadenceActionButton(title: "Stop and draft", role: .primary, isDefault: true) {
                    model.onStop?()
                }
            }
        }
    }

    private func review(_ result: ScribeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Draft ready")
                .font(.headline)
                .foregroundStyle(FlowTheme.textPrimary)
            Text("Review the result before it affects the original app.")
                .font(.caption)
                .foregroundStyle(FlowTheme.textSecondary)
            if let exactLiteralSummary = model.exactLiteralSummary {
                Text(exactLiteralSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .accessibilityLabel(exactLiteralSummary)
            }

            ScrollView {
                Text(result.text)
                    .font(.body)
                    .foregroundStyle(FlowTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                CadenceActionButton(title: "Discard draft", role: .destructive) { model.onCancel?() }
                CadenceActionButton(title: "Draft again", role: .secondary) { model.onRetry?() }
                CadenceActionButton(title: "Copy draft", role: .quiet) { model.onCopy?() }
                Spacer()
                CadenceActionButton(
                    title: "Insert into original app",
                    role: .primary,
                    isDefault: true
                ) { model.onInsert?() }
            }
        }
    }

    private func insertionRecovery(_ result: ScribeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            statusView(
                icon: "arrow.uturn.backward.circle",
                title: "Draft not inserted",
                detail: model.failureMessage ?? "Return to the original app and insertion point. Your draft is still here."
            )
            .accessibilityIdentifier("scribe-insertion-recovery-status")
            ScrollView {
                Text(result.text)
                    .font(.body)
                    .foregroundStyle(FlowTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: 100, maxHeight: 200)
            .background(FlowTheme.subtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                CadenceActionButton(title: "Discard draft", role: .destructive) { model.onCancel?() }
                CadenceActionButton(title: "Copy draft", role: .quiet) { model.onCopy?() }
                Spacer()
                CadenceActionButton(title: "Return and insert", role: .primary, isDefault: true) {
                    model.onInsert?()
                }
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
                CadenceActionButton(title: "Discard request", role: .destructive) { model.onCancel?() }
                if model.literalTranscript?.isEmpty == false {
                    CadenceActionButton(title: "Use spoken words", role: .quiet) { model.onUseLiteral?() }
                }
                Spacer()
                CadenceActionButton(
                    title: model.canRetryGeneration ? "Try Scribe again" : "Record request again",
                    role: .primary,
                    isDefault: true
                ) { model.onRetry?() }
            }
        }
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusView(
                icon: "checkmark.circle.fill",
                title: "Draft sent",
                detail: "Cadence updated the pinned text field atomically. Copy the draft here if the app did not display it."
            )
            HStack {
                Spacer()
                CadenceActionButton(title: "Done", role: .primary, isDefault: true) {
                    model.onClose?()
                }
            }
        }
    }

    private func statusView(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(FlowTheme.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(FlowTheme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(FlowTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func cancellableStatus(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            statusView(icon: icon, title: title, detail: detail)
            HStack {
                Spacer()
                CadenceActionButton(title: "Cancel request", role: .quiet) { model.onCancel?() }
            }
        }
    }

    private func intentIcon(_ intent: ScribeIntent) -> String {
        switch intent {
        case .compose: return "square.and.pencil"
        case .respond: return "arrowshape.turn.up.left"
        case .edit: return "text.cursor"
        }
    }

    private var showsEnvironmentCue: Bool {
        if case .reviewing = model.state { return true }
        return false
    }

    private func focusFirstIntentIfNeeded() {
        if model.state == .choosingIntent || model.state == .idle {
            focusedIntent = model.requestedIntentFocus ?? .compose
        }
    }
}

private final class ScribeNonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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

    func presentIntentPicker(
        providerStatus: String,
        selectedTextDisclosure: String,
        initialFocus: ScribeIntent = .compose
    ) {
        viewModel.presentPicker(
            providerStatus: providerStatus,
            selectedTextDisclosure: selectedTextDisclosure,
            initialFocus: initialFocus
        )
        show(size: Metrics.picker)
    }

    func update(
        state: ScribeSessionState,
        failureMessage: String?,
        literalTranscript: String?,
        environmentCue: String? = nil,
        exactLiterals: [ScribeExactLiteral] = [],
        canRetryGeneration: Bool = false
    ) {
        viewModel.apply(
            state: state,
            failureMessage: failureMessage,
            literalTranscript: literalTranscript,
            environmentCue: environmentCue,
            exactLiterals: exactLiterals,
            canRetryGeneration: canRetryGeneration
        )
        switch state {
        case .idle:
            panel?.orderOut(nil)
        case .choosingIntent:
            show(size: Metrics.picker)
        case .reviewing, .insertionRecovery:
            show(size: Metrics.review)
        default:
            show(size: Metrics.status)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    #if DEBUG
    func presentFixture(
        state: ScribeSessionState,
        failureMessage: String? = nil,
        literalTranscript: String? = nil,
        environmentCue: String? = nil,
        exactLiterals: [ScribeExactLiteral] = [],
        canRetryGeneration: Bool = false,
        width: CGFloat? = nil
    ) {
        viewModel.apply(
            state: state,
            failureMessage: failureMessage,
            literalTranscript: literalTranscript,
            environmentCue: environmentCue,
            exactLiterals: exactLiterals,
            canRetryGeneration: canRetryGeneration
        )
        show(size: NSSize(
            width: width ?? Metrics.review.width,
            height: Metrics.review.height
        ))
    }
    #endif

    private func show(size: NSSize) {
        let panel = makePanelIfNeeded(size: size)
        panel.setContentSize(size)
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func makePanelIfNeeded(size: NSSize) -> NSPanel {
        if let panel { return panel }
        let panel = ScribeNonactivatingPanel(
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
