import SwiftUI

struct HUDDropZoneOverlay: View {
    @ObservedObject var model: HUDDropZoneViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            for position in HUDPosition.allCases {
                let rect = zoneRect(position, screenSize: size)
                let path = Path(roundedRect: rect, cornerRadius: 12)
                let isNearest = model.nearestZone == position
                let opacity: Double = isNearest ? 0.35 : 0.12
                context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: isNearest ? 2 : 1)
                if isNearest {
                    context.fill(path, with: .color(.white.opacity(0.05)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.nearestZone)
    }

    private func zoneRect(_ position: HUDPosition, screenSize: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let size: CGFloat = 80
        switch position {
        case .bottomCenter:
            return CGRect(x: (screenSize.width - size) / 2, y: screenSize.height - inset - size, width: size, height: size)
        case .topLeft:
            return CGRect(x: inset, y: inset, width: size, height: size)
        case .topRight:
            return CGRect(x: screenSize.width - inset - size, y: inset, width: size, height: size)
        case .bottomLeft:
            return CGRect(x: inset, y: screenSize.height - inset - size, width: size, height: size)
        case .bottomRight:
            return CGRect(x: screenSize.width - inset - size, y: screenSize.height - inset - size, width: size, height: size)
        }
    }
}

@MainActor
final class HUDDropZoneViewModel: ObservableObject {
    @Published var nearestZone: HUDPosition?
}
