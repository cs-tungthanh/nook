import SwiftUI
import AppKit
import UserNotifications

@main
struct PowerOffTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var timer: Timer?
    @Published var shutdownDate: Date?
    var updateTimer: Timer?
    var highlightView: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Create the status item with fixed width to prevent position shifts
        statusItem = NSStatusBar.system.statusItem(withLength: 70)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Power Off Timer")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create the popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 380)
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

    func addHighlight() {
        guard let button = statusItem.button else { return }

        // Remove existing highlight if any
        removeHighlight()

        // Create a subtle background view that matches native macOS style
        // Use full bounds with smaller insets to accommodate text
        let highlight = NSView(frame: button.bounds.insetBy(dx: 3, dy: 3))
        highlight.wantsLayer = true

        if let layer = highlight.layer {
            // Use a subtle white/black overlay depending on appearance
            if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                // Dark mode: subtle white overlay with border
                layer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
                layer.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
            } else {
                // Light mode: subtle black overlay with border
                layer.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
                layer.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
            }
            layer.cornerRadius = 5
            layer.borderWidth = 0.5
        }

        // Make it resize with the button
        highlight.autoresizingMask = [.width, .height]

        // Insert at the very back
        button.addSubview(highlight, positioned: .below, relativeTo: button.subviews.first)
        highlightView = highlight

        // Force layout update
        button.layoutSubtreeIfNeeded()
    }

    func removeHighlight() {
        highlightView?.removeFromSuperview()
        highlightView = nil
    }

    func scheduleShutdown(at date: Date) {
        shutdownDate = date

        // Cancel existing timer
        timer?.invalidate()

        // Schedule new timer
        timer = Timer(fireAt: date, interval: 0, target: self, selector: #selector(executeShutdown), userInfo: nil, repeats: false)
        RunLoop.main.add(timer!, forMode: .common)

        // Start UI update timer for countdown
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.objectWillChange.send()
        }

        // Update status item
        updateStatusItem()

        // Show notification
        let content = UNMutableNotificationContent()
        content.title = "Shutdown Scheduled"
        content.body = "Your Mac will shut down at \(formatDate(date))"
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelShutdown() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
            self?.updateTimer?.invalidate()
            self?.updateTimer = nil
            self?.shutdownDate = nil
            self?.updateStatusItem()

            let content = UNMutableNotificationContent()
            content.title = "Shutdown Cancelled"
            content.body = "The scheduled shutdown has been cancelled"
            content.sound = .default

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
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

        if remaining <= 0 {
            return "Now"
        }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    func getTimeRemaining() -> String? {
        guard let shutdownDate = shutdownDate else { return nil }
        let remaining = shutdownDate.timeIntervalSinceNow

        if remaining <= 0 {
            return "Shutting down..."
        }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        let seconds = Int(remaining) % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

// MARK: - NSPopoverDelegate
extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        // Remove highlight when popover closes
        removeHighlight()
    }
}

struct ContentView: View {
    @ObservedObject var appDelegate: AppDelegate
    @State private var customMinutes: String = "20"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "power")
                    .font(.title2)
                Text("Power Off Timer")
                    .font(.headline)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.1))

            // Main content area with consistent frame
            Group {
                if appDelegate.shutdownDate != nil {
                    scheduledView
                } else {
                    quickActionsView
                }
            }
            .frame(maxWidth: .infinity, minHeight: 270, maxHeight: 270, alignment: .top)

            Divider()

            // Footer
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("Quit")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(8)
        }
    }

    var scheduledView: some View {
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

            Text("Shutdown at \(appDelegate.formatDate(appDelegate.shutdownDate!))")
                .font(.subheadline)
                .foregroundColor(.secondary)

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

    var quickActionsView: some View {
        VStack(spacing: 12) {
            Text("Quick Actions")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                QuickActionButton(title: "30min", minutes: 30) {
                    scheduleQuickShutdown(minutes: 30)
                }
                QuickActionButton(title: "40min", minutes: 40) {
                    scheduleQuickShutdown(minutes: 40)
                }
                QuickActionButton(title: "1h", minutes: 60) {
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

    func scheduleQuickShutdown(minutes: Int) {
        let shutdownDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
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

struct PlainButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(isHovered ? 0.1 : 0))
                    .padding(-6)
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
    let minutes: Int
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
