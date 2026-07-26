import AppKit
import OSLog
import SwiftUI

private let scribeNotchViewLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ScribeNotchView"
)

enum ScribeNotchMotion {
    static let surface = Animation.spring(
        response: 0.26,
        dampingFraction: 0.94,
        blendDuration: 0.04
    )
    static let content = Animation.easeOut(duration: 0.12)
    static let replacement = Animation.easeInOut(duration: 0.16)
    static let feedback = Animation.easeOut(duration: 0.14)
    static let insertEmphasis = Animation.timingCurve(
        0.23,
        1,
        0.32,
        1,
        duration: 0.24
    )
    static let sourceTypingMaximumDuration = 0.68
    static let resultTypingMaximumDuration = 0.78
    static let typingMinimumDuration = 0.16
    static let typingSecondsPerCharacter = 0.006
    static let maximumTypingUpdates = 40
    static let collapsedHardwareSize = NSSize(width: 154, height: 34)
    static let collapsedFloatingSize = NSSize(width: 112, height: 32)
    static let canvasSize = NSSize(
        width: ScribeNotchGeometry.surfaceSize.width
            + (ScribeNotchGeometry.hardwareAttachmentShoulderRadius * 2),
        height: ScribeNotchGeometry.surfaceSize.height + 44
    )

    static func typingDuration(
        characterCount: Int,
        maximumDuration: Double
    ) -> Double {
        min(
            maximumDuration,
            max(
                typingMinimumDuration,
                Double(characterCount) * typingSecondsPerCharacter
            )
        )
    }
}

@MainActor
final class ScribeNotchViewModel: ObservableObject {
    @Published private(set) var presentation = ScribeNotchPresentation(
        content: .hidden,
        pill: .hidden
    )
    @Published private(set) var surfaceSize = ScribeNotchMotion.collapsedHardwareSize
    @Published private(set) var contentOpacity = 0.0
    @Published private(set) var displayedSource = ""
    @Published private(set) var displayedResult = ""
    @Published private(set) var sourceOpacity = 1.0
    @Published private(set) var resultOpacity = 0.0
    @Published private(set) var actionsOpacity = 0.0
    @Published private(set) var statusText = "Transcribing"
    @Published private(set) var hasHardwareNotch = true
    @Published private(set) var topGap: CGFloat = 0
    @Published private(set) var feedbackMessage = ""
    @Published private(set) var feedbackOpacity = 0.0
    @Published private(set) var completedSourceTypeOn = false
    @Published private(set) var insertEmphasisRevision = 0

    var onInsert: (() -> Void)?
    var onCopy: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onRetry: (() -> Void)?
    var onConfigureProvider: (() -> Void)?
    var onReturnToTargetApp: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onReplacementCompleted: (() -> Void)?
    var onInteractionAvailabilityChanged: ((Bool) -> Void)?

    private var transitionTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var reducedMotion = false

    var isVisible: Bool {
        presentation.content != .hidden
    }

    var showsReviewActions: Bool {
        actionsOpacity > 0
    }

    var failureLiteralTranscript: String? {
        guard case let .failure(_, literalTranscript, _) = presentation.content else {
            return nil
        }
        return literalTranscript
    }

    var failureRecovery: ScribeNotchFailureRecovery {
        guard case let .failure(_, _, recovery) = presentation.content else {
            return .none
        }
        return recovery
    }

    func configureDisplay(hasHardwareNotch: Bool) {
        self.hasHardwareNotch = hasHardwareNotch
        topGap = hasHardwareNotch ? 0 : ScribeNotchGeometry.floatingTopGap
        if !isVisible {
            surfaceSize = collapsedSize
        }
    }

    func setReducedMotion(_ reducedMotion: Bool) {
        self.reducedMotion = reducedMotion
    }

    func apply(_ next: ScribeNotchPresentation) {
        guard next != presentation else { return }
        transitionTask?.cancel()
        transitionTask = nil
        if next.pill == .listening {
            feedbackTask?.cancel()
            feedbackTask = nil
            feedbackMessage = ""
            feedbackOpacity = 0
        }
        let wasVisible = isVisible
        presentation = next
        onInteractionAvailabilityChanged?(next.allowsReviewActions)

        guard next.content != .hidden else {
            dismissSurface()
            return
        }

        if !wasVisible {
            surfaceSize = collapsedSize
            contentOpacity = 0
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.surface) {
                surfaceSize = ScribeNotchGeometry.surfaceSize
            }
        }

        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !wasVisible, !self.reducedMotion {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            withAnimation(self.reducedMotion ? nil : ScribeNotchMotion.content) {
                self.contentOpacity = 1
            }
            await self.render(next.content)
        }
    }

    func resetImmediately() {
        transitionTask?.cancel()
        feedbackTask?.cancel()
        transitionTask = nil
        feedbackTask = nil
        presentation = ScribeNotchPresentation(content: .hidden, pill: .hidden)
        surfaceSize = collapsedSize
        contentOpacity = 0
        displayedSource = ""
        displayedResult = ""
        sourceOpacity = 1
        resultOpacity = 0
        actionsOpacity = 0
        feedbackMessage = ""
        feedbackOpacity = 0
        completedSourceTypeOn = false
        insertEmphasisRevision = 0
    }

    func showFeedback(_ message: String) {
        feedbackTask?.cancel()
        feedbackMessage = message
        withAnimation(reducedMotion ? nil : ScribeNotchMotion.feedback) {
            feedbackOpacity = 1
        }
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_100))
            guard let self, !Task.isCancelled else { return }
            withAnimation(self.reducedMotion ? nil : ScribeNotchMotion.feedback) {
                self.feedbackOpacity = 0
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.feedbackMessage = ""
        }
    }

    private var collapsedSize: NSSize {
        hasHardwareNotch
            ? ScribeNotchMotion.collapsedHardwareSize
            : ScribeNotchMotion.collapsedFloatingSize
    }

    private func dismissSurface() {
        withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
            contentOpacity = 0
            actionsOpacity = 0
            sourceOpacity = 0
            resultOpacity = 0
        }
        guard !reducedMotion else {
            surfaceSize = collapsedSize
            return
        }
        transitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(110))
            guard let self, !Task.isCancelled else { return }
            withAnimation(ScribeNotchMotion.surface) {
                self.surfaceSize = self.collapsedSize
            }
        }
    }

    private func render(_ content: ScribeNotchContent) async {
        switch content {
        case .hidden:
            return
        case .transcribing:
            statusText = "Transcribing"
            completedSourceTypeOn = false
            clearText()
        case let .typingTranscript(text, isSlow):
            statusText = isSlow ? "Still scribing" : "Scribing"
            completedSourceTypeOn = false
            actionsOpacity = 0
            resultOpacity = 0
            displayedResult = ""
            sourceOpacity = 1
            if displayedSource != text {
                await type(
                    text,
                    into: \.displayedSource,
                    maximumDuration: ScribeNotchMotion.sourceTypingMaximumDuration,
                    preservingExistingPrefix: true
                )
            }
        case let .replacing(source, result):
            statusText = "Scribing"
            displayedResult = ""
            sourceOpacity = 1
            resultOpacity = 0
            actionsOpacity = 0

            if reducedMotion {
                displayedSource = source
                completedSourceTypeOn = true
                displayedSource = ""
                sourceOpacity = 0
                displayedResult = result.text
                resultOpacity = 1
            } else {
                if displayedSource != source {
                    await type(
                        source,
                        into: \.displayedSource,
                        maximumDuration: ScribeNotchMotion.sourceTypingMaximumDuration,
                        preservingExistingPrefix: true
                    )
                    guard !Task.isCancelled else { return }
                }
                completedSourceTypeOn = true
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                withAnimation(ScribeNotchMotion.replacement) {
                    sourceOpacity = 0
                }
                try? await Task.sleep(for: .milliseconds(190))
                guard !Task.isCancelled else { return }
                displayedSource = ""
                resultOpacity = 1
                await type(
                    result.text,
                    into: \.displayedResult,
                    maximumDuration: ScribeNotchMotion.resultTypingMaximumDuration
                )
                guard !Task.isCancelled else { return }
            }

            statusText = "Scribed"
            insertEmphasisRevision += 1
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 1
            }
            onInteractionAvailabilityChanged?(true)
            onReplacementCompleted?()
        case let .ready(result):
            statusText = "Scribed"
            displayedSource = ""
            displayedResult = result.text
            sourceOpacity = 0
            resultOpacity = 1
            insertEmphasisRevision += 1
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 1
            }
            onInteractionAvailabilityChanged?(true)
            onReplacementCompleted?()
        case let .insertionRecovery(message, result):
            statusText = "Draft not inserted"
            displayedSource = ""
            displayedResult = "\(message)\n\n\(result.text)"
            sourceOpacity = 0
            resultOpacity = 1
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 1
            }
        case .inserting:
            statusText = "Inserting"
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 0
            }
        case let .failure(message, _, _):
            statusText = "Scribe needs attention"
            displayedSource = ""
            displayedResult = message
            sourceOpacity = 0
            resultOpacity = 1
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 1
            }
        }
    }

    private func clearText() {
        displayedSource = ""
        displayedResult = ""
        sourceOpacity = 1
        resultOpacity = 0
        actionsOpacity = 0
    }

    private func type(
        _ text: String,
        into keyPath: ReferenceWritableKeyPath<ScribeNotchViewModel, String>,
        maximumDuration: Double,
        preservingExistingPrefix: Bool = false
    ) async {
        let characters = Array(text)
        guard !characters.isEmpty else {
            self[keyPath: keyPath] = ""
            return
        }
        if reducedMotion {
            self[keyPath: keyPath] = text
            return
        }

        let existingCharacters = Array(self[keyPath: keyPath])
        let startingCount: Int
        if preservingExistingPrefix,
           existingCharacters.count <= characters.count,
           Array(characters.prefix(existingCharacters.count)) == existingCharacters {
            startingCount = existingCharacters.count
        } else {
            self[keyPath: keyPath] = ""
            startingCount = 0
        }
        guard startingCount < characters.count else {
            self[keyPath: keyPath] = text
            return
        }
        let totalDuration = ScribeNotchMotion.typingDuration(
            characterCount: characters.count,
            maximumDuration: maximumDuration
        )
        let remainingCount = characters.count - startingCount
        let remainingDuration = totalDuration
            * (Double(remainingCount) / Double(characters.count))
        let updateCount = min(
            remainingCount,
            ScribeNotchMotion.maximumTypingUpdates
        )
        let charactersPerUpdate = max(1, Int(ceil(Double(remainingCount) / Double(updateCount))))
        let nanoseconds = UInt64(
            remainingDuration / Double(max(1, Int(ceil(Double(remainingCount) / Double(charactersPerUpdate)))))
                * 1_000_000_000
        )

        var end = startingCount
        while end < characters.count {
            guard !Task.isCancelled else { return }
            end = min(characters.count, end + charactersPerUpdate)
            self[keyPath: keyPath] = String(characters.prefix(end))
            if end < characters.count {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }
}

struct ScribeNotchView: View {
    @ObservedObject var model: ScribeNotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if model.hasHardwareNotch {
                notchAttachmentShoulders
            }
            surface
                .frame(
                    width: ScribeNotchGeometry.surfaceSize.width,
                    height: ScribeNotchGeometry.surfaceSize.height
                )
                .scaleEffect(
                    x: model.surfaceSize.width / ScribeNotchGeometry.surfaceSize.width,
                    y: model.surfaceSize.height / ScribeNotchGeometry.surfaceSize.height,
                    anchor: .top
                )
            feedback
                .offset(y: model.surfaceSize.height + 7)
        }
        .frame(
            width: ScribeNotchMotion.canvasSize.width,
            height: ScribeNotchMotion.canvasSize.height,
            alignment: .top
        )
        .onAppear { model.setReducedMotion(reduceMotion) }
        .onChange(of: reduceMotion) { _, reduced in
            model.setReducedMotion(reduced)
        }
    }

    private var notchAttachmentShoulders: some View {
        HStack(spacing: 0) {
            ScribeNotchAttachmentShoulder(edge: .leading)
                .fill(Color(nsColor: NSColor(hex: ScribeNotchPalette.surfaceHex, alpha: 1)))
                .frame(
                    width: ScribeNotchGeometry.hardwareAttachmentShoulderRadius,
                    height: ScribeNotchGeometry.hardwareAttachmentShoulderRadius
                )
            Color.clear
                .frame(width: model.surfaceSize.width)
            ScribeNotchAttachmentShoulder(edge: .trailing)
                .fill(Color(nsColor: NSColor(hex: ScribeNotchPalette.surfaceHex, alpha: 1)))
                .frame(
                    width: ScribeNotchGeometry.hardwareAttachmentShoulderRadius,
                    height: ScribeNotchGeometry.hardwareAttachmentShoulderRadius
                )
        }
        .frame(
            width: model.surfaceSize.width
                + (ScribeNotchGeometry.hardwareAttachmentShoulderRadius * 2),
            alignment: .top
        )
        .opacity(model.contentOpacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var feedback: some View {
        if !model.feedbackMessage.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(FlowTheme.success)
                Text(model.feedbackMessage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: NSColor(hex: ScribeNotchPalette.surfaceHex, alpha: 1)))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    }
            }
            .opacity(model.feedbackOpacity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("scribe-notch-feedback")
        }
    }

    private var surface: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                if model.hasHardwareNotch {
                    Color.clear
                        .frame(height: ScribeNotchGeometry.hardwareNotchContentInset)
                        .accessibilityHidden(true)
                }
                if case .transcribing = model.presentation.content {
                    transcribingCanvas
                } else {
                    header
                    textViewport
                    actions
                }
            }
            .opacity(model.contentOpacity)
        }
        .clipShape(surfaceShape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scribe-notch-surface")
    }

    private var transcribingCanvas: some View {
        ZStack {
            Circle()
                .fill(FlowTheme.accent.opacity(0.08))
                .frame(width: 72, height: 72)
                .blur(radius: 18)
                .accessibilityHidden(true)

            ScribeTranscribingStatusView(fontSize: 12, spacing: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: 7) {
            phaseStatus
                .id(model.statusText)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .animation(
            reduceMotion ? nil : ScribeNotchMotion.content,
            value: model.statusText
        )
    }

    @ViewBuilder
    private var phaseStatus: some View {
        if model.statusText == "Transcribing" {
            ScribeTranscribingStatusView(fontSize: 10, spacing: 7)
        } else if model.statusText == "Scribing"
                    || model.statusText == "Still scribing" {
            ScribeScribingStatusView(isSlow: model.statusText == "Still scribing")
        } else {
            HStack(spacing: 7) {
                if model.statusText == "Scribed" {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlowTheme.textPrimary)
                } else if case .failure = model.presentation.content {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlowTheme.textSecondary)
                } else if case .insertionRecovery = model.presentation.content {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlowTheme.textSecondary)
                } else {
                    HUDSpinnerView()
                }
                Text(model.statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
            }
        }
    }

    private var textViewport: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                Text(model.displayedSource)
                    .foregroundStyle(FlowTheme.textSecondary)
                    .opacity(model.sourceOpacity)
                Text(model.displayedResult)
                    .foregroundStyle(FlowTheme.textPrimary)
                    .opacity(model.resultOpacity)
            }
            .font(.system(size: 12))
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentMargins(.horizontal, 13, for: .scrollContent)
        .contentMargins(.vertical, 8, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if case .failure = model.presentation.content {
                notchIconAction(
                    systemName: "xmark",
                    label: "Discard",
                    accessibilityIdentifier: "scribe-notch-discard"
                ) {
                    model.onDiscard?()
                }
                if model.failureLiteralTranscript != nil {
                    notchIconAction(
                        systemName: "doc.on.doc",
                        label: "Copy",
                        accessibilityIdentifier: "scribe-notch-copy-literal"
                    ) {
                        model.onCopy?()
                    }
                }
                Spacer(minLength: 0)
                switch model.failureRecovery {
                case .retryGeneration:
                    Button("Try again") {
                        model.onRetry?()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.accent)
                    .buttonStyle(.plain)
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .help("Try Scribe again")
                    .accessibilityIdentifier("scribe-notch-retry")
                case .setUpProvider:
                    recoveryButton(
                        "Set up provider",
                        help: "Set up an AI provider for Scribe",
                        accessibilityIdentifier: "scribe-notch-setup-provider"
                    ) {
                        model.onConfigureProvider?()
                    }
                case .reviewProvider:
                    recoveryButton(
                        "Review provider",
                        help: "Review the saved AI provider",
                        accessibilityIdentifier: "scribe-notch-review-provider"
                    ) {
                        model.onConfigureProvider?()
                    }
                case .returnToTargetApp:
                    recoveryButton(
                        "Return to app",
                        help: "Return to the most recent app and place the cursor",
                        accessibilityIdentifier: "scribe-notch-return-to-app"
                    ) {
                        model.onReturnToTargetApp?()
                    }
                case .openPermissions:
                    recoveryButton(
                        "Open permissions",
                        help: "Open Cadence permission setup",
                        accessibilityIdentifier: "scribe-notch-open-permissions"
                    ) {
                        model.onOpenPermissions?()
                    }
                case .none:
                    EmptyView()
                }
            } else {
                notchIconAction(
                    systemName: "xmark",
                    label: "Discard",
                    accessibilityIdentifier: "scribe-notch-discard"
                ) {
                    model.onDiscard?()
                }
                notchIconAction(
                    systemName: "doc.on.doc",
                    label: "Copy",
                    accessibilityIdentifier: "scribe-notch-copy"
                ) {
                    model.onCopy?()
                }
                Spacer(minLength: 0)
                ScribeInsertActionButton(
                    emphasisRevision: model.insertEmphasisRevision
                ) {
                    model.onInsert?()
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 43)
        .opacity(model.actionsOpacity)
        .allowsHitTesting(model.showsReviewActions)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private func recoveryButton(
        _ title: String,
        help: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FlowTheme.accent)
            .buttonStyle(.plain)
            .frame(height: 28)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .help(help)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func notchIconAction(
        systemName: String,
        label: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FlowTheme.textSecondary)
                .frame(width: 27, height: 27)
                .background {
                    Circle()
                        .fill(Color.white.opacity(0.035))
                        .overlay {
                            Circle()
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.75)
                        }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var background: some View {
        Color(nsColor: NSColor(hex: ScribeNotchPalette.surfaceHex, alpha: 1))
    }

    private var surfaceShape: UnevenRoundedRectangle {
        let topRadius: CGFloat = model.hasHardwareNotch
            ? 0
            : ScribeNotchGeometry.surfaceBottomCornerRadius
        return UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(
                topLeading: topRadius,
                bottomLeading: ScribeNotchGeometry.surfaceBottomCornerRadius,
                bottomTrailing: ScribeNotchGeometry.surfaceBottomCornerRadius,
                topTrailing: topRadius
            ),
            style: .continuous
        )
    }
}

private struct ScribeInsertActionButton: View {
    let emphasisRevision: Int
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sparkleProgress: CGFloat = -0.2
    @State private var sparkleOpacity = 0.0
    @State private var isHighlighted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("Insert")
                Image(systemName: "return")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FlowTheme.accent)
            .frame(height: 28)
            .padding(.horizontal, 9)
            .background {
                Capsule(style: .continuous)
                    .fill(FlowTheme.accent.opacity(isHighlighted ? 0.11 : 0))
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(
                                FlowTheme.accent.opacity(isHighlighted ? 0.34 : 0),
                                lineWidth: 0.75
                            )
                    }
            }
            .overlay {
                GeometryReader { proxy in
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(color: FlowTheme.accent.opacity(0.9), radius: 3)
                        .opacity(sparkleOpacity)
                        .offset(
                            x: (proxy.size.width + 16) * sparkleProgress - 8,
                            y: 9
                        )
                }
                .allowsHitTesting(false)
            }
            .clipShape(Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Insert into the original app (Return)")
        .accessibilityLabel("Insert")
        .accessibilityHint("Press Return to insert into the original app")
        .accessibilityIdentifier("scribe-notch-insert")
        .task(id: emphasisRevision) {
            guard emphasisRevision > 0 else {
                sparkleProgress = -0.2
                sparkleOpacity = 0
                isHighlighted = false
                return
            }
            sparkleProgress = -0.2
            sparkleOpacity = reduceMotion ? 0 : 1
            isHighlighted = true
            guard !reduceMotion else { return }
            await Task.yield()
            withAnimation(ScribeNotchMotion.insertEmphasis) {
                sparkleProgress = 1.2
            }
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            sparkleOpacity = 0
        }
    }
}

private struct ScribeScribingStatusView: View {
    let isSlow: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.2) / 1.2
            let pulse = reduceMotion
                ? 1.0
                : 0.96 + (0.06 * ((sin(phase * .pi * 2) + 1) / 2))

            HStack(spacing: 7) {
                Image(systemName: CadenceIconography.scribe)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.45, green: 0.68, blue: 1),
                                Color(red: 0.76, green: 0.48, blue: 1),
                                Color(red: 1, green: 0.48, blue: 0.72)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .scaleEffect(pulse)
                    .shadow(
                        color: Color(red: 0.68, green: 0.5, blue: 1).opacity(0.24),
                        radius: 4
                    )

                Text(isSlow ? "Still scribing" : "Scribing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSlow ? "Still scribing" : "Scribing")
    }
}

private struct ScribeNotchAttachmentShoulder: Shape {
    enum Edge {
        case leading
        case trailing
    }

    let edge: Edge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .leading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.minY),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
            path.closeSubpath()
        case .trailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
            path.closeSubpath()
        }
        return path
    }
}
