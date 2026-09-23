import AppKit

let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("icon context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let canvas = NSRect(x: 0, y: 0, width: size, height: size)
NSColor.clear.setFill()
canvas.fill()

let inset: CGFloat = 56
let tile = NSBezierPath(roundedRect: canvas.insetBy(dx: inset, dy: inset), xRadius: 205, yRadius: 205)
NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.17, alpha: 1).setFill()
tile.fill()

let center = NSPoint(x: 512, y: 512)
func band(inner: CGFloat, outer: CGFloat, from: CGFloat, to: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: outer, startAngle: from, endAngle: to, clockwise: false)
    path.appendArc(withCenter: center, radius: inner, startAngle: to, endAngle: from, clockwise: true)
    path.close()
    color.setFill()
    path.fill()
}

let mint = NSColor(calibratedRed: 0.26, green: 0.87, blue: 0.76, alpha: 1)
let cyan = NSColor(calibratedRed: 0.21, green: 0.72, blue: 0.89, alpha: 1)
let amber = NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.33, alpha: 1)
let coral = NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.43, alpha: 1)
band(inner: 136, outer: 235, from: 3, to: 177, color: mint)
band(inner: 136, outer: 235, from: 183, to: 262, color: cyan)
band(inner: 136, outer: 235, from: 268, to: 357, color: amber)
band(inner: 247, outer: 344, from: 3, to: 119, color: mint)
band(inner: 247, outer: 344, from: 125, to: 177, color: coral)
band(inner: 247, outer: 344, from: 183, to: 262, color: cyan)
band(inner: 247, outer: 344, from: 268, to: 321, color: amber)
band(inner: 247, outer: 344, from: 327, to: 357, color: coral)

let middle = NSBezierPath(ovalIn: NSRect(x: 407, y: 407, width: 210, height: 210))
NSColor(calibratedRed: 0.11, green: 0.17, blue: 0.24, alpha: 1).setFill()
middle.fill()
let dot = NSBezierPath(ovalIn: NSRect(x: 478, y: 478, width: 68, height: 68))
mint.setFill()
dot.fill()

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("png") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
