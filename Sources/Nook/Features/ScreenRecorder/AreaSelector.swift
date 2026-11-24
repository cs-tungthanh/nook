import AppKit

/// Dims every screen and lets the user drag out the area to record. Esc cancels.
final class AreaSelector {
    private var windows: [NSWindow] = []
    private let completion: (AreaSelection?) -> Void

    init(completion: @escaping (AreaSelection?) -> Void) {
        self.completion = completion
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let frame = screen.frame
            let window = KeyableWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = SelectionView(frame: CGRect(origin: .zero, size: frame.size))
            view.onSelect = { [weak self] rect in
                // The view's origin is bottom-left; capture wants top-left
                let flipped = CGRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
                self?.finish(AreaSelection(displayID: displayID, rect: flipped))
            }
            view.onCancel = { [weak self] in self?.finish(nil) }
            window.contentView = view
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        // Make the screen under the pointer key so Esc works right away
        let key = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
        key?.makeKey()
        key?.makeFirstResponder(key?.contentView)
    }

    private func finish(_ selection: AreaSelection?) {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        completion(selection)
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragStart: CGPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let selection = selection else {
            drawLabel("Drag to select an area to record · Esc to cancel", centeredIn: bounds)
            return
        }
        NSColor.clear.setFill()
        selection.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let sizeText = "\(Int(selection.width)) × \(Int(selection.height))"
        let labelRect = CGRect(x: selection.minX, y: max(0, selection.minY - 26), width: 120, height: 22)
        drawLabel(sizeText, centeredIn: labelRect)
    }

    private func drawLabel(_ text: String, centeredIn rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let background = CGRect(x: rect.midX - size.width / 2 - 8, y: rect.midY - size.height / 2 - 4,
                                width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: background, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: background.minX + 8, y: background.minY + 4))
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                           width: abs(point.x - start.x), height: abs(point.y - start.y))
            .intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let selection = selection?.integral,
              selection.width >= Constants.Recording.minAreaSize,
              selection.height >= Constants.Recording.minAreaSize else {
            // Too small to be deliberate; let the user try again
            self.selection = nil
            needsDisplay = true
            return
        }
        onSelect?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }
}
