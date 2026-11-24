import AppKit

/// Nook's mark: an arched alcove with a dot inside. Drawn as a template image
/// so the menu bar tints it for light and dark appearances.
enum NookGlyph {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let body = rect.insetBy(dx: 2.5, dy: 1.5)
            let radius = body.width / 2

            let arch = NSBezierPath()
            arch.move(to: NSPoint(x: body.minX, y: body.minY))
            arch.line(to: NSPoint(x: body.minX, y: body.maxY - radius))
            arch.appendArc(withCenter: NSPoint(x: body.midX, y: body.maxY - radius),
                           radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
            arch.line(to: NSPoint(x: body.maxX, y: body.minY))
            arch.close()
            arch.lineWidth = 1.6
            arch.lineJoinStyle = .round
            NSColor.black.setStroke()
            arch.stroke()

            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: body.midX - 2.5, y: body.minY + 3, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Nook"
        return image
    }()
}

/// Status icons drawn on the same 18×18 canvas as `NookGlyph`, so swapping
/// icons never changes the menu bar button's size.
enum StatusIcon {
    static let onBreak = symbol("cup.and.saucer.fill", description: "On Break")
    static let shutdown = symbol("power.circle.fill", description: "Shutdown Scheduled")
    static let recording = symbol("record.circle.fill", description: "Recording Screen")
    static let recordingPaused = symbol("pause.circle.fill", description: "Recording Stopped")
    static let music = symbol("music.note", description: "Playing Music")

    private static func symbol(_ name: String, description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config) else { return nil }

        let image = NSImage(size: NookGlyph.image.size, flipped: false) { rect in
            let size = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
