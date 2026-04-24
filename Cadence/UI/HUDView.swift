import SwiftUI

struct HUDView: View {
    @ObservedObject var model: HUDViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.state.visualState {
            case .recording(let triggerMode, let showsHint):
                recordingPill(triggerMode: triggerMode, showsHint: showsHint)
            case .transcribing:
                statusPill(icon: .spinner, text: "Transcribing…")
            case .error(let message):
                statusPill(icon: .error, text: message)
            }
        }
        .animation(reduceMotion ? nil : .timingCurve(0.25, 0, 0, 1, duration: 0.18), value: model.state.visualState)
        .contentShape(Rectangle())
        .gesture(dragGesture)
    }

    private func recordingPill(triggerMode: DictationTriggerMode, showsHint: Bool) -> some View {
        HStack(spacing: 10) {
            if triggerMode == .tapToStartStop {
                dismissButton
            }

            WaveformCanvasView(levels: model.displayBars)
                .frame(width: 96, height: 20)

            if triggerMode == .holdToTalk, showsHint {
                Text("Release to stop")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(FlowTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            if triggerMode == .tapToStartStop {
                stopButton
            }
        }
        .padding(.horizontal, triggerMode == .tapToStartStop ? 8 : 14)
        .frame(width: pillWidth(triggerMode: triggerMode, showsHint: showsHint), height: 38)
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

    private var dismissButton: some View {
        Button(action: { model.onCancel?() }) {
            ZStack {
                Circle()
                    .fill(FlowTheme.subtle)
                    .frame(width: 20, height: 20)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(FlowTheme.textSecondary)
            }
        }
        .buttonStyle(HUDControlButtonStyle())
    }

    private var stopButton: some View {
        Button(action: { model.onStop?() }) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white)
                .frame(width: 16, height: 16)
                .padding(10)
                .background(FlowTheme.accent, in: Circle())
        }
        .buttonStyle(HUDControlButtonStyle())
    }

    private func pillWidth(triggerMode: DictationTriggerMode, showsHint: Bool) -> CGFloat {
        switch triggerMode {
        case .tapToStartStop:
            return 188
        case .holdToTalk:
            return showsHint ? 228 : 140
        }
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(FlowTheme.elevated)
    }

    private var pillStroke: some View {
        Capsule(style: .continuous)
            .stroke(FlowTheme.border, lineWidth: 1)
    }

    private enum StatusIcon {
        case spinner
        case error
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                model.onDrag?(value.translation)
            }
            .onEnded { _ in
                model.onDragEnded?()
            }
    }
}

private struct HUDSpinnerView: View {
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
            let maxHeight: CGFloat = 18
            let minHeight: CGFloat = 2
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
            let startX = max(0, (size.width - totalWidth) / 2)

            for (index, level) in levels.enumerated() {
                let clamped = max(0, min(1, level))
                let barHeight = minHeight + CGFloat(clamped) * (maxHeight - minHeight)
                let x = startX + CGFloat(index) * (barWidth + barGap)
                let y = (size.height - barHeight) / 2
                let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                let path = Path(roundedRect: rect, cornerRadius: 2)
                context.fill(path, with: .color(FlowTheme.accent.opacity(0.82)))
            }
        }
    }
}

private struct HUDControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
