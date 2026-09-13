import AppKit
import Foundation
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let base = NSBezierPath(roundedRect: NSRect(x: 66, y: 66, width: 892, height: 892), xRadius: 200, yRadius: 200)
        NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.58, blue: 0.98, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.29, blue: 0.76, alpha: 1))!.draw(in: base, angle: -70)
        NSColor.white.withAlphaComponent(0.96).setFill()
        for y in [CGFloat(278), 406, 534] {
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 288, y: y+66))
            body.line(to: NSPoint(x: 288, y: y+151))
            body.curve(to: NSPoint(x: 736, y: y+151), controlPoint1: NSPoint(x: 390, y: y+70), controlPoint2: NSPoint(x: 634, y: y+70))
            body.line(to: NSPoint(x: 736, y: y+66))
            body.curve(to: NSPoint(x: 288, y: y+66), controlPoint1: NSPoint(x: 736, y: y-40), controlPoint2: NSPoint(x: 288, y: y-40))
            body.close(); body.fill()
        }
        NSBezierPath(ovalIn: NSRect(x: 288, y: 638, width: 448, height: 142)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/icon_\(size)x\(size)\(suffix).png"))
    }
}
