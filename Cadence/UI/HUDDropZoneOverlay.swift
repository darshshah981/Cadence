import SwiftUI

enum HUDDropZoneGeometry {
    static func canvasRect(
        for position: HUDPosition,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> CGRect {
        let panelOrigin = position.origin(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            hudSize: HUDMetrics.idleHitSize
        )
        let panelFrame = NSRect(origin: panelOrigin, size: HUDMetrics.idleHitSize)
        let markFrame = position.visibleMarkFrame(in: panelFrame)
        return CGRect(
            x: markFrame.minX - screenFrame.minX,
            y: screenFrame.maxY - markFrame.maxY,
            width: markFrame.width,
            height: markFrame.height
        )
    }
}

struct HUDDropZoneOverlay: View {
    @ObservedObject var model: HUDDropZoneViewModel
    var body: some View {
        Canvas { context, _ in
            for position in HUDPosition.allCases {
                let rect = HUDDropZoneGeometry.canvasRect(
                    for: position,
                    screenFrame: model.screenFrame,
                    visibleFrame: model.visibleFrame
                )
                let path = HUDAdaptiveShape(position: position).path(in: rect)
                let isNearest = model.nearestZone == position
                let opacity: Double = isNearest ? 0.35 : 0.12
                context.stroke(path, with: .color(.white.opacity(opacity)), lineWidth: isNearest ? 2 : 1)
                if isNearest {
                    context.fill(path, with: .color(.white.opacity(0.05)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class HUDDropZoneViewModel: ObservableObject {
    @Published var nearestZone: HUDPosition?
    @Published private(set) var screenFrame = NSRect.zero
    @Published private(set) var visibleFrame = NSRect.zero

    func configure(screenFrame: NSRect, visibleFrame: NSRect) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
    }
}
