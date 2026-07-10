import SwiftUI

struct HUDView: View {
    @ObservedObject var model: HUDViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasDragged = false

    private static let dragThreshold: CGFloat = 4

    var body: some View {
        Group {
            switch model.state.visualState {
            case .idle:
                if model.isExpanded {
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
        .animation(reduceMotion ? nil : .timingCurve(0.25, 0, 0, 1, duration: 0.18), value: model.state.visualState)
        .animation(reduceMotion ? nil : FlowMotion.control, value: model.isExpanded)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityLabel(model.state.visualState.accessibilityLabel)
        .accessibilityHint(model.state.visualState.accessibilityHint ?? "")
        .onAppear { model.setReducedMotion(reduceMotion) }
        .onChange(of: reduceMotion) { _, reduced in model.setReducedMotion(reduced) }
    }

    private var logoBadge: some View {
        let radii = model.position.cornerRadii
        return Image("HUDLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: 44, height: 44)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: radii.topLeading,
                    bottomLeadingRadius: radii.bottomLeading,
                    bottomTrailingRadius: radii.bottomTrailing,
                    topTrailingRadius: radii.topTrailing,
                    style: .continuous
                )
            )
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
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
                .frame(width: 112, height: 28)

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

    private var adaptiveClipShape: UnevenRoundedRectangle {
        let radii = model.position.cornerRadii
        return UnevenRoundedRectangle(
            topLeadingRadius: radii.topLeading,
            bottomLeadingRadius: radii.bottomLeading,
            bottomTrailingRadius: radii.bottomTrailing,
            topTrailingRadius: radii.topTrailing,
            style: .continuous
        )
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

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !hasDragged {
                    let distance = abs(value.translation.width) + abs(value.translation.height)
                    if distance < Self.dragThreshold { return }
                    hasDragged = true
                }
                model.onDrag?(value.translation)
            }
            .onEnded { _ in
                if hasDragged {
                    model.onDragEnded?()
                } else if model.state.visualState == .idle {
                    model.toggleExpanded()
                }
                hasDragged = false
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

            let barWidth: CGFloat = 3
            let barGap: CGFloat = 3
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
