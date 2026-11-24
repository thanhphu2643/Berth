// Draws Resources/AppIcon.icns: three containers on a pier above the water, on a plum tile.
// Run: swift scripts/make-icon.swift
import AppKit

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: r, green: g, blue: b, alpha: a)
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Tile on Apple's icon grid: 824pt body, 100pt margin, soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill()
    shape.fill()
    ctx.restoreGState()
    ctx.saveGState()
    shape.addClip()
    NSGradient(colors: [color(0.36, 0.23, 0.42), color(0.17, 0.11, 0.24)])!.draw(in: tile, angle: -90)

    // Water: two waves across the bottom of the tile.
    for (y, alpha) in [(CGFloat(250), CGFloat(0.55)), (CGFloat(185), CGFloat(0.35))] {
        let wave = NSBezierPath()
        wave.move(to: CGPoint(x: 60, y: y))
        var x: CGFloat = 60
        while x < 980 {
            wave.curve(to: CGPoint(x: x + 110, y: y), controlPoint1: CGPoint(x: x + 30, y: y + 32), controlPoint2: CGPoint(x: x + 80, y: y - 32))
            x += 110
        }
        wave.lineWidth = 26
        wave.lineCapStyle = .round
        color(0.45, 0.78, 0.86, alpha).setStroke()
        wave.stroke()
    }

    // The pier.
    let pier = NSBezierPath(roundedRect: CGRect(x: 170, y: 310, width: 684, height: 46), xRadius: 14, yRadius: 14)
    color(0.86, 0.80, 0.70).setFill()
    pier.fill()
    for x in [230, 500, 770] as [CGFloat] {
        let post = NSBezierPath(roundedRect: CGRect(x: x - 18, y: 230, width: 36, height: 100), xRadius: 10, yRadius: 10)
        color(0.70, 0.62, 0.52).setFill()
        post.fill()
    }

    // Three containers: two side by side, one on top.
    let boxes: [(rect: CGRect, fill: NSColor, ribs: NSColor)] = [
        (CGRect(x: 205, y: 356, width: 300, height: 170), color(0.31, 0.71, 0.73), color(0.20, 0.55, 0.58)),
        (CGRect(x: 519, y: 356, width: 300, height: 170), color(0.98, 0.70, 0.33), color(0.85, 0.53, 0.18)),
        (CGRect(x: 362, y: 540, width: 300, height: 170), color(0.95, 0.47, 0.42), color(0.80, 0.31, 0.29)),
    ]
    for box in boxes {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        box.fill.setFill()
        NSBezierPath(roundedRect: box.rect, xRadius: 18, yRadius: 18).fill()
        ctx.restoreGState()
        // Corrugation ribs.
        box.ribs.setFill()
        var x = box.rect.minX + 42
        while x < box.rect.maxX - 30 {
            NSBezierPath(roundedRect: CGRect(x: x, y: box.rect.minY + 26, width: 16, height: box.rect.height - 52), xRadius: 8, yRadius: 8).fill()
            x += 46
        }
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("BerthIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
try! render(1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print("Wrote \(out.path)")
