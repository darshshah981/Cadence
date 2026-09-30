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
    @Published private(set) var canRefineReviewedDraft = false
    @Published private(set) var canUndoRefinement = false
    @Published private(set) var refinementUnavailableReason: String?
    @Published private(set) var isRefining = false
    @Published private(set) var reviewNotice: String?
    @Published private(set) var lastRefinementInstruction: String?
    @Published private(set) var selectedTextContextStatus: String?
    @Published private(set) var sessionMemoryContextStatus: String?
    @Published private(set) var sessionFactsReviewSource: ScribeSessionFactsReviewSource?
    @Published private(set) var selectedTextReviewSource: ScribeSelectedTextReviewSource?
    @Published private(set) var insertionOutcomeUncertain = false
    @Published private(set) var canUseScreenContext = false
    @Published private(set) var screenDraftPhase: ComposeScreenDraftReviewPhase = .idle
    @Published private(set) var isInspectingSource = false
    @Published private(set) var isInspectingFacts = false
    var isInspectingContext: Bool {
        isInspectingSource || isInspectingFacts || screenDraftPhase != .idle
    }
    var permitsReviewedInsertion: Bool {
        !insertionOutcomeUncertain
            && selectedTextReviewSource?.isExcluded != true
            && selectedTextReviewSource?.isUnchanged != true
            && !isInspectingContext
    }

    func updateInsertionOutcomeUncertain(_ value: Bool) {
        insertionOutcomeUncertain = value
    }

    var onInsert: (() -> Void)?
    var onBeginScreenDraft: (() -> Void)?
    var onApproveScreenReading: (() -> Void)?
    var onApproveScreenProviderUse: (() -> Void)?
    var onCopyScreenDraft: (() -> Void)?
    var onCancelScreenDraft: (() -> Void)?
    var onExcludeSelectedTextSource: ((UUID) -> Void)?
    var onInspectSelectedTextSource: ((UUID) -> Bool)?
    var onRecordWithoutSelectedSource: ((UUID) -> Void)?
    var onRefreshSelectedTextSource: ((UUID) -> Void)?
    var onRegenerateWithoutSessionFacts: ((UUID) -> Void)?
    var onRegenerateWithoutSessionFact: ((UUID, UUID) -> Void)?
    var onSavePersistentMemory: ((UUID) -> Void)?
    var onConfirmPersistentMemoryForget: ((UUID) -> Void)?
    var onCopy: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onRetry: (() -> Void)?
    var onRefine: (() -> Void)?
    var onUndoRefinement: (() -> Void)?
    var onCancelRefinement: (() -> Void)?
    var onConfigureProvider: (() -> Void)?
    var onReturnToTargetApp: (() -> Void)?
    var onOpenPermissions: (() -> Void)?
    var onReplacementCompleted: (() -> Void)?
    var onInteractionAvailabilityChanged: ((Bool) -> Void)?

    private var transitionTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var reducedMotion = false
    private var completedResult: ScribeResult?

    var isVisible: Bool {
        presentation.content != .hidden
    }

    var showsReviewActions: Bool {
        presentation.allowsReviewActions && !isRefining
    }

    var allowsInteraction: Bool {
        showsReviewActions || (isRefining && isVisible)
    }

    var showsRefinementActions: Bool {
        switch presentation.content {
        case .replacing, .ready, .insertionRecovery: return true
        default: return false
        }
    }

    private var readyStatusText: String {
        if selectedTextReviewSource?.isUnchanged == true { return "No changes made" }
        return reviewNotice == nil ? "Composed" : "Draft kept"
    }

    var refinementHelp: String {
        refinementUnavailableReason ?? "Say how to change this draft. Your current draft stays available."
    }

    func updateSelectedTextContextStatus(_ status: String?) {
        selectedTextContextStatus = status
    }

    func updateScreenDraftAvailability(_ available: Bool) {
        canUseScreenContext = available
    }

    func updateScreenDraftPhase(_ next: ComposeScreenDraftReviewPhase) {
        guard screenDraftPhase != next else { return }
        screenDraftPhase = next
        onInteractionAvailabilityChanged?(allowsInteraction)
    }

    func updateSessionMemoryContextStatus(_ status: String?) {
        sessionMemoryContextStatus = status
    }

    func updateSessionFactsReviewSource(_ source: ScribeSessionFactsReviewSource?) {
        guard sessionFactsReviewSource != source else { return }
        if sessionFactsReviewSource?.id != source?.id { isInspectingFacts = false }
        sessionFactsReviewSource = source
        onInteractionAvailabilityChanged?(allowsInteraction)
    }

    func setInspectingFacts(_ isPresented: Bool, sourceID: UUID? = nil) {
        if let sourceID, sessionFactsReviewSource?.id != sourceID { return }
        let value = isPresented && sessionFactsReviewSource != nil
        guard value != isInspectingFacts else { return }
        isInspectingFacts = value
        onInteractionAvailabilityChanged?(allowsInteraction)
    }

    func updateSelectedTextReviewSource(_ source: ScribeSelectedTextReviewSource?) {
        guard selectedTextReviewSource != source else { return }
        if selectedTextReviewSource?.id != source?.id { isInspectingSource = false }
        selectedTextReviewSource = source
        onInteractionAvailabilityChanged?(allowsInteraction)
    }

    func setInspectingSource(_ isPresented: Bool, sourceID: UUID? = nil) {
        if let sourceID, selectedTextReviewSource?.id != sourceID { return }
        let value = isPresented && selectedTextReviewSource != nil
        guard value != isInspectingSource else { return }
        isInspectingSource = value
        onInteractionAvailabilityChanged?(allowsInteraction)
    }

    func updateRefinement(
        canRefineReviewedDraft: Bool,
        canUndoRefinement: Bool,
        unavailableReason: String?,
        isRefining: Bool,
        reviewNotice: String? = nil,
        lastInstruction: String? = nil
    ) {
        self.canRefineReviewedDraft = canRefineReviewedDraft
        self.canUndoRefinement = canUndoRefinement
        self.refinementUnavailableReason = unavailableReason
        self.isRefining = isRefining
        self.reviewNotice = reviewNotice
        self.lastRefinementInstruction = lastInstruction
        if isRefining, showsRefinementActions {
            statusText = "Preparing refinement"
        } else if !isRefining {
            switch presentation.content {
            case .replacing, .ready:
                statusText = readyStatusText
            default:
                break
            }
        }
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
        guard self.reducedMotion != reducedMotion else { return }
        self.reducedMotion = reducedMotion
        guard reducedMotion else { return }

        // Accessibility can change while source text is typing or the surface
        // is collapsing. Stop that cosmetic work and settle the current state.
        transitionTask?.cancel()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            surfaceSize = isVisible ? ScribeNotchGeometry.surfaceSize : collapsedSize
            contentOpacity = isVisible ? 1 : 0
        }
        transitionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.render(self.presentation.content)
        }
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

        guard next.content != .hidden else {
            completedResult = nil
            onInteractionAvailabilityChanged?(false)
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

        // Result readiness is synchronous. Expansion can animate independently,
        // but neither source typing nor a fade owns text, hit testing, or keys.
        switch next.content {
        case let .replacing(_, result), let .ready(result):
            publishReadyResult(result)
            return
        default:
            onInteractionAvailabilityChanged?(allowsInteraction)
        }

        transitionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
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
        completedResult = nil
        isRefining = false
        onInteractionAvailabilityChanged?(false)
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
        canRefineReviewedDraft = false
        canUndoRefinement = false
        refinementUnavailableReason = nil
        reviewNotice = nil
        lastRefinementInstruction = nil
        selectedTextContextStatus = nil
        sessionMemoryContextStatus = nil
        sessionFactsReviewSource = nil
        selectedTextReviewSource = nil
        isInspectingSource = false
        isInspectingFacts = false
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
            statusText = isRefining
                ? (isSlow ? "Still refining" : "Refining")
                : (isSlow ? "Still composing" : "Composing")
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
        case .replacing, .ready:
            // Published by apply before scheduling any cosmetic work.
            return
        case let .persistentMemoryProposal(proposal):
            statusText = proposal.replacingFact == nil ? "Review saved fact" : "Review correction"
            displayedSource = ""
            if let previous = proposal.replacingFact {
                displayedResult = "Replace this saved fact:\n\n\(previous)\n\nWith:\n\n\(proposal.fact)"
            } else {
                displayedResult = "Save this exact fact for this document for up to 30 days?\n\n\(proposal.fact)"
            }
            sourceOpacity = 0
            resultOpacity = 1
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 1
            }
        case let .persistentMemoryForgetProposal(proposal):
            statusText = "Forget saved facts?"
            displayedSource = ""
            displayedResult = "Remove \(proposal.factCount) saved \(proposal.factCount == 1 ? "fact" : "facts") for this document from this Mac?"
            sourceOpacity = 0
            resultOpacity = 1
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 1
            }
        case let .memoryNotice(notice):
            statusText = notice.title
            displayedSource = ""
            displayedResult = notice.detail
            sourceOpacity = 0
            resultOpacity = 1
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 1
            }
        case let .insertionRecovery(message, result):
            statusText = "Check insertion"
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
            statusText = "Compose needs attention"
            displayedSource = ""
            displayedResult = message
            sourceOpacity = 0
            resultOpacity = 1
            withAnimation(reducedMotion ? nil : ScribeNotchMotion.content) {
                actionsOpacity = 1
            }
        }
    }

    private func publishReadyResult(_ result: ScribeResult) {
        displayedSource = ""
        displayedResult = result.text
        sourceOpacity = 0
        resultOpacity = 1
        actionsOpacity = 1
        contentOpacity = 1
        statusText = readyStatusText
        onInteractionAvailabilityChanged?(true)
        guard completedResult != result else { return }
        completedResult = result
        insertEmphasisRevision += 1
        onReplacementCompleted?()
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
                if model.screenDraftPhase != .idle {
                    screenDraftCanvas
                } else if case .transcribing = model.presentation.content {
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

            VStack(spacing: 12) {
                ScribeTranscribingStatusView(fontSize: 12, spacing: 8)
                if model.isRefining {
                    cancelRefinementButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    private var screenDraftCanvas: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Use visible context")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
                Spacer()
                Button("Back") { model.onCancelScreenDraft?() }
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(FlowTheme.textSecondary)
                    .accessibilityIdentifier("scribe-screen-back")
            }
            switch model.screenDraftPhase {
            case .idle:
                EmptyView()
            case .awaitingCaptureApproval:
                Text("Choose one window. Cadence will read its visible text on this Mac for this draft. The screenshot is not saved.")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                Spacer(minLength: 0)
                screenDraftAction("Choose window", identifier: "scribe-screen-approve-reading") {
                    model.onApproveScreenReading?()
                }
            case .choosingAndReading:
                Text("Choose the original window in the system picker. Reading visible text on this Mac…")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
            case let .awaitingProviderApproval(sourcePreview):
                Text("Send this recognized text to Apple Intelligence on this Mac to draft a response? It will not be saved as memory.")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                ScrollView {
                    Text(sourcePreview)
                        .font(.system(size: 11))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("scribe-screen-source-preview")
                screenDraftAction("Use text for draft", identifier: "scribe-screen-approve-provider") {
                    model.onApproveScreenProviderUse?()
                }
            case .drafting:
                Text("Drafting from the text you approved…")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
            case let .ready(text):
                Text("Screen-grounded draft · Review and copy")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(FlowTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("scribe-screen-draft")
                screenDraftAction("Copy draft", identifier: "scribe-screen-copy") {
                    model.onCopyScreenDraft?()
                }
            case .unavailable:
                Text("Screen context is unavailable for this request. Your previous draft is still here.")
                    .font(.system(size: 11))
                    .foregroundStyle(FlowTheme.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, model.hasHardwareNotch ? ScribeNotchGeometry.hardwareNotchContentInset + 9 : 10)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("scribe-screen-review")
    }

    private func screenDraftAction(
        _ title: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FlowTheme.accent)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier(identifier)
    }

    private var header: some View {
        HStack(spacing: 7) {
            phaseStatus
                .id(model.statusText)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            Spacer(minLength: 8)
            if model.canUseScreenContext {
                Button("Use screen") { model.onBeginScreenDraft?() }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .buttonStyle(.plain)
                    .help("Choose the original window and approve local visible-text reading")
                    .accessibilityIdentifier("scribe-use-screen-context")
            }
            if model.showsRefinementActions, let source = model.selectedTextReviewSource {
                ScribeSelectedTextSourceControl(source: source, identifier: "scribe-notch-selected-text-context",
                    canInspect: { model.onInspectSelectedTextSource?(source.id) ?? false },
                    onExclude: { model.onExcludeSelectedTextSource?($0) },
                    onRecordNewMessage: { model.onRecordWithoutSelectedSource?($0) },
                        onRefresh: { model.onRefreshSelectedTextSource?($0) },
                    onPresentationChange: { model.setInspectingSource($0, sourceID: source.id) })
            } else if model.showsRefinementActions, let status = model.selectedTextContextStatus {
                Text(status)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
                    .help("This draft used selected text from TextEdit, processed on this Mac.")
                    .accessibilityIdentifier("scribe-notch-selected-text-context")
            }
            if model.showsRefinementActions, let source = model.sessionFactsReviewSource {
                ScribeSessionFactsControl(
                    source: source, identifier: "scribe-notch-session-memory-context",
                    onRegenerateWithoutFacts: { model.onRegenerateWithoutSessionFacts?($0) },
                    onRegenerateWithoutFact: { model.onRegenerateWithoutSessionFact?($0, $1) },
                    onPresentationChange: { model.setInspectingFacts($0, sourceID: source.id) }
                )
            } else if model.showsRefinementActions, let status = model.sessionMemoryContextStatus {
                Text(status)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
                    .help("This draft used explicitly saved facts from this TextEdit document on this Mac.")
                    .accessibilityIdentifier("scribe-notch-session-memory-context")
            }
            if model.isRefining {
                cancelRefinementButton
            }
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
        } else if model.statusText == "Composing"
                    || model.statusText == "Still composing" {
            ScribeScribingStatusView(isSlow: model.statusText == "Still composing")
        } else {
            HStack(spacing: 7) {
                if model.statusText == "Composed" {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlowTheme.textPrimary)
                } else if case .memoryNotice = model.presentation.content {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlowTheme.textPrimary)
                } else if case .persistentMemoryProposal = model.presentation.content {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)
                } else if case .persistentMemoryForgetProposal = model.presentation.content {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FlowTheme.textPrimary)
                } else if model.reviewNotice != nil {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlowTheme.textSecondary)
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
            VStack(alignment: .leading, spacing: 8) {
                if model.showsRefinementActions, let reviewNotice = model.reviewNotice {
                    Text(reviewNotice)
                        .foregroundStyle(FlowTheme.textSecondary)
                        .accessibilityIdentifier("scribe-notch-refinement-notice")
                    if let instruction = model.lastRefinementInstruction {
                        Text("Last refinement: \(instruction)")
                            .foregroundStyle(FlowTheme.textSecondary)
                            .accessibilityIdentifier("scribe-notch-refinement-instruction")
                    }
                }
                ZStack(alignment: .topLeading) {
                    Text(model.displayedSource)
                        .foregroundStyle(FlowTheme.textSecondary)
                        .opacity(model.sourceOpacity)
                    Text(model.displayedResult)
                        .foregroundStyle(FlowTheme.textPrimary)
                        .opacity(model.resultOpacity)
                }
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
            if case let .persistentMemoryProposal(proposal) = model.presentation.content {
                notchIconAction(
                    systemName: "xmark", label: "Discard",
                    accessibilityIdentifier: "scribe-notch-memory-discard"
                ) { model.onDiscard?() }
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button(proposal.replacingFact == nil ? "Save fact" : "Save correction") {
                    model.onSavePersistentMemory?(proposal.proposalID)
                }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.accent)
                    .buttonStyle(.plain)
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .accessibilityLabel(proposal.replacingFact == nil
                        ? "Save this exact fact for this document"
                        : "Save this correction for this document")
                    .accessibilityIdentifier("scribe-notch-memory-save")
                    .keyboardShortcut(.defaultAction)
            } else if case let .persistentMemoryForgetProposal(proposal) = model.presentation.content {
                notchIconAction(
                    systemName: "xmark", label: "Keep facts",
                    accessibilityIdentifier: "scribe-notch-memory-forget-cancel"
                ) { model.onDiscard?() }
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Forget facts") {
                    model.onConfirmPersistentMemoryForget?(proposal.proposalID)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FlowTheme.accent)
                .buttonStyle(.plain)
                .frame(height: 28)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("scribe-notch-memory-forget-confirm")
                .keyboardShortcut(.defaultAction)
            } else if case .memoryNotice = model.presentation.content {
                Spacer(minLength: 0)
                Button("Done") { model.onDiscard?() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.accent)
                    .buttonStyle(.plain)
                    .frame(height: 28)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("scribe-notch-memory-done")
            } else if case .failure = model.presentation.content {
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
                    .help("Try Compose again")
                    .accessibilityIdentifier("scribe-notch-retry")
                case .setUpProvider:
                    recoveryButton(
                        "Set up provider",
                        help: "Set up an AI provider for Compose",
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
                    label: model.selectedTextReviewSource?.isExcluded == true ? "Copy previous draft" : "Copy",
                    accessibilityIdentifier: "scribe-notch-copy"
                ) {
                    model.onCopy?()
                }
                if model.showsRefinementActions {
                    Button("Refine") { model.onRefine?() }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(FlowTheme.textSecondary)
                        .disabled(!model.canRefineReviewedDraft)
                        .opacity(model.canRefineReviewedDraft ? 1 : 0.4)
                        .help(model.refinementHelp)
                        .accessibilityHint(model.refinementHelp)
                        .accessibilityIdentifier("scribe-notch-refine")
                    Button("Undo") { model.onUndoRefinement?() }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(FlowTheme.textSecondary)
                        .disabled(!model.canUndoRefinement)
                        .opacity(model.canUndoRefinement ? 1 : 0.4)
                        .help("Restore the previous draft")
                        .accessibilityIdentifier("scribe-notch-undo-refinement")
                }
                Spacer(minLength: 0)
                ScribeInsertActionButton(
                    emphasisRevision: model.insertEmphasisRevision
                ) {
                    model.onInsert?()
                }
                .disabled(!model.permitsReviewedInsertion)
                .opacity(model.permitsReviewedInsertion ? 1 : 0.4)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 43)
        .opacity(model.isRefining ? 0 : model.actionsOpacity)
        .allowsHitTesting(model.showsReviewActions)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private var cancelRefinementButton: some View {
        Button("Cancel refinement") { model.onCancelRefinement?() }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(FlowTheme.textSecondary)
            .buttonStyle(.plain)
            .help("Keep the previous draft (Escape)")
            .accessibilityIdentifier("scribe-notch-cancel-refinement")
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
                CadenceComposeIcon(size: 14)
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

                Text(isSlow ? "Still composing" : "Composing")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FlowTheme.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSlow ? "Still composing" : "Composing")
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
