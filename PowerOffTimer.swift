import SwiftUI
import AppKit
import UserNotifications

// MARK: - Constants

private enum Constants {
    enum UI {
        static let statusBarWidth: CGFloat = 70
        static let popoverWidth: CGFloat = 320
        static let popoverHeight: CGFloat = 380
        static let contentHeight: CGFloat = 270
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
}

// MARK: - App Entry Point

@main
struct PowerOffTimerApp: App {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNotificationPermissions()
        setupStatusBar()
        setupPopover()
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: Constants.UI.statusBarWidth)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Power Off Timer")
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: Constants.UI.popoverWidth, height: Constants.UI.popoverHeight)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ContentView(appDelegate: self))
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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
            if shutdownDate != nil {
                // Show countdown in menu bar when scheduled
                let shortTime = getShortTimeRemaining()
                button.title = " \(shortTime)"
                button.image = NSImage(systemSymbolName: "power.circle.fill", accessibilityDescription: "Power Off Timer Active")
            } else {
                button.title = ""
                button.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Power Off Timer")
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

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var customMinutes: String = Constants.Default.customMinutes

    var body: some View {
        VStack(spacing: 0) {
            headerView
            contentView
            Divider()
            footerView
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "power")
                .font(.title2)
            Text("Power Off Timer")
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
            Text("Quick Actions")
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
