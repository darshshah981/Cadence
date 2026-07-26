import AppKit
import SwiftUI

@MainActor
final class ScribePanelViewModel: ObservableObject {
    @Published private(set) var state = ScribeSessionState.idle
    @Published private(set) var failureMessage: String?
    @Published private(set) var literalTranscript: String?
    @Published private(set) var providerStatus = "Private preview"
    @Published private(set) var environmentCue: String?
    @Published private(set) var targetDisplayName = "original app"
    @Published private(set) var exactLiteralSummary: String?
    @Published private(set) var canRetryGeneration = false
    @Published private(set) var fixtureIdentifier: String?
    @Published private(set) var closeRequestRevision = 0
    @Published private(set) var panelWidth = CadenceDesignMetrics.compactActionBreakpoint
    @Published private(set) var isDiscardAlertPresented = false

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onReRecord: (() -> Void)?
    var onUseLiteral: (() -> Void)?
    var onInsert: (() -> Void)?
    var onInsertUnpolished: (() -> Void)?
    var onCopyPolished: (() -> Void)?
    var onCopyUnpolished: (() -> Void)?
    var onClose: (() -> Void)?

    func requestCloseFromKeyboard() {
        closeRequestRevision &+= 1
    }

    func setPanelWidth(_ width: CGFloat) {
        panelWidth = width
    }

    func setDiscardAlertPresented(_ isPresented: Bool) {
        isDiscardAlertPresented = isPresented
    }

    func apply(
        state: ScribeSessionState,
        failureMessage: String?,
        literalTranscript: String?,
        environmentCue: String?,
        targetDisplayName: String? = nil,
        exactLiterals: [ScribeExactLiteral],
        canRetryGeneration: Bool,
        fixtureIdentifier: String? = nil
    ) {
        self.state = state
        self.failureMessage = failureMessage
        self.literalTranscript = literalTranscript
        self.environmentCue = environmentCue
        let normalizedTarget = targetDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedTarget, !normalizedTarget.isEmpty {
            self.targetDisplayName = normalizedTarget
        } else {
            self.targetDisplayName = "original app"
        }
        self.exactLiteralSummary = exactLiterals.isEmpty
            ? nil
            : "Exact literals: " + exactLiterals.map { "`\($0.value)`" }.joined(separator: ", ")
        self.canRetryGeneration = canRetryGeneration
        self.fixtureIdentifier = fixtureIdentifier
    }
}

struct ScribePanelView: View {
    @ObservedObject var model: ScribePanelViewModel
    @Environment(\.cadenceAccessibility) private var accessibility
    @State private var showsDiscardConfirmation = false

    var body: some View {
        #if DEBUG
        if ScribeLaunchFixtures.current == .controlSemantics {
            CadenceActionControlFixtureView()
        } else {
            panelBody
        }
        #else
        panelBody
        #endif
    }

    private var panelBody: some View {
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.fixtureIdentifier ?? "scribe-panel")
        .cadenceAccessibilityPreferences()
        .onChange(of: model.closeRequestRevision) { _, _ in requestClose() }
        .onChange(of: showsDiscardConfirmation) { _, isPresented in
            model.setDiscardAlertPresented(isPresented)
        }
        .alert("Discard this draft?", isPresented: $showsDiscardConfirmation) {
            Button("Discard draft", role: .destructive) {
                model.onCancel?()
            }
            Button("Keep draft", role: .cancel) {}
        } message: {
            Text("The draft is still selectable and can be copied or inserted.")
        }
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
            CadenceActionButton(title: "Close", role: .icon, accessibilityIdentifier: "scribe-close") {
                requestClose()
            }
            .accessibilityLabel("Cancel Scribe")
            .accessibilityHint(closeAccessibilityHint)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            directDictationStatus
        case .listening:
            listening
        case .transcribing:
            cancellableStatus(
                icon: "waveform",
                title: "Transcribing request…",
                detail: "Your speech stays on this Mac."
            )
        case .generating:
            cancellableStatus(
                icon: CadenceIconography.scribe,
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

    private var directDictationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preparing dictation…")
                .font(.title3.weight(.semibold))
                .foregroundStyle(FlowTheme.textPrimary)
            Text("Cadence will transcribe your dictation, then send only the processed dictation and writing behavior to your configured provider for review.")
                .font(.body)
                .foregroundStyle(FlowTheme.textSecondary)
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusView(
                icon: "waveform.circle.fill",
                title: "Listening…",
                detail: "No app text is being read."
            )
            actionGroup
        }
    }

    private func review(_ result: ScribeResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failureMessage = model.failureMessage {
                statusView(
                    icon: "exclamationmark.triangle",
                    title: "Latest polish attempt failed",
                    detail: failureMessage
                )
                .accessibilityIdentifier("scribe-polish-retry-failure")
            }
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
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scribe-exact-literal-summary")
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

            actionGroup
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

            actionGroup
        }
    }

    private var failureView: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusView(
                icon: "exclamationmark.triangle",
                title: "Scribe needs attention",
                detail: model.failureMessage ?? "Scribe could not finish this request."
            )
            actionGroup
        }
    }

    private var successView: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusView(
                icon: "checkmark.circle.fill",
                title: "Inserted into \(model.targetDisplayName)",
                detail: "The Scribe draft was inserted successfully."
            )
            actionGroup
        }
    }

    private func statusView(icon: String, title: String, detail: String) -> some View {
        CadenceStatusRow(symbol: icon, title: title, detail: detail)
    }

    private func cancellableStatus(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CadenceLoadingRow(
                title: title,
                detail: detail,
                accessibilityIdentifier: "scribe-loading-status"
            )
            actionGroup
        }
    }

    private var showsEnvironmentCue: Bool {
        ScribeActionPolicy.showsEnvironmentCue(model.state)
    }

    private var actionGroup: some View {
        let actions = ScribeActionPolicy.actions(
            for: model.state,
            hasLiteralTranscript: model.literalTranscript?.isEmpty == false,
            canRetryGeneration: model.canRetryGeneration,
            targetDisplayName: model.targetDisplayName
        )
        let usesVerticalLayout = model.panelWidth < CadenceDesignMetrics.compactActionBreakpoint
            || actions.count > 4
        return CadenceActionGroup(
            actions: actions,
            layoutWidth: model.panelWidth,
            perform: perform
        )
        // A review can expose seven recovery actions. Keep that ordered
        // control group operable in the compact panel even when surrounding
        // explanatory text honors a larger accessibility category.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scribe-action-group")
        .accessibilityValue(
            usesVerticalLayout
                ? "Vertical"
                : "Horizontal"
        )
    }

    private func perform(_ route: ScribeActionRoute) {
        switch route {
        case .cancel: requestClose()
        case .stop: model.onStop?()
        case .retry: model.onRetry?()
        case .reRecord: model.onReRecord?()
        case .useLiteral: model.onUseLiteral?()
        case .insert: model.onInsert?()
        case .insertUnpolished: model.onInsertUnpolished?()
        case .copyPolished: model.onCopyPolished?()
        case .copyUnpolished: model.onCopyUnpolished?()
        case .close: model.onClose?()
        }
    }

    private func requestClose() {
        if ScribeActionPolicy.requiresDiscardConfirmation(
            for: model.state,
            hasRecoverableContent: hasRecoverableContent
        ) {
            showsDiscardConfirmation = true
        } else {
            model.onCancel?()
        }
    }

    private var closeAccessibilityHint: String {
        ScribeActionPolicy.requiresDiscardConfirmation(
            for: model.state,
            hasRecoverableContent: hasRecoverableContent
        )
            ? "Ask before discarding this draft."
            : "Cancel this Scribe request and close the panel."
    }

    private var hasRecoverableContent: Bool {
        ScribeActionPolicy.hasRecoverableContent(
            in: model.state,
            literalTranscript: model.literalTranscript
        )
    }

}

@MainActor
private final class ScribeNonactivatingPanel: NSPanel {
    var onCancelKey: (() -> Void)?
    var shouldHandleCancelKey: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53 else {
            return super.performKeyEquivalent(with: event)
        }
        guard shouldHandleCancelKey?() != false else {
            return super.performKeyEquivalent(with: event)
        }
        onCancelKey?()
        return true
    }
}

@MainActor
final class ScribePanelWindowController {
    private enum Metrics {
        static let directReady = NSSize(width: 440, height: 170)
        static let status = NSSize(width: 400, height: 170)
        static let review = NSSize(width: 580, height: 580)
        static let bottomInset: CGFloat = 42
    }

    let viewModel = ScribePanelViewModel()
    private var panel: NSPanel?

    func update(
        state: ScribeSessionState,
        failureMessage: String?,
        literalTranscript: String?,
        environmentCue: String? = nil,
        targetDisplayName: String? = nil,
        exactLiterals: [ScribeExactLiteral] = [],
        canRetryGeneration: Bool = false
    ) {
        viewModel.apply(
            state: state,
            failureMessage: failureMessage,
            literalTranscript: literalTranscript,
            environmentCue: environmentCue,
            targetDisplayName: targetDisplayName,
            exactLiterals: exactLiterals,
            canRetryGeneration: canRetryGeneration
        )
        switch state {
        case .idle:
            show(size: Metrics.directReady)
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
        targetDisplayName: String? = nil,
        exactLiterals: [ScribeExactLiteral] = [],
        canRetryGeneration: Bool = false,
        fixtureIdentifier: String? = nil,
        width: CGFloat? = nil
    ) {
        viewModel.apply(
            state: state,
            failureMessage: failureMessage,
            literalTranscript: literalTranscript,
            environmentCue: environmentCue,
            targetDisplayName: targetDisplayName,
            exactLiterals: exactLiterals,
            canRetryGeneration: canRetryGeneration,
            fixtureIdentifier: fixtureIdentifier
        )
        if case .reviewing = state {
            viewModel.onInsert = { [weak self] in
                guard let self else { return }
                self.viewModel.apply(
                    state: .succeeded(requestID: UUID()),
                    failureMessage: nil,
                    literalTranscript: nil,
                    environmentCue: nil,
                    targetDisplayName: targetDisplayName,
                    exactLiterals: [],
                    canRetryGeneration: false,
                    fixtureIdentifier: "scribe-fixture-return-success"
                )
                self.show(size: NSSize(
                    width: width ?? Metrics.review.width,
                    height: Metrics.status.height
                ))
            }
        }
        let fixtureHeight: CGFloat
        if ScribeLaunchFixtures.usesLargeText {
            // Review now has seven actions. At accessibility text sizes they
            // form a single vertical hierarchy, so preserve enough height for
            // every route to be operable rather than merely present in AX.
            fixtureHeight = 700
        } else if (width ?? Metrics.review.width) < CadenceDesignMetrics.compactActionBreakpoint {
            fixtureHeight = 700
        } else {
            fixtureHeight = 680
        }
        show(size: NSSize(width: width ?? Metrics.review.width, height: fixtureHeight))
    }
    #endif

    private func show(size: NSSize) {
        viewModel.setPanelWidth(size.width)
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
        panel.onCancelKey = { [weak viewModel] in
            viewModel?.requestCloseFromKeyboard()
        }
        panel.shouldHandleCancelKey = { [weak viewModel] in
            #if DEBUG
            if ScribeLaunchFixtures.current == .controlSemantics { return false }
            #endif
            return viewModel?.isDiscardAlertPresented != true
        }

        #if DEBUG
        let rootView = ScribePanelView(model: viewModel)
            .cadenceAccessibilityFixture(ScribeLaunchFixtures.accessibilityOverride)
            .environment(\.dynamicTypeSize, ScribeLaunchFixtures.usesLargeText ? .accessibility2 : .large)
            .cadenceAccessibilityPreferences()
        #else
        let rootView = ScribePanelView(model: viewModel)
            .cadenceAccessibilityPreferences()
        #endif
        let hostingView = NSHostingView(rootView: rootView)
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
