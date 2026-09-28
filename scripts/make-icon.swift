// Renders the app icon: a page being squeezed between two arrows.
// usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Squircle background.
    let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor(red: 0.95, green: 0.27, blue: 0.24, alpha: 1).setFill()
    bg.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor(red: 1.0, green: 0.42, blue: 0.33, alpha: 1),
                        NSColor(red: 0.86, green: 0.16, blue: 0.22, alpha: 1)])!.draw(in: bg, angle: -90)

    // Page.
    let page = NSBezierPath()
    page.move(to: NSPoint(x: 362, y: 250)); page.line(to: NSPoint(x: 662, y: 250))
    page.line(to: NSPoint(x: 662, y: 690)); page.line(to: NSPoint(x: 572, y: 780))
    page.line(to: NSPoint(x: 362, y: 780)); page.close()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setFill(); page.fill()
    ctx.restoreGState()
    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 572, y: 780)); fold.line(to: NSPoint(x: 572, y: 690)); fold.line(to: NSPoint(x: 662, y: 690)); fold.close()
    NSColor(white: 0.85, alpha: 1).setFill(); fold.fill()

    // Text lines.
    NSColor(red: 0.86, green: 0.16, blue: 0.22, alpha: 0.35).setFill()
    for (i, w) in [220, 250, 190, 250, 160].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 397, y: 620 - i * 64, width: w, height: 26), xRadius: 13, yRadius: 13).fill()
    }

    // Squeeze arrows.
    NSColor.white.setFill()
    for dir in [1.0, -1.0] {
        let cx = 512 - dir * 290
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: cx + dir * 110, y: 515))
        arrow.line(to: NSPoint(x: cx + dir * 20, y: 605))
        arrow.line(to: NSPoint(x: cx + dir * 20, y: 555))
        arrow.line(to: NSPoint(x: cx - dir * 55, y: 555))
        arrow.line(to: NSPoint(x: cx - dir * 55, y: 475))
        arrow.line(to: NSPoint(x: cx + dir * 20, y: 475))
        arrow.line(to: NSPoint(x: cx + dir * 20, y: 425))
        arrow.close()
        arrow.fill()
    }
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
