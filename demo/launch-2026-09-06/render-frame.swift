import AppKit

let size = NSSize(width: 1920, height: 1080)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.086, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    (value as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}
let mint = NSColor(calibratedRed: 0.455, green: 0.941, blue: 0.769, alpha: 1)
text("C A D E N C E", x: 76, y: 885, width: 480, height: 60, size: 26, weight: .semibold, color: mint)
text("Your voice.\nYour workflow.", x: 76, y: 520, width: 520, height: 260, size: 66, weight: .semibold, color: .white)
text("A first look at\nCadence for Mac.", x: 80, y: 345, width: 450, height: 120, size: 30, weight: .regular, color: NSColor(white: 0.65, alpha: 1))
text("REAL APP CAPTURE  /  PRODUCT TOUR DRAFT", x: 80, y: 80, width: 1100, height: 35, size: 18, weight: .medium, color: NSColor(white: 0.55, alpha: 1))
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
