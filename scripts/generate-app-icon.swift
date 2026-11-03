import AppKit

// Original vector artwork. Regenerate without third-party raster assets.
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.04, green: 0.43, blue: 0.97, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
let heart = NSBezierPath()
heart.move(to: NSPoint(x: 512, y: 250))
heart.curve(
  to: NSPoint(x: 218, y: 586), controlPoint1: NSPoint(x: 310, y: 406),
  controlPoint2: NSPoint(x: 218, y: 465))
heart.curve(
  to: NSPoint(x: 512, y: 687), controlPoint1: NSPoint(x: 218, y: 780),
  controlPoint2: NSPoint(x: 428, y: 821))
heart.curve(
  to: NSPoint(x: 806, y: 586), controlPoint1: NSPoint(x: 596, y: 821),
  controlPoint2: NSPoint(x: 806, y: 780))
heart.curve(
  to: NSPoint(x: 512, y: 250), controlPoint1: NSPoint(x: 806, y: 465),
  controlPoint2: NSPoint(x: 714, y: 406))
heart.close()
NSColor.white.setFill()
heart.fill()
let pulse = NSBezierPath()
pulse.lineWidth = 35
pulse.lineCapStyle = .round
pulse.lineJoinStyle = .round
pulse.move(to: NSPoint(x: 316, y: 548))
pulse.line(to: NSPoint(x: 416, y: 548))
pulse.line(to: NSPoint(x: 468, y: 624))
pulse.line(to: NSPoint(x: 536, y: 450))
pulse.line(to: NSPoint(x: 590, y: 548))
pulse.line(to: NSPoint(x: 708, y: 548))
NSColor(calibratedRed: 0.04, green: 0.43, blue: 0.97, alpha: 1).setStroke()
pulse.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 3,
  hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(
  to: URL(fileURLWithPath: CommandLine.arguments[1]))
