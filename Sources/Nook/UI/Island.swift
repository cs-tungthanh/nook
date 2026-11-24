import SwiftUI
import AppKit

/// The outline of the island: flat along the top of the screen with small
/// outward flares where it meets the menu bar, like the notch, and wide
/// rounded corners at the bottom.
struct IslandShape: Shape {
    var flareRadius: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flareRadius, cornerRadius) }
        set {
            flareRadius = newValue.first
            cornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let flare = flareRadius
        let left = rect.minX + flare
        let right = rect.maxX - flare
        let corner = max(0, min(cornerRadius, rect.height / 2, (right - left) / 2))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: left, y: rect.minY + flare), control: CGPoint(x: left, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: corner)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: corner)
        path.addLine(to: CGPoint(x: right, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// What the island looks like right now: collapsed into the notch or open.
final class IslandModel: ObservableObject {
    @Published var isExpanded = false
    /// The notch (or a notch-sized slot in the menu bar) the island grows out of
    @Published var notchSize = CGSize(width: 180, height: 24)
}

/// Grows its content out of the notch: a black notch-sized pill springs open
/// to the content's size while the content fades and scales into place.
/// Clicking the empty space around it calls `onDismiss`.
struct IslandView<Content: View>: View {
    @ObservedObject var model: IslandModel
    let onDismiss: () -> Void
    let content: Content

    var body: some View {
        let expanded = model.isExpanded

        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            content
                // Keep the content below the notch, which hides whatever is under it
                .padding(.top, model.notchSize.height)
                // Leave room for the flares at the top corners
                .padding(.horizontal, Constants.Island.flareRadius)
                .fixedSize()
                .opacity(expanded ? 1 : 0)
                // No blur here: an animated blur re-renders and blurs the whole
                // content offscreen on every frame, which made opening stutter
                .scaleEffect(expanded ? 1 : 0.7, anchor: .top)
                .mask(GeometryReader { proxy in
                    islandShape(fitting: proxy.size)
                })
                .background(GeometryReader { proxy in
                    islandShape(fitting: proxy.size)
                        .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 18, y: 8)
                })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// The island in black, notch-sized while collapsed and filling `size`
    /// when open, pinned to the top center either way.
    private func islandShape(fitting size: CGSize) -> some View {
        let expanded = model.isExpanded
        let notch = model.notchSize
        let flare = expanded ? Constants.Island.flareRadius : Constants.Island.collapsedFlareRadius
        return IslandShape(
            flareRadius: flare,
            cornerRadius: expanded ? Constants.Island.cornerRadius : notch.height / 2
        )
        .fill(Color.black)
        .frame(
            width: expanded ? size.width : notch.width + 2 * flare,
            height: expanded ? size.height : notch.height
        )
        .frame(width: size.width, height: size.height, alignment: .top)
    }
}

/// Takes the first click even while the panel isn't key, so a button never
/// needs a second click after focus moved elsewhere.
private final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // Sit over the menu bar, flush with the top of the screen, like the notch
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Shows Nook's controls in a Dynamic Island–style panel that drops out of
/// the notch at the top center of the screen, and folds back into it on close.
final class IslandController {
    private let model = IslandModel()
    private let panel: IslandPanel
    private let root = NSView()
    /// Holds the hosting view; in `root` only while the island is on screen
    private let container = NSView()
    private var pendingHide: DispatchWorkItem?

    /// True from the moment the island starts opening until it starts closing
    private(set) var isShown = false

    /// Called when the user clicks the empty space around the open island
    var onDismiss: (() -> Void)?

    init<Content: View>(content: Content) {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The island draws its own shadow so it follows the shape
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hostingView = IslandHostingView(rootView: IslandView(
            model: model,
            onDismiss: { [weak self] in self?.onDismiss?() },
            content: content
        ))
        // The panel is sized by hand. As the window's own content view, the
        // hosting view would also resize the window, and the two fight until
        // AppKit throws, so wrap it in a plain view instead.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        container.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        panel.contentView = root
    }

    /// SwiftUI keeps updating a hosting view whose window is merely ordered
    /// out, so anything animating inside the content (like the Pomodoro ring,
    /// whose one-second animation restarts every second) would re-lay out the
    /// island on every frame while it's closed. A hosting view outside any
    /// window stays idle and keeps its state, so it's only attached while the
    /// island is on screen.
    private func attachContent() {
        guard container.superview == nil else { return }
        container.frame = root.bounds
        container.subviews.first?.frame = container.bounds
        root.addSubview(container)
        // Draw the collapsed island first so opening animates from the notch
        container.layoutSubtreeIfNeeded()
    }

    func show(on screen: NSScreen) {
        pendingHide?.cancel()
        pendingHide = nil
        isShown = true
        model.notchSize = Self.notchSize(of: screen)
        layoutPanel(on: screen)
        let isStillClosing = container.superview != nil
        attachContent()
        panel.orderFrontRegardless()
        panel.makeKey()

        // Reopened before it finished folding away: grow from where it is
        if isStillClosing {
            expand()
            return
        }

        // A hosting view put back in the window hasn't drawn anything yet, and
        // the close animation may not have settled before it was detached. If
        // the island expanded in this same pass, SwiftUI would never show the
        // collapsed island and would jump straight to open (every open after
        // the first). So settle on the collapsed island, draw it, and only
        // start growing on the next pass of the run loop.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.isExpanded = false
        }
        container.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isShown else { return }
            self.expand()
        }
    }

    private func expand() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            model.isExpanded = true
        }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.92)) {
            model.isExpanded = false
        }
        // Take the panel off screen once it has folded back into the notch
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.container.removeFromSuperview()
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Island.closeDuration, execute: work)
    }

    /// Spans a fixed column at the top center of the screen, wide enough for
    /// the open island and its shadow. The empty part is transparent, so the
    /// island can change height without the panel resizing mid-animation.
    private func layoutPanel(on screen: NSScreen) {
        let margin = Constants.Island.shadowMargin
        let width = Constants.UI.panelWidth + 2 * (Constants.Island.flareRadius + margin)
        let height = screen.frame.height - screen.visibleFrame.minY
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    /// The notch's size on screens that have one; otherwise a notch-sized
    /// slot as tall as the menu bar.
    private static func notchSize(of screen: NSScreen) -> CGSize {
        if #available(macOS 12.0, *),
           screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        return CGSize(width: Constants.Island.fallbackNotchWidth, height: NSStatusBar.system.thickness)
    }
}
