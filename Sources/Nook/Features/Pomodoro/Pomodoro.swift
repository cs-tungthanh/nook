import AppKit
import Combine
import UserNotifications

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

/// The Custom choice of a setting that also has presets, like Break's
/// 2m · 5m · 10m · Custom. `isSelected` keeps Custom picked even when its
/// value happens to equal a preset, so stepping through 5m doesn't jump.
struct CustomValue: Equatable {
    var isSelected: Bool
    var value: Int

    /// Loads the saved custom choice. A saved `current` that isn't a preset
    /// (from before the setting had presets) becomes the custom value.
    static func load(forKey key: String, current: Int, presets: [Int], defaultValue: Int) -> CustomValue {
        let defaults = UserDefaults.standard
        if current != 0 && !presets.contains(current) {
            return CustomValue(isSelected: true, value: current)
        }
        return CustomValue(isSelected: defaults.bool(forKey: key + ".isSelected"),
                           value: defaults.object(forKey: key + ".value") as? Int ?? defaultValue)
    }

    func save(forKey key: String) {
        UserDefaults.standard.set(isSelected, forKey: key + ".isSelected")
        UserDefaults.standard.set(value, forKey: key + ".value")
    }
}

final class Pomodoro: ObservableObject {
    enum Phase: Equatable {
        case off
        case focusing(endsAt: Date, duration: TimeInterval)
        case onBreak(endsAt: Date, duration: TimeInterval)
        case paused
    }

    /// Time left in the current focus or break, nil when neither is running.
    var timeRemaining: TimeInterval? {
        switch phase {
        case .focusing(let endsAt, _), .onBreak(let endsAt, _):
            return max(0, endsAt.timeIntervalSinceNow)
        case .off, .paused:
            return nil
        }
    }

    /// Share of the current focus or break still left, from 1 down to 0.
    var progress: Double {
        switch phase {
        case .focusing(let endsAt, let duration), .onBreak(let endsAt, let duration):
            guard duration > 0 else { return 0 }
            return max(0, min(1, endsAt.timeIntervalSinceNow / duration))
        case .off, .paused:
            return 0
        }
    }

    @Published private(set) var phase: Phase = .off {
        didSet { onChange?() }
    }

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Constants.Pomodoro.Keys.enabled)
            isEnabled ? startCycle() : stop()
        }
    }

    @Published var intervalMinutes: Int {
        didSet {
            defaults.set(intervalMinutes, forKey: Constants.Pomodoro.Keys.intervalMinutes)
            // Keep the time already focused: 15 min into 20, changing to 25 leaves 10
            let change = TimeInterval((intervalMinutes - oldValue) * Constants.Time.secondsPerMinute)
            if case .focusing(let endsAt, let duration) = phase {
                phase = .focusing(endsAt: endsAt.addingTimeInterval(change), duration: duration + change)
            } else if let held = heldPhase, !held.isBreak {
                heldPhase = HeldPhase(isBreak: false, remaining: max(0, held.remaining + change),
                                      duration: held.duration + change, pausedAt: held.pausedAt)
            }
        }
    }

    @Published var durationSeconds: Int {
        didSet { defaults.set(durationSeconds, forKey: Constants.Pomodoro.Keys.durationSeconds) }
    }

    /// Focus's Custom choice; while it's picked, `intervalMinutes` follows it
    @Published var customInterval: CustomValue {
        didSet {
            customInterval.save(forKey: Constants.Pomodoro.Keys.customInterval)
            if customInterval.isSelected { intervalMinutes = customInterval.value }
        }
    }

    /// Break's Custom choice, in seconds; while it's picked, `durationSeconds` follows it
    @Published var customDuration: CustomValue {
        didSet {
            customDuration.save(forKey: Constants.Pomodoro.Keys.customDuration)
            if customDuration.isSelected { durationSeconds = customDuration.value }
        }
    }

    @Published var mode: BreakMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Constants.Pomodoro.Keys.mode)
            if mode == .notification {
                Notifier.requestAuthorizationIfNeeded { [weak self] in self?.refreshNotificationPermission() }
            }
        }
    }

    /// Whether macOS shows Nook's notifications. Without them a Notification-style
    /// break passes unseen, so the tile says what's missing. Assumed allowed until
    /// read, so the tile doesn't flash a warning.
    @Published private(set) var notificationsAllowed = true

    /// Re-reads the notification permission; cheap, and done at the start of
    /// every focus and whenever the island opens
    func refreshNotificationPermission() {
        Notifier.checkAllowed { [weak self] allowed in
            guard let self = self, self.notificationsAllowed != allowed else { return }
            self.notificationsAllowed = allowed
        }
    }

    /// Called on every phase change so the menu bar can refresh.
    var onChange: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let overlay = BreakOverlayController()
    private var tickTimer: Timer?
    private var pauseReasons: Set<String> = []
    /// The focus or break a pause interrupted, so resuming picks it up where it stopped
    private var heldPhase: HeldPhase?

    private struct HeldPhase {
        let isBreak: Bool
        let remaining: TimeInterval
        let duration: TimeInterval
        let pausedAt: Date
    }
    private var observers: [NSObjectProtocol] = []

    init() {
        defaults.register(defaults: [
            Constants.Pomodoro.Keys.enabled: false,
            Constants.Pomodoro.Keys.intervalMinutes: Constants.Pomodoro.defaultIntervalMinutes,
            Constants.Pomodoro.Keys.durationSeconds: Constants.Pomodoro.defaultDurationSeconds,
            Constants.Pomodoro.Keys.mode: BreakMode.notification.rawValue
        ])
        isEnabled = defaults.bool(forKey: Constants.Pomodoro.Keys.enabled)
        let storedInterval = defaults.integer(forKey: Constants.Pomodoro.Keys.intervalMinutes)
        intervalMinutes = storedInterval
        let storedDuration = defaults.integer(forKey: Constants.Pomodoro.Keys.durationSeconds)
        let duration = (Constants.Pomodoro.minDurationSeconds...Constants.Pomodoro.maxDurationSeconds).contains(storedDuration)
            ? storedDuration
            : Constants.Pomodoro.defaultDurationSeconds
        durationSeconds = duration
        customInterval = .load(forKey: Constants.Pomodoro.Keys.customInterval, current: storedInterval,
                               presets: Constants.Pomodoro.intervalOptions, defaultValue: 30)
        customDuration = .load(forKey: Constants.Pomodoro.Keys.customDuration, current: duration,
                               presets: Constants.Pomodoro.durationOptions, defaultValue: 15 * Constants.Time.secondsPerMinute)
        mode = BreakMode(rawValue: defaults.string(forKey: Constants.Pomodoro.Keys.mode) ?? "") ?? .notification

        observeSystemEvents()
        if isEnabled { startCycle() }
    }

    var isOnBreak: Bool {
        if case .onBreak = phase { return true }
        return false
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
            overlay.show(pomodoro: self)
        }
    }

    func skipBreak() {
        overlay.hide()
        startCycle()
    }

    /// Pushes the coming break back by the snooze time, keeping the focus so far
    func postponeBreak() {
        guard case .focusing(let endsAt, let duration) = phase else { return }
        let snoozeInterval = TimeInterval(Constants.Pomodoro.snoozeMinutes * Constants.Time.secondsPerMinute)
        phase = .focusing(endsAt: endsAt.addingTimeInterval(snoozeInterval), duration: duration + snoozeInterval)
    }

    func snooze() {
        let snoozeInterval = TimeInterval(Constants.Pomodoro.snoozeMinutes * Constants.Time.secondsPerMinute)
        overlay.hide()
        phase = .focusing(endsAt: Date().addingTimeInterval(snoozeInterval), duration: snoozeInterval)
    }

    // MARK: Cycle

    private func startCycle() {
        heldPhase = nil
        guard isEnabled else { return }
        refreshNotificationPermission()
        startTicking()
        guard pauseReasons.isEmpty else {
            phase = .paused
            return
        }
        let interval = TimeInterval(intervalMinutes * Constants.Time.secondsPerMinute)
        phase = .focusing(endsAt: Date().addingTimeInterval(interval), duration: interval)
    }

    private func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        overlay.hide()
        phase = .off
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Constants.Pomodoro.notificationID])
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
        case .focusing(let endsAt, _) where now >= endsAt:
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
                title: "Break time 🍅",
                body: "Let's relax for \(Self.durationText(durationSeconds)) — look away, stretch, breathe.",
                identifier: Constants.Pomodoro.notificationID,
                category: Constants.Pomodoro.categoryID
            )
            // Start the next cycle right away so ignored reminders don't pile up
            startCycle()
        case .overlay:
            startBreak()
        }
    }

    private func finishBreak() {
        if mode == .notification {
            Notifier.post(title: "Break over", body: "Back to focus. Next break in \(intervalMinutes) min.")
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
        switch phase {
        case .focusing(let endsAt, let duration):
            heldPhase = HeldPhase(isBreak: false, remaining: max(0, endsAt.timeIntervalSinceNow),
                                  duration: duration, pausedAt: Date())
        case .onBreak(let endsAt, let duration):
            heldPhase = HeldPhase(isBreak: true, remaining: max(0, endsAt.timeIntervalSinceNow),
                                  duration: duration, pausedAt: Date())
        case .off, .paused:
            break
        }
        overlay.hide()
        phase = .paused
    }

    private func resume(_ reason: String) {
        pauseReasons.remove(reason)
        guard isEnabled, pauseReasons.isEmpty, phase == .paused else { return }
        guard let held = heldPhase else {
            startCycle()
            return
        }
        heldPhase = nil
        let endsAt = Date().addingTimeInterval(held.remaining)
        if held.isBreak {
            // Time away from the Mac counts as rest: a break the pause outlasted is done
            guard Date().timeIntervalSince(held.pausedAt) < held.remaining else {
                startCycle()
                return
            }
            phase = .onBreak(endsAt: endsAt, duration: held.duration)
            if mode == .overlay { overlay.show(pomodoro: self) }
        } else {
            phase = .focusing(endsAt: endsAt, duration: held.duration)
        }
    }
}
