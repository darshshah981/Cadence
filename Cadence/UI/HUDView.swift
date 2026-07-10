import SwiftUI

struct HUDAdaptiveShape: Shape {
    let position: HUDPosition

    func path(in rect: CGRect) -> Path {
        let radii = position.cornerRadii
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing,
            style: .continuous
        ).path(in: rect)
    }
}

struct HUDContentAttachment {
    let alignment: Alignment
    let anchor: UnitPoint

    static func forPosition(_ position: HUDPosition) -> HUDContentAttachment {
        switch position {
        case .bottomCenter:
            HUDContentAttachment(alignment: .bottom, anchor: .bottom)
        case .topLeft:
            HUDContentAttachment(alignment: .topLeading, anchor: .topLeading)
        case .topRight:
            HUDContentAttachment(alignment: .topTrailing, anchor: .topTrailing)
        case .bottomLeft:
            HUDContentAttachment(alignment: .bottomLeading, anchor: .bottomLeading)
        case .bottomRight:
            HUDContentAttachment(alignment: .bottomTrailing, anchor: .bottomTrailing)
        }
    }

    static func appKitOrigin(
        position: HUDPosition,
        contentSize: NSSize,
        containerSize: NSSize
    ) -> NSPoint {
        switch position {
        case .bottomCenter:
            NSPoint(x: (containerSize.width - contentSize.width) / 2, y: 0)
        case .topLeft:
            NSPoint(x: 0, y: containerSize.height - contentSize.height)
        case .topRight:
            NSPoint(
                x: containerSize.width - contentSize.width,
                y: containerSize.height - contentSize.height
            )
        case .bottomLeft:
            .zero
        case .bottomRight:
            NSPoint(x: containerSize.width - contentSize.width, y: 0)
        }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: attachment.alignment) {
            if let previous = model.previousPresentation {
                content(for: previous)
                    .opacity(1 - model.morphProgress)
                    .scaleEffect(
                        x: 1 - 0.04 * model.morphProgress,
                        y: 1,
                        anchor: attachment.anchor
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            content(for: model.presentation)
                .opacity(model.previousPresentation == nil ? 1 : model.morphProgress)
                .scaleEffect(
                    x: model.previousPresentation == nil ? 1 : 0.96 + 0.04 * model.morphProgress,
                    y: 1,
                    anchor: attachment.anchor
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: attachment.alignment)
        .clipped()
        .modifier(HUDRootAccessibilityModifier(presentation: model.presentation))
        .onAppear { model.setReducedMotion(reduceMotion) }
        .onChange(of: reduceMotion) { _, reduced in model.setReducedMotion(reduced) }
    }

    @ViewBuilder
    private func content(for presentation: HUDPresentation) -> some View {
        switch presentation.visualState {
        case .idle:
            if presentation.isExpanded {
                IdleExpandedTray(model: model)
            } else {
                logoBadge
            }
        case .recording(let triggerMode, let showsHint):
            recordingPill(triggerMode: triggerMode, showsHint: showsHint)
        case .preparingModel:
            statusPill(icon: .spinner, text: "Setting up speech model…")
        case .transcribing:
            statusPill(icon: .spinner, text: "Transcribing…")
        case .inserting:
            statusPill(icon: .spinner, text: "Inserting…")
        case .success:
            statusPill(icon: .success, text: "Inserted")
        case .cancelled:
            statusPill(icon: .cancelled, text: "Cancelled")
        case .error(let message):
            statusPill(icon: .error, text: message)
        }
    }

    private var logoBadge: some View {
        ZStack(alignment: attachment.alignment) {
            Color.clear
            Image("HUDLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: HUDMetrics.idleMarkSize.width, height: HUDMetrics.idleMarkSize.height)
                .clipShape(HUDAdaptiveShape(position: model.position))
        }
            .frame(width: HUDMetrics.idleHitSize.width, height: HUDMetrics.idleHitSize.height)
            .overlay {
                HUDLogoInteractionSurface(model: model)
            }
    }

    private var attachment: HUDContentAttachment {
        HUDContentAttachment.forPosition(model.position)
    }

    private func recordingPill(triggerMode: DictationTriggerMode, showsHint: Bool) -> some View {
        HStack(spacing: 10) {
            if triggerMode.showsLockIndicator {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlowTheme.accent)
                    .accessibilityHidden(true)
            }

            WaveformCanvasView(levels: model.displayBars)
                .frame(width: HUDMetrics.waveformWidth, height: HUDMetrics.waveformHeight)

            if triggerMode == .holdToTalk, showsHint {
                Text("Release to stop")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .frame(width: pillWidth(triggerMode: triggerMode, showsHint: showsHint), height: HUDMetrics.pillHeight)
        .background(pillBackground)
        .overlay(pillStroke)
    }

    private func statusPill(icon: StatusIcon, text: String) -> some View {
        HStack(spacing: 8) {
            switch icon {
            case .spinner:
                HUDSpinnerView()
            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FlowTheme.error)
            case .success:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FlowTheme.accent)
            case .cancelled:
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(FlowTheme.textSecondary)
            }

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(icon == .error ? FlowTheme.error : FlowTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(pillBackground)
        .overlay(pillStroke)
    }

    private func pillWidth(triggerMode: DictationTriggerMode, showsHint: Bool) -> CGFloat {
        switch triggerMode {
        case .tapToStartStop:
            return HUDMetrics.compactWidth
        case .holdToTalk:
            return showsHint ? HUDMetrics.holdHintWidth : HUDMetrics.compactWidth
        }
    }

    private var adaptiveClipShape: HUDAdaptiveShape {
        HUDAdaptiveShape(position: model.position)
    }

    private var pillBackground: some View {
        adaptiveClipShape
            .fill(FlowTheme.elevated)
    }

    private var pillStroke: some View {
        adaptiveClipShape
            .stroke(FlowTheme.border, lineWidth: 1)
    }

    private enum StatusIcon {
        case spinner
        case error
        case success
        case cancelled
    }

}

private struct HUDRootAccessibilityModifier: ViewModifier {
    let presentation: HUDPresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        if presentation.exposesInteractiveChildren {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.visualState.accessibilityLabel)
                .accessibilityHint(presentation.visualState.accessibilityHint ?? "")
        }
    }
}

/// AppKit owns the logo pointer sequence so coordinates remain stable while its
/// panel moves. This surface exists only for the collapsed idle logo; expanded
/// tray buttons therefore never compete with drag recognition.
private struct HUDLogoInteractionSurface: NSViewRepresentable {
    @ObservedObject var model: HUDViewModel

    func makeNSView(context: Context) -> HUDLogoInteractionView {
        let view = HUDLogoInteractionView()
        view.setAccessibilityElement(false)
        configure(view)
        return view
    }

    func updateNSView(_ view: HUDLogoInteractionView, context: Context) {
        configure(view)
    }

    private func configure(_ view: HUDLogoInteractionView) {
        view.onEvent = { [weak model] event in
            model?.handleLogoInteraction(event)
        }
    }
}

final class HUDLogoInteractionView: NSView {
    var onEvent: ((HUDLogoInteractionEvent) -> Void)?
    private var tracker = HUDLogoPointerTracker()

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        tracker.begin(at: point)
        onEvent?(.began(point))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        guard tracker.update(to: point) else { return }
        onEvent?(.moved(point))
    }

    override func mouseUp(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        switch tracker.end(at: point) {
        case .click:
            onEvent?(.clicked)
        case .drag:
            onEvent?(.moved(point))
            onEvent?(.ended(point))
        case .none:
            break
        }
    }
}

struct HUDSpinnerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(FlowTheme.accent)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .frame(width: 14, height: 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
            .onChange(of: reduceMotion) { _, reduced in
                guard !reduced else {
                    isAnimating = false
                    return
                }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
            .onDisappear {
                isAnimating = false
            }
    }
}

private struct WaveformCanvasView: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let barCount = levels.count
            guard barCount > 0 else { return }

            let barWidth = HUDMetrics.waveformBarWidth
            let barGap = HUDMetrics.waveformBarGap
            let maxHeight = max(22, size.height - 2)
            let minHeight: CGFloat = 4
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
            let startX = max(0, (size.width - totalWidth) / 2)

            for (index, level) in levels.enumerated() {
                let clamped = max(0, min(1, level))
                let boosted = sqrt(clamped)
                let barHeight = minHeight + CGFloat(boosted) * (maxHeight - minHeight)
                let x = startX + CGFloat(index) * (barWidth + barGap)
                let y = (size.height - barHeight) / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                context.fill(path, with: .color(FlowTheme.accent.opacity(0.96)))
            }
        }
    }
}

struct HUDControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
