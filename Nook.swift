import SwiftUI
import AppKit
import UserNotifications

// MARK: - Constants

private enum Constants {
    enum UI {
        static let statusBarWidth: CGFloat = 70
        static let popoverWidth: CGFloat = 320
        static let contentHeight: CGFloat = 270
    }

    enum Break {
        static let defaultIntervalMinutes = 20
        static let defaultDurationSeconds = 600
        static let durationOptions = [600, 1800, 3600, 7200]
        static let minIntervalMinutes = 1
        static let maxIntervalMinutes = 180
        static let intervalStep = 5
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
        static let fixedWidth: CGFloat = 64
        static let fixedHeight: CGFloat = 18
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

    enum Default {
        static let customMinutes = "20"
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

    var shortFormat: String {
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
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

    /// Called on every tick and phase change so the menu bar can refresh.
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
        objectWillChange.send()
        onChange?()
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
    var updateTimer: Timer?
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
        statusItem = NSStatusBar.system.statusItem(withLength: Constants.UI.statusBarWidth)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Nook")
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

        // Use fixed size and center within button
        let width = Constants.Highlight.fixedWidth
        let height = Constants.Highlight.fixedHeight
        let x = (button.bounds.width - width) / 2
        let y = (button.bounds.height - height) / 2

        let highlight = NSView(frame: NSRect(x: x, y: y, width: width, height: height))
        highlight.wantsLayer = true

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
        startUIUpdateTimer()
        updateStatusItem()
        showNotification(title: "Shutdown Scheduled", body: "Your Mac will shut down at \(formatDate(date))")
    }

    private func cancelExistingTimers() {
        timer?.invalidate()
        updateTimer?.invalidate()
    }

    private func startShutdownTimer(for date: Date) {
        timer = Timer(fireAt: date, interval: 0, target: self, selector: #selector(executeShutdown), userInfo: nil, repeats: false)
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func startUIUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: Constants.Time.updateInterval, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
            self?.updateStatusItem()
        }
    }

    func cancelShutdown() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
            self?.updateTimer?.invalidate()
            self?.updateTimer = nil
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
        if let button = statusItem.button {
            if let breakRemaining = breakReminder.breakTimeRemaining {
                // Break countdown takes priority while a break is running
                button.title = " \(TimeRemaining(from: breakRemaining).clockFormat)"
                button.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "On Break")
            } else if shutdownDate != nil {
                // Show countdown in menu bar when scheduled
                let shortTime = getShortTimeRemaining()
                button.title = " \(shortTime)"
                button.image = NSImage(systemSymbolName: "power.circle.fill", accessibilityDescription: "Shutdown Scheduled")
            } else {
                button.title = ""
                button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Nook")
            }
        }
    }

    func getShortTimeRemaining() -> String {
        guard let shutdownDate = shutdownDate else { return "" }
        let remaining = shutdownDate.timeIntervalSinceNow

        guard remaining > 0 else { return "Now" }
        return TimeRemaining(from: remaining).shortFormat
    }

    func getTimeRemaining() -> String? {
        guard let shutdownDate = shutdownDate else { return nil }
        let remaining = shutdownDate.timeIntervalSinceNow

        guard remaining > 0 else { return "Shutting down..." }
        return TimeRemaining(from: remaining).longFormat
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
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
    @State private var customMinutes: String = Constants.Default.customMinutes

    var body: some View {
        VStack(spacing: 0) {
            headerView
            contentView
            Divider()
            breakReminderView
            Divider()
            footerView
        }
        .frame(width: Constants.UI.popoverWidth)
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "square.grid.2x2.fill")
                .font(.title2)
            Text("Nook")
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.1))
    }

    private var contentView: some View {
        Group {
            if appDelegate.shutdownDate != nil {
                scheduledView
            } else {
                quickActionsView
            }
        }
        .frame(maxWidth: .infinity, minHeight: Constants.UI.contentHeight, maxHeight: Constants.UI.contentHeight, alignment: .top)
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

    private var scheduledView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.red)
                Text("SHUTDOWN SCHEDULED")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.15))
            .cornerRadius(12)

            if let timeRemaining = appDelegate.getTimeRemaining() {
                Text(timeRemaining)
                    .font(.system(.title, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
            }

            if let shutdownDate = appDelegate.shutdownDate {
                Text("Shutdown at \(appDelegate.formatDate(shutdownDate))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: {
                appDelegate.cancelShutdown()
            }) {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                    Text("Cancel Shutdown")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red)
                .cornerRadius(8)
            }
            .buttonStyle(DangerButtonStyle())
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.orange.opacity(0.15), Color.red.opacity(0.1)]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var quickActionsView: some View {
        VStack(spacing: 12) {
            Text("Power Off")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                QuickActionButton(title: "30min") {
                    scheduleQuickShutdown(minutes: 30)
                }
                QuickActionButton(title: "40min") {
                    scheduleQuickShutdown(minutes: 40)
                }
                QuickActionButton(title: "1h") {
                    scheduleQuickShutdown(minutes: 60)
                }
            }

            Divider()
                .padding(.vertical, 4)

            Text("Custom")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                // Decrement button
                Button(action: {
                    if let current = Int(customMinutes), current > 1 {
                        customMinutes = String(current - 1)
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(IconButtonStyle())

                // Minutes display
                VStack(spacing: 2) {
                    TextField("", text: $customMinutes)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text("minutes")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Increment button
                Button(action: {
                    if let current = Int(customMinutes) {
                        customMinutes = String(current + 1)
                    }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(IconButtonStyle())
            }

            // Big trigger button
            Button(action: {
                if let minutes = Int(customMinutes), minutes > 0 {
                    scheduleQuickShutdown(minutes: minutes)
                }
            }) {
                HStack {
                    Image(systemName: "power")
                    Text("Start Shutdown Timer")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.accentColor.opacity(0.8), Color.accentColor]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.bottom, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.accentColor.opacity(0.05))
    }

    // MARK: Break Reminder

    private var breakReminderView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $breakReminder.isEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "cup.and.saucer.fill")
                        .foregroundColor(.accentColor)
                    Text("Break Reminders")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if breakReminder.isEnabled {
                breakSettingRow("Every") {
                    Button(action: decrementInterval) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(IconButtonStyle())

                    Text("\(breakReminder.intervalMinutes) min")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(minWidth: 60)

                    Button(action: incrementInterval) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(IconButtonStyle())

                    Spacer()
                }

                breakSettingRow("Relax") {
                    Picker("", selection: $breakReminder.durationSeconds) {
                        ForEach(Constants.Break.durationOptions, id: \.self) { seconds in
                            Text(shortDurationText(seconds)).tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                breakSettingRow("Style") {
                    Picker("", selection: $breakReminder.mode) {
                        ForEach(BreakMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                breakStatusView
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private func breakSettingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            content()
        }
    }

    @ViewBuilder
    private var breakStatusView: some View {
        switch breakReminder.phase {
        case .working(let nextBreak):
            breakStatusRow(
                icon: "timer",
                text: "Next break in \(TimeRemaining(from: max(0, nextBreak.timeIntervalSinceNow)).longFormat)",
                actionTitle: "Break now",
                action: breakReminder.startBreak
            )
        case .onBreak:
            breakStatusRow(
                icon: "cup.and.saucer.fill",
                text: "On break · \(TimeRemaining(from: breakReminder.breakTimeRemaining ?? 0).clockFormat) left",
                actionTitle: "End break",
                action: breakReminder.skipBreak
            )
        case .paused:
            breakStatusRow(icon: "pause.circle", text: "Paused while your Mac is locked or asleep")
        case .off:
            EmptyView()
        }
    }

    private func breakStatusRow(icon: String, text: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
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

    private func decrementInterval() {
        let current = breakReminder.intervalMinutes
        let step = current > Constants.Break.intervalStep ? Constants.Break.intervalStep : 1
        breakReminder.intervalMinutes = max(Constants.Break.minIntervalMinutes, current - step)
    }

    private func incrementInterval() {
        let current = breakReminder.intervalMinutes
        let step = current >= Constants.Break.intervalStep ? Constants.Break.intervalStep : 1
        breakReminder.intervalMinutes = min(Constants.Break.maxIntervalMinutes, current + step)
    }

    private func scheduleQuickShutdown(minutes: Int) {
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

struct DangerButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(
                RoundedRectangle(cornerRadius: 8)
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

                countdownRing

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

struct QuickActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.title2)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0.8)]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .foregroundColor(.white)
            .cornerRadius(10)
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}
