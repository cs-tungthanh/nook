import SwiftUI
import AppKit
import UserNotifications

// MARK: - Constants

private enum Constants {
    enum UI {
        static let popoverWidth: CGFloat = 320
    }

    enum Break {
        static let defaultIntervalMinutes = 20
        static let defaultDurationSeconds = 120
        static let durationOptions = [120, 300, 600, 1200]
        static let minIntervalMinutes = 1
        static let maxIntervalMinutes = 180
        static let snoozeMinutes = 5
        static let notificationID = "break-reminder"
        static let categoryID = "BREAK_REMINDER"

        enum Action {
            static let start = "BREAK_START"
            static let snooze = "BREAK_SNOOZE"
            static let skip = "BREAK_SKIP"
        }

        enum Keys {
            static let enabled = "breakReminder.enabled"
            static let intervalMinutes = "breakReminder.intervalMinutes"
            static let durationSeconds = "breakReminder.durationSeconds"
            static let mode = "breakReminder.mode"
        }
    }

    enum Highlight {
        static let fixedHeight: CGFloat = 24
        static let cornerRadius: CGFloat = 5
        static let borderWidth: CGFloat = 0.5
        static let darkModeBackgroundAlpha: CGFloat = 0.08
        static let darkModeBorderAlpha: CGFloat = 0.15
        static let lightModeBackgroundAlpha: CGFloat = 0.06
        static let lightModeBorderAlpha: CGFloat = 0.12
    }

    enum Time {
        static let secondsPerMinute = 60
        static let secondsPerHour = 3600
        static let updateInterval: TimeInterval = 1.0
    }

    enum Shutdown {
        static let defaultMinutes = 30
        static let presetMinutes = [30, 40, 60]
        static let minMinutes = 1
        static let maxMinutes = 600
    }

    enum Stepper {
        static let step = 5
    }
}

// MARK: - Time Formatting Helper

private struct TimeRemaining {
    let hours: Int
    let minutes: Int
    let seconds: Int

    init(from timeInterval: TimeInterval) {
        let totalSeconds = Int(timeInterval)
        hours = totalSeconds / Constants.Time.secondsPerHour
        minutes = (totalSeconds % Constants.Time.secondsPerHour) / Constants.Time.secondsPerMinute
        seconds = totalSeconds % Constants.Time.secondsPerMinute
    }

    var longFormat: String {
        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    var clockFormat: String {
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Notifications

private enum Notifier {
    static func post(title: String, body: String, identifier: String = UUID().uuidString, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category = category {
            content.categoryIdentifier = category
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Nook: failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    static func registerBreakCategory() {
        let actions = [
            UNNotificationAction(identifier: Constants.Break.Action.start, title: "Start break", options: []),
            UNNotificationAction(identifier: Constants.Break.Action.snooze, title: "Snooze \(Constants.Break.snoozeMinutes)m", options: []),
            UNNotificationAction(identifier: Constants.Break.Action.skip, title: "Skip", options: [])
        ]
        let category = UNNotificationCategory(identifier: Constants.Break.categoryID, actions: actions, intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

// MARK: - Break Reminder

enum BreakMode: String, CaseIterable, Identifiable {
    case notification
    case overlay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notification: return "Notification"
        case .overlay: return "Full screen"
        }
    }
}

final class BreakReminder: ObservableObject {
    enum Phase: Equatable {
        case off
        case working(nextBreak: Date)
        case onBreak(endsAt: Date, duration: TimeInterval)
        case paused
    }

    @Published private(set) var phase: Phase = .off {
        didSet { onChange?() }
    }

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Constants.Break.Keys.enabled)
            isEnabled ? startCycle() : stop()
        }
    }

    @Published var intervalMinutes: Int {
        didSet {
            defaults.set(intervalMinutes, forKey: Constants.Break.Keys.intervalMinutes)
            if case .working = phase { startCycle() }
        }
    }

    @Published var durationSeconds: Int {
        didSet { defaults.set(durationSeconds, forKey: Constants.Break.Keys.durationSeconds) }
    }

    @Published var mode: BreakMode {
        didSet { defaults.set(mode.rawValue, forKey: Constants.Break.Keys.mode) }
    }

    /// Called on every phase change so the menu bar can refresh.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let overlay = BreakOverlayController()
    private var tickTimer: Timer?
    private var pauseReasons: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    init() {
        defaults.register(defaults: [
            Constants.Break.Keys.enabled: false,
            Constants.Break.Keys.intervalMinutes: Constants.Break.defaultIntervalMinutes,
            Constants.Break.Keys.durationSeconds: Constants.Break.defaultDurationSeconds,
            Constants.Break.Keys.mode: BreakMode.notification.rawValue
        ])
        isEnabled = defaults.bool(forKey: Constants.Break.Keys.enabled)
        intervalMinutes = defaults.integer(forKey: Constants.Break.Keys.intervalMinutes)
        let storedDuration = defaults.integer(forKey: Constants.Break.Keys.durationSeconds)
        durationSeconds = Constants.Break.durationOptions.contains(storedDuration)
            ? storedDuration
            : Constants.Break.defaultDurationSeconds
        mode = BreakMode(rawValue: defaults.string(forKey: Constants.Break.Keys.mode) ?? "") ?? .notification

        observeSystemEvents()
        if isEnabled { startCycle() }
    }

    var breakTimeRemaining: TimeInterval? {
        guard case .onBreak(let endsAt, _) = phase else { return nil }
        return max(0, endsAt.timeIntervalSinceNow)
    }

    var breakProgress: Double {
        guard case .onBreak(let endsAt, let duration) = phase, duration > 0 else { return 0 }
        return max(0, min(1, endsAt.timeIntervalSinceNow / duration))
    }

    static func durationText(_ seconds: Int) -> String {
        if seconds >= Constants.Time.secondsPerHour {
            let hours = seconds / Constants.Time.secondsPerHour
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return seconds < Constants.Time.secondsPerMinute
            ? "\(seconds) sec"
            : "\(seconds / Constants.Time.secondsPerMinute) min"
    }

    // MARK: Actions

    func startBreak() {
        guard isEnabled else { return }
        let duration = TimeInterval(durationSeconds)
        phase = .onBreak(endsAt: Date().addingTimeInterval(duration), duration: duration)
        if mode == .overlay {
            overlay.show(reminder: self)
        }
    }

    func skipBreak() {
        overlay.hide()
        startCycle()
    }

    func snooze() {
        overlay.hide()
        let snoozeInterval = TimeInterval(Constants.Break.snoozeMinutes * Constants.Time.secondsPerMinute)
        phase = .working(nextBreak: Date().addingTimeInterval(snoozeInterval))
    }

    // MARK: Cycle

    private func startCycle() {
        guard isEnabled else { return }
        startTicking()
        guard pauseReasons.isEmpty else {
            phase = .paused
            return
        }
        let interval = TimeInterval(intervalMinutes * Constants.Time.secondsPerMinute)
        phase = .working(nextBreak: Date().addingTimeInterval(interval))
    }

    private func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        overlay.hide()
        phase = .off
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Constants.Break.notificationID])
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: Constants.Time.updateInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        let now = Date()
        switch phase {
        case .working(let nextBreak) where now >= nextBreak:
            breakDue()
        case .onBreak(let endsAt, _) where now >= endsAt:
            finishBreak()
        default:
            break
        }
    }

    private func breakDue() {
        switch mode {
        case .notification:
            Notifier.post(
                title: "Break time ☕",
                body: "Let's relax for \(Self.durationText(durationSeconds)) — look away, stretch, breathe.",
                identifier: Constants.Break.notificationID,
                category: Constants.Break.categoryID
            )
            // Start the next cycle right away so ignored reminders don't pile up
            startCycle()
        case .overlay:
            startBreak()
        }
    }

    private func finishBreak() {
        if mode == .notification {
            Notifier.post(title: "Break over", body: "Welcome back! Next break in \(intervalMinutes) min.")
        } else {
            NSSound(named: "Glass")?.play()
        }
        overlay.hide()
        startCycle()
    }

    // MARK: Sleep & Lock

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, String, Bool)] = [
            (workspace, NSWorkspace.willSleepNotification, "sleep", true),
            (workspace, NSWorkspace.didWakeNotification, "sleep", false),
            (workspace, NSWorkspace.screensDidSleepNotification, "display", true),
            (workspace, NSWorkspace.screensDidWakeNotification, "display", false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), "lock", true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), "lock", false)
        ]

        observers = events.map { center, name, reason, isPausing in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                isPausing ? self?.pause(reason) : self?.resume(reason)
            }
        }
    }

    private func pause(_ reason: String) {
        pauseReasons.insert(reason)
        guard isEnabled else { return }
        overlay.hide()
        phase = .paused
    }

    private func resume(_ reason: String) {
        pauseReasons.remove(reason)
        guard isEnabled, pauseReasons.isEmpty, phase == .paused else { return }
        startCycle()
    }
}

// MARK: - Break Overlay

private final class BreakOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class BreakOverlayController {
    private var windows: [NSWindow] = []

    func show(reminder: BreakReminder) {
        hide()
        windows = NSScreen.screens.map { screen in
            let window = BreakOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // Floating level keeps the menu bar and Dock visible above the overlay
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BreakOverlayView(reminder: reminder))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.screen == NSScreen.main } ?? windows.first)?.makeKey()
    }

    func hide() {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        // Hand focus back to the app that was active before the break
        NSApp.hide(nil)
    }
}

// MARK: - Nook Glyph

/// Nook's mark: an arched alcove with a dot inside. Drawn as a template image
/// so the menu bar tints it for light and dark appearances.
private enum NookGlyph {
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
private enum StatusIcon {
    static let onBreak = symbol("cup.and.saucer.fill", description: "On Break")
    static let shutdown = symbol("power.circle.fill", description: "Shutdown Scheduled")

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

// MARK: - App Entry Point

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var timer: Timer?
    @Published var shutdownDate: Date?
    var highlightView: NSView?
    let breakReminder = BreakReminder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNotificationPermissions()
        setupStatusBar()
        setupPopover()
        breakReminder.onChange = { [weak self] in
            self?.updateStatusItem()
        }
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerBreakCategory()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("Nook: notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                NSLog("Nook: notifications not allowed — enable them in System Settings › Notifications")
            }
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.image = NookGlyph.image
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self

        // Let the popover follow the SwiftUI height as the break reminder card expands
        let hostingController = NSHostingController(rootView: ContentView(appDelegate: self, breakReminder: breakReminder))
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        // Build and lay out the SwiftUI tree now so the first click doesn't pay for it
        _ = hostingController.view.fittingSize
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
                removeHighlight()
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                addHighlight()
            }
        }
    }

    private func addHighlight() {
        guard let button = statusItem.button else { return }
        removeHighlight()

        // Span the button's width so the highlight matches the icon-only item
        let width = button.bounds.width
        let height = min(Constants.Highlight.fixedHeight, button.bounds.height)
        let x = (button.bounds.width - width) / 2
        let y = (button.bounds.height - height) / 2

        let highlight = NSView(frame: NSRect(x: x, y: y, width: width, height: height))
        highlight.wantsLayer = true
        // Follow the button if its size changes while the popover is open
        highlight.autoresizingMask = [.width, .minYMargin, .maxYMargin]

        configureHighlightLayer(highlight.layer)

        button.addSubview(highlight, positioned: .below, relativeTo: button.subviews.first)
        highlightView = highlight
        button.layoutSubtreeIfNeeded()
    }

    private func configureHighlightLayer(_ layer: CALayer?) {
        guard let layer = layer else { return }

        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let backgroundColor = isDarkMode
            ? NSColor.white.withAlphaComponent(Constants.Highlight.darkModeBackgroundAlpha)
            : NSColor.black.withAlphaComponent(Constants.Highlight.lightModeBackgroundAlpha)
        let borderColor = isDarkMode
            ? NSColor.white.withAlphaComponent(Constants.Highlight.darkModeBorderAlpha)
            : NSColor.black.withAlphaComponent(Constants.Highlight.lightModeBorderAlpha)

        layer.backgroundColor = backgroundColor.cgColor
        layer.borderColor = borderColor.cgColor
        layer.cornerRadius = Constants.Highlight.cornerRadius
        layer.borderWidth = Constants.Highlight.borderWidth
    }

    private func removeHighlight() {
        highlightView?.removeFromSuperview()
        highlightView = nil
    }

    func scheduleShutdown(at date: Date) {
        shutdownDate = date
        cancelExistingTimers()
        startShutdownTimer(for: date)
        updateStatusItem()
        showNotification(title: "Shutdown Scheduled", body: "Your Mac will shut down at \(formatDate(date))")
    }

    private func cancelExistingTimers() {
        timer?.invalidate()
    }

    private func startShutdownTimer(for date: Date) {
        timer = Timer(fireAt: date, interval: 0, target: self, selector: #selector(executeShutdown), userInfo: nil, repeats: false)
        RunLoop.main.add(timer!, forMode: .common)
    }

    func cancelShutdown() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
            self?.shutdownDate = nil
            self?.updateStatusItem()
            self?.showNotification(title: "Shutdown Cancelled", body: "The scheduled shutdown has been cancelled")
        }
    }

    private func showNotification(title: String, body: String) {
        Notifier.post(title: title, body: body)
    }

    @objc func executeShutdown() {
        let script = """
        tell application "System Events"
            shut down
        end tell
        """

        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)

            if let error = error {
                print("Error executing shutdown: \(error)")
            }
        }
    }

    func updateStatusItem() {
        // Icon only, so the item stays the same size as other menu bar icons;
        // the countdowns live in the popover
        guard let button = statusItem.button else { return }
        let image: NSImage?
        if breakReminder.breakTimeRemaining != nil {
            // Break state takes priority while a break is running
            image = StatusIcon.onBreak
        } else if shutdownDate != nil {
            image = StatusIcon.shutdown
        } else {
            image = NookGlyph.image
        }
        if button.image !== image {
            button.image = image
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    func formatDate(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }
}

// MARK: - NSPopoverDelegate
extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        // Remove highlight when popover closes
        DispatchQueue.main.async { [weak self] in
            self?.removeHighlight()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let breakReminder = self?.breakReminder else { return }
            switch action {
            case Constants.Break.Action.start:
                breakReminder.startBreak()
            case Constants.Break.Action.snooze:
                breakReminder.snooze()
            case Constants.Break.Action.skip:
                breakReminder.skipBreak()
            default:
                break
            }
        }
        completionHandler()
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var breakReminder: BreakReminder
    @State private var shutdownMinutes = Constants.Shutdown.defaultMinutes

    var body: some View {
        VStack(spacing: 0) {
            headerView
            powerOffView
            Divider()
            breakReminderView
            Divider()
            footerView
        }
        .frame(width: Constants.UI.popoverWidth)
    }

    private var headerView: some View {
        HStack {
            Image(nsImage: NookGlyph.image)
                .renderingMode(.template)
                .resizable()
                .frame(width: 22, height: 22)
            Text("Nook")
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.1))
    }

    private var footerView: some View {
        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            Text("Quit")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(8)
        }
        .buttonStyle(CustomPlainButtonStyle())
    }

    // MARK: Power Off

    private var powerOffView: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Power Off", systemImage: "power")
                .frame(minHeight: 20)

            if let shutdownDate = appDelegate.shutdownDate {
                TimelineView(.periodic(from: .now, by: Constants.Time.updateInterval)) { _ in
                    statusRow(
                        icon: "power.circle.fill",
                        text: shutdownCountdownText(until: shutdownDate),
                        actionTitle: "Cancel",
                        action: appDelegate.cancelShutdown
                    )
                }
            } else {
                settingRow("After") {
                    minuteStepper($shutdownMinutes, in: Constants.Shutdown.minMinutes...Constants.Shutdown.maxMinutes)
                }

                settingRow("Quick") {
                    Picker("", selection: $shutdownMinutes) {
                        ForEach(Constants.Shutdown.presetMinutes, id: \.self) { minutes in
                            Text(shortDurationText(minutes * Constants.Time.secondsPerMinute)).tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                TimelineView(.periodic(from: .now, by: Constants.Time.updateInterval)) { _ in
                    statusRow(
                        icon: "clock",
                        text: "Shuts down at \(appDelegate.formatDate(Date().addingTimeInterval(TimeInterval(shutdownMinutes * Constants.Time.secondsPerMinute))))",
                        actionTitle: "Start",
                        action: { scheduleShutdown(minutes: shutdownMinutes) }
                    )
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private func shutdownCountdownText(until date: Date) -> String {
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "Shutting down…" }
        return "Shutting down in \(TimeRemaining(from: remaining).longFormat)"
    }

    // MARK: Break Reminder

    private var breakReminderView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $breakReminder.isEnabled) {
                sectionLabel("Break Reminders", systemImage: "cup.and.saucer.fill")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if breakReminder.isEnabled {
                settingRow("Every") {
                    minuteStepper($breakReminder.intervalMinutes, in: Constants.Break.minIntervalMinutes...Constants.Break.maxIntervalMinutes)
                }

                settingRow("Relax") {
                    Picker("", selection: $breakReminder.durationSeconds) {
                        ForEach(Constants.Break.durationOptions, id: \.self) { seconds in
                            Text(shortDurationText(seconds)).tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                settingRow("Style") {
                    Picker("", selection: $breakReminder.mode) {
                        ForEach(BreakMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Only the countdown row redraws each second, not the whole popover
                TimelineView(.periodic(from: .now, by: Constants.Time.updateInterval)) { _ in
                    breakStatusView
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var breakStatusView: some View {
        switch breakReminder.phase {
        case .working(let nextBreak):
            statusRow(
                icon: "timer",
                text: "Next break in \(TimeRemaining(from: max(0, nextBreak.timeIntervalSinceNow)).longFormat)",
                actionTitle: "Break now",
                action: breakReminder.startBreak
            )
        case .onBreak:
            statusRow(
                icon: "cup.and.saucer.fill",
                text: "On break · \(TimeRemaining(from: breakReminder.breakTimeRemaining ?? 0).clockFormat) left",
                actionTitle: "End break",
                action: breakReminder.skipBreak
            )
        case .paused:
            statusRow(icon: "pause.circle", text: "Paused while your Mac is locked or asleep")
        case .off:
            EmptyView()
        }
    }

    // MARK: Shared Rows

    private func sectionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            content()
        }
    }

    /// Steps by 1 below `Constants.Stepper.step` minutes and by that step above it.
    private func minuteStepper(_ value: Binding<Int>, in range: ClosedRange<Int>) -> some View {
        let step = Constants.Stepper.step
        return Group {
            Button(action: {
                let current = value.wrappedValue
                value.wrappedValue = max(range.lowerBound, current - (current > step ? step : 1))
            }) {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(IconButtonStyle())

            Text("\(value.wrappedValue) min")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .frame(minWidth: 60)

            Button(action: {
                let current = value.wrappedValue
                value.wrappedValue = min(range.upperBound, current + (current >= step ? step : 1))
            }) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(IconButtonStyle())

            Spacer()
        }
    }

    private func statusRow(icon: String, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .monospacedDigit()
            Spacer()
            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    Text(actionTitle)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(CustomPlainButtonStyle())
                .cornerRadius(5)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(8)
    }

    private func shortDurationText(_ seconds: Int) -> String {
        if seconds >= Constants.Time.secondsPerHour {
            return "\(seconds / Constants.Time.secondsPerHour)h"
        }
        return seconds < Constants.Time.secondsPerMinute
            ? "\(seconds)s"
            : "\(seconds / Constants.Time.secondsPerMinute)m"
    }

    private func scheduleShutdown(minutes: Int) {
        let shutdownDate = Date().addingTimeInterval(TimeInterval(minutes * Constants.Time.secondsPerMinute))
        appDelegate.scheduleShutdown(at: shutdownDate)
    }
}

// MARK: - Custom Button Styles with Hover Effects

struct PrimaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(isHovered ? 0.15 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

struct IconButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.secondary.opacity(isHovered ? 0.15 : 0))
                    .padding(-6)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

struct CustomPlainButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.secondary.opacity(isHovered ? 0.1 : 0)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Components

struct BreakOverlayView: View {
    @ObservedObject var reminder: BreakReminder

    var body: some View {
        ZStack {
            VisualEffectBackground()
            Color.black.opacity(0.25)

            VStack(spacing: 28) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 56))

                VStack(spacing: 8) {
                    Text("Break Time")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Let's relax — look away from the screen, stretch, breathe.")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.8))
                }

                TimelineView(.periodic(from: .now, by: Constants.Time.updateInterval)) { _ in
                    countdownRing
                }

                HStack(spacing: 12) {
                    overlayButton("Snooze \(Constants.Break.snoozeMinutes)m", systemImage: "moon.zzz.fill", action: reminder.snooze)
                    overlayButton("Skip Break", systemImage: "forward.fill", action: reminder.skipBreak)
                        .keyboardShortcut(.cancelAction)
                }

                Text("Press Esc to skip")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            .foregroundColor(.white)
        }
    }

    private var countdownRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 8)
            Circle()
                .trim(from: 0, to: reminder.breakProgress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: Constants.Time.updateInterval), value: reminder.breakProgress)
            Text(TimeRemaining(from: reminder.breakTimeRemaining ?? 0).clockFormat)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
        }
        .frame(width: 180, height: 180)
    }

    private func overlayButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.18))
            .cornerRadius(10)
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
