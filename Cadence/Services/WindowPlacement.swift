import AppKit

enum WindowPlacement {
    static func visibleFrame(containing point: NSPoint = NSEvent.mouseLocation) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? .zero
    }
}
