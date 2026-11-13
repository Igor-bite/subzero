// Renders the Freezer app icon and builds Icon.icns in the repo root.
// Usage: swift Scripts/make_icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/Icon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels) / 1024

    // Apple icon grid: 824×824 body centered on a 1024 canvas.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    // Drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Background gradient: icy cyan → sky blue → deep blue.
    let gradient = NSGradient(colors: [
        NSColor(red: 0.45, green: 0.86, blue: 0.98, alpha: 1),
        NSColor(red: 0.24, green: 0.62, blue: 0.95, alpha: 1),
        NSColor(red: 0.13, green: 0.36, blue: 0.86, alpha: 1),
    ])!
    gradient.draw(in: squircle, angle: -60)

    // Soft top highlight.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    /// Draws an SF Symbol centered at `center`, optionally with a soft shadow.
    func drawSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, colors: [NSColor],
                    center: NSPoint, shadowAlpha: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let rect = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                          width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        if shadowAlpha > 0 {
            let glyphShadow = NSShadow()
            glyphShadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
            glyphShadow.shadowBlurRadius = 18 * s
            glyphShadow.shadowOffset = NSSize(width: 0, height: -8 * s)
            glyphShadow.set()
        }
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Big white snowflake, nudged up-left to leave room for the shield.
    drawSymbol("snowflake", pointSize: 500 * s, weight: .semibold, colors: [.white],
               center: NSPoint(x: body.midX - 30 * s, y: body.midY + 30 * s), shadowAlpha: 0.22)

    // Small shield in front, bottom-right. A larger shield in the background
    // color underneath acts as a cut-out outline separating it from the snowflake.
    let shieldCenter = NSPoint(x: body.maxX - 205 * s, y: body.minY + 215 * s)
    let outline = NSColor(red: 0.13, green: 0.36, blue: 0.86, alpha: 1)
    drawSymbol("shield.fill", pointSize: 300 * s, weight: .black, colors: [outline],
               center: shieldCenter, shadowAlpha: 0)
    let check = NSColor(red: 0.13, green: 0.70, blue: 0.40, alpha: 1)
    drawSymbol("checkmark.shield.fill", pointSize: 245 * s, weight: .bold, colors: [check, .white],
               center: shieldCenter, shadowAlpha: 0.25)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, px) in sizes {
    try render(pixels: px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try render(pixels: 1024).write(to: root.appendingPathComponent(".build/Icon-preview.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Icon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Icon.icns written" : "iconutil failed")
