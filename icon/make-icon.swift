// Renders the app icon: a 2x2 grid of tool tiles on a graphite squircle.
// Usage: swift icon/make-icon.swift <output.iconset>
// Then:  iconutil -c icns <output.iconset> -o AppIcon.icns

import AppKit

let canvas: CGFloat = 1024

struct Tile {
    let symbol: String
    let top: NSColor
    let bottom: NSColor
}

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

// Reading order: top-left, top-right, bottom-left, bottom-right.
let tiles = [
    Tile(symbol: "power", top: rgb(0xFF6B5E), bottom: rgb(0xE5383B)),
    Tile(symbol: "cup.and.saucer.fill", top: rgb(0xFFC24B), bottom: rgb(0xF08C00)),
    Tile(symbol: "terminal.fill", top: rgb(0x4ADE80), bottom: rgb(0x16A34A)),
    Tile(symbol: "plus", top: rgb(0x60A5FA), bottom: rgb(0x2563EB)),
]

func drawIcon() {
    // Squircle on Apple's macOS icon grid: 824pt body inset 100pt.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    rgb(0x1F2430).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: rgb(0x3A4150), ending: rgb(0x161A22))!.draw(in: bodyPath, angle: -90)

    // Thin inner highlight along the top edge.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rim.lineWidth = 4
    NSColor.white.withAlphaComponent(0.08).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let padding: CGFloat = 92
    let gap: CGFloat = 44
    let side = (body.width - padding * 2 - gap) / 2

    for (index, tile) in tiles.enumerated() {
        let col = CGFloat(index % 2)
        let row = CGFloat(1 - index / 2) // AppKit's origin is bottom-left
        let rect = NSRect(x: body.minX + padding + col * (side + gap),
                          y: body.minY + padding + row * (side + gap),
                          width: side, height: side)
        let path = NSBezierPath(roundedRect: rect, xRadius: 74, yRadius: 74)

        NSGraphicsContext.saveGraphicsState()
        let tileShadow = NSShadow()
        tileShadow.shadowOffset = NSSize(width: 0, height: -6)
        tileShadow.shadowBlurRadius = 14
        tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        tileShadow.set()
        tile.bottom.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: tile.top, ending: tile.bottom)!.draw(in: path, angle: -90)

        let config = NSImage.SymbolConfiguration(pointSize: side * 0.42, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        guard let glyph = NSImage(systemSymbolName: tile.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            fatalError("missing SF Symbol \(tile.symbol)")
        }
        let size = glyph.size
        let scale = min(side * 0.5 / size.width, side * 0.5 / size.height)
        let glyphRect = NSRect(x: rect.midX - size.width * scale / 2,
                               y: rect.midY - size.height * scale / 2,
                               width: size.width * scale,
                               height: size.height * scale)
        glyph.draw(in: glyphRect)
    }
}

func render(pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let scale = CGFloat(pixels) / canvas
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(pixels: base, to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(pixels: base * 2, to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
