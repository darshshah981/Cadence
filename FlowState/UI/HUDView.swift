import SwiftUI

struct HUDView: View {
    @ObservedObject var model: HUDViewModel

    var body: some View {
        HStack(spacing: model.state.showsControls ? 10 : 0) {
            if model.state.showsControls {
                controlButton(systemName: "xmark", action: { model.onCancel?() })
            }

            waveform
                .frame(maxWidth: .infinity)

            if model.state.showsControls {
                controlButton(systemName: "stop.fill", action: { model.onStop?() })
            }
        }
        .padding(.horizontal, model.state.showsControls ? 12 : 20)
        .padding(.vertical, 9)
        .frame(
            width: model.state.showsControls ? 164 : 108,
            height: 34,
            alignment: .center
        )
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.05),
                                    Color.cyan.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        )
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<11, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 5, height: barHeight(for: index))
            }
        }
        .frame(width: 46, height: 12, alignment: .center)
    }

    private func controlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func barHeight(for index: Int) -> CGFloat {
        let distanceFromCenter = abs(Double(index) - 5.0)
        let centerWeight = max(0.45, 1.0 - distanceFromCenter * 0.11)
        let oscillation = (sin(model.wavePhase + Double(index) * 0.72) + 1) * 0.5
        let floor = 3.0 + max(0.04, model.displayLevel) * 2.8
        let amplitude = max(0.08, model.displayLevel) * 8.5
        return floor + amplitude * oscillation * centerWeight
    }
}
