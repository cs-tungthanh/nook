import SwiftUI
import AppKit
import UserNotifications
import ScreenCaptureKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers
import IOBluetooth
import CoreBluetooth
import IOKit
import IOKit.ps
import WebKit
import AuthenticationServices
import CryptoKit

// MARK: - Constants

private enum Constants {
    enum UI {
        static let panelWidth: CGFloat = 700
        static let gridSpacing: CGFloat = 12
        static let gridPadding: CGFloat = 16
        static let tileCornerRadius: CGFloat = 16
    }

    enum Island {
        /// Outward flares where the island meets the menu bar
        static let flareRadius: CGFloat = 12
        static let collapsedFlareRadius: CGFloat = 6
        static let cornerRadius: CGFloat = 30
        /// Used on screens without a notch
        static let fallbackNotchWidth: CGFloat = 180
        /// Room around the island for its shadow
        static let shadowMargin: CGFloat = 32
        static let closeDuration: TimeInterval = 0.4
        static let escapeKeyCode: UInt16 = 53
    }

    enum Pomodoro {
        static let defaultIntervalMinutes = 20
        static let defaultDurationSeconds = 120
        static let durationOptions = [120, 300, 600, 1200]
        static let minIntervalMinutes = 1
        static let maxIntervalMinutes = 180
        static let snoozeMinutes = 5
        static let notificationID = "pomodoro-break"
        static let categoryID = "POMODORO_BREAK"

        enum Action {
            static let start = "POMODORO_START"
            static let snooze = "POMODORO_SNOOZE"
            static let skip = "POMODORO_SKIP"
        }

        /// Keys keep the old "breakReminder" names so saved settings carry over
        /// Keep the old "breakReminder" names so saved settings carry over
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
        /// The ruler offers 5 min to 2 h in 5-minute ticks, labeled every 30 min
        static let minMinutes = 5
        static let maxMinutes = 120
        static let stepMinutes = 5
        static let labelEveryMinutes = 30
        static let tint = Color(red: 1.0, green: 0.66, blue: 0.2)
    }

    enum Stepper {
        static let step = 5
    }

    enum Recording {
        static let framesPerSecond: Int32 = 60
        static let audioSampleRate = 48_000
        static let audioChannelCount = 2
        static let audioBitRate = 128_000
        /// Frames ScreenCaptureKit may hold per stream; one is kept for compositing
        static let queueDepth = 6
        /// Largest frames each encoder accepts; bigger canvases are scaled down
        static let h264MaxSize = CGSize(width: 4096, height: 2304)
        static let hevcMaxSize = CGSize(width: 8192, height: 4320)
        /// Smallest area, in points, a drag selects; shorter drags are ignored
        static let minAreaSize: CGFloat = 32
        static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

        /// Keys keep the old "breakReminder" names so saved settings carry over
        enum Keys {
            static let systemAudio = "screenRecording.systemAudio"
            static let microphone = "screenRecording.microphone"
            static let source = "screenRecording.source"
            static let display = "screenRecording.display"
        }
    }

    enum Bluetooth {
        /// Devices shown before the list collapses behind "Show all"
        static let collapsedCount = 4
        static let settingsURL = "x-apple.systempreferences:com.apple.BluetoothSettings"
        static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        /// Grace period before re-reading state after a disconnect
        static let refreshDelay: TimeInterval = 1
    }

    enum System {
        /// How often the System page re-reads its stats while it's on screen
        static let sampleInterval: TimeInterval = 1.5
        /// Usage above this turns a meter orange
        static let highUsage = 0.85
    }

    enum Music {
        static let defaultVolume = 40.0
        /// How long the old music fades out before a new station starts
        static let fadeMilliseconds = 500
        static let searchDebounce: TimeInterval = 0.3
        static let searchResultLimit = 15
        static let recentSearchLimit = 10
        /// Stations kept in "Recently Played"
        static let recentlyPlayedLimit = 15
        /// "Long" results: YouTube's own filter means over 20 minutes
        static let longMinimumSeconds = 3600
        /// A player this small starts at YouTube's lowest video quality, so it
        /// never pauses mid-song to step down. Nobody sees the video anyway.
        static let playerSize = CGSize(width: 256, height: 144)
        /// Embeds need a real https origin; a blank one is refused (errors 152/153)
        static let origin = "https://nook.local"
        /// The client version youtube.com sends to its own search API
        static let clientVersion = "2.20251120.01.00"

        enum Keys {
            static let volume = "music.volume"
            static let lastStation = "music.lastStation"
            static let customStations = "music.customStations"
            static let recentSearches = "music.recentSearches"
            static let recentlyPlayed = "music.recentlyPlayed"
        }
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

    static func registerPomodoroCategory() {
        let actions = [
            UNNotificationAction(identifier: Constants.Pomodoro.Action.start, title: "Start break", options: []),
            UNNotificationAction(identifier: Constants.Pomodoro.Action.snooze, title: "Snooze \(Constants.Pomodoro.snoozeMinutes)m", options: []),
            UNNotificationAction(identifier: Constants.Pomodoro.Action.skip, title: "Skip", options: [])
        ]
        let category = UNNotificationCategory(identifier: Constants.Pomodoro.categoryID, actions: actions, intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

// MARK: - Pomodoro

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
            if case .focusing = phase { startCycle() }
        }
    }

    @Published var durationSeconds: Int {
        didSet { defaults.set(durationSeconds, forKey: Constants.Pomodoro.Keys.durationSeconds) }
    }

    @Published var mode: BreakMode {
        didSet { defaults.set(mode.rawValue, forKey: Constants.Pomodoro.Keys.mode) }
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
            Constants.Pomodoro.Keys.enabled: false,
            Constants.Pomodoro.Keys.intervalMinutes: Constants.Pomodoro.defaultIntervalMinutes,
            Constants.Pomodoro.Keys.durationSeconds: Constants.Pomodoro.defaultDurationSeconds,
            Constants.Pomodoro.Keys.mode: BreakMode.notification.rawValue
        ])
        isEnabled = defaults.bool(forKey: Constants.Pomodoro.Keys.enabled)
        intervalMinutes = defaults.integer(forKey: Constants.Pomodoro.Keys.intervalMinutes)
        let storedDuration = defaults.integer(forKey: Constants.Pomodoro.Keys.durationSeconds)
        durationSeconds = Constants.Pomodoro.durationOptions.contains(storedDuration)
            ? storedDuration
            : Constants.Pomodoro.defaultDurationSeconds
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

    func snooze() {
        overlay.hide()
        let snoozeInterval = TimeInterval(Constants.Pomodoro.snoozeMinutes * Constants.Time.secondsPerMinute)
        phase = .focusing(endsAt: Date().addingTimeInterval(snoozeInterval), duration: snoozeInterval)
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

    func show(pomodoro: Pomodoro) {
        hide()
        windows = NSScreen.screens.map { screen in
            let window = BreakOverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            // Floating level keeps the menu bar and Dock visible above the overlay
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BreakOverlayView(pomodoro: pomodoro))
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

// MARK: - Screen Recorder

enum RecordingSource: String, CaseIterable, Identifiable {
    case screen
    case allScreens
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Screen"
        case .allScreens: return "All screens"
        case .area: return "Area"
        }
    }
}

struct DisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
}

/// An area the user dragged out, in points relative to the top-left of its display.
struct AreaSelection {
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Records one screen, every screen side by side, or a dragged-out area, with
/// optional system audio and microphone. Stop pauses the recording: the user
/// can resume into the same movie, or save it to a name and folder they pick.
/// Needs macOS 15 for microphone capture; on older systems `start()` reports an error.
final class ScreenRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case selectingArea
        case starting
        case recording
        case pausing
        case paused
        case saving
    }

    @Published private(set) var state: State = .idle {
        didSet { onChange?() }
    }

    @Published private(set) var errorMessage: String?
    /// True when the last error can be fixed in System Settings › Privacy & Security
    @Published private(set) var needsPrivacySettings = false
    /// Connected screens, left to right
    @Published private(set) var displays: [DisplayOption] = []

    @Published var source: RecordingSource {
        didSet { defaults.set(source.rawValue, forKey: Constants.Recording.Keys.source) }
    }

    @Published var selectedDisplayID: CGDirectDisplayID {
        didSet { defaults.set(Int(selectedDisplayID), forKey: Constants.Recording.Keys.display) }
    }

    @Published var capturesSystemAudio: Bool {
        didSet { defaults.set(capturesSystemAudio, forKey: Constants.Recording.Keys.systemAudio) }
    }

    @Published var capturesMicrophone: Bool {
        didSet { defaults.set(capturesMicrophone, forKey: Constants.Recording.Keys.microphone) }
    }

    /// Called on every state change so the menu bar can refresh.
    var onChange: (() -> Void)?

    private struct Capture {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    private let defaults = UserDefaults.standard
    private let sampleQueue = DispatchQueue(label: "com.nook.screen-recorder.samples")
    /// What to capture, kept so Resume can start identical streams
    private var captures: [Capture] = []
    private var streams: [SCStream] = []
    private var sinks: [StreamSink] = []
    private var writer: RecordingWriter?
    private var areaSelector: AreaSelector?
    /// Time recorded in earlier segments, before the last Resume
    private var recordedDuration: TimeInterval = 0
    private var segmentStartedAt: Date?
    private var saveHandlers: [() -> Void] = []

    override init() {
        defaults.register(defaults: [
            Constants.Recording.Keys.systemAudio: true,
            Constants.Recording.Keys.microphone: false,
            Constants.Recording.Keys.source: RecordingSource.screen.rawValue
        ])
        capturesSystemAudio = defaults.bool(forKey: Constants.Recording.Keys.systemAudio)
        capturesMicrophone = defaults.bool(forKey: Constants.Recording.Keys.microphone)
        source = RecordingSource(rawValue: defaults.string(forKey: Constants.Recording.Keys.source) ?? "") ?? .screen
        selectedDisplayID = CGDirectDisplayID(defaults.integer(forKey: Constants.Recording.Keys.display))
        super.init()
        refreshDisplays()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    var isRecording: Bool { state == .recording || state == .pausing }

    var isPaused: Bool { state == .paused }

    /// A recording is in progress or stopped and not yet saved
    var hasUnsavedRecording: Bool { isRecording || isPaused }

    /// Total recorded time, excluding pauses
    var elapsed: TimeInterval {
        recordedDuration + (segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    var selectedDisplayName: String {
        displays.first { $0.id == selectedDisplayID }?.name ?? "Main screen"
    }

    static var isSupported: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    // MARK: Actions

    func start() {
        guard state == .idle else { return }
        guard Self.isSupported else {
            errorMessage = "Screen recording needs macOS 15 or later."
            return
        }
        errorMessage = nil
        needsPrivacySettings = false

        guard source == .area else {
            begin(area: nil)
            return
        }
        state = .selectingArea
        let selector = AreaSelector { [weak self] selection in
            guard let self = self else { return }
            self.areaSelector = nil
            if let selection = selection {
                self.begin(area: selection)
            } else {
                self.state = .idle
            }
        }
        areaSelector = selector
        selector.show()
    }

    /// Stops capturing but keeps the movie open so the user can resume or save it.
    func pause(completion: (() -> Void)? = nil) {
        guard state == .recording else {
            completion?()
            return
        }
        state = .pausing
        Task { @MainActor in
            await self.stopStreams()
            // A failure while stopping already reset the recorder
            if self.state == .pausing { self.state = .paused }
            completion?()
        }
    }

    func resume() {
        guard state == .paused else { return }
        errorMessage = nil
        needsPrivacySettings = false
        state = .starting
        Task { @MainActor in
            do {
                try await self.startStreams()
                self.state = .recording
            } catch {
                NSLog("Nook: resuming screen recording failed: \(error.localizedDescription)")
                self.errorMessage = "Couldn't resume: \(error.localizedDescription)"
                self.state = .paused
            }
        }
    }

    /// Finishes the movie and asks where to save it. Stops first if still recording;
    /// `completion` runs once the file is saved or deleted (or right away if there's nothing to save).
    func save(completion: (() -> Void)? = nil) {
        if state == .recording {
            pause { [weak self] in
                guard let self = self else { completion?(); return }
                self.save(completion: completion)
            }
            return
        }
        guard state == .paused, let writer = writer else {
            completion?()
            return
        }
        if let completion = completion { saveHandlers.append(completion) }
        state = .saving
        writer.finish { [weak self] url in
            guard let self = self else { return }
            self.reset()
            if let url = url {
                self.promptToSave(url)
            } else {
                self.errorMessage = "Nothing was recorded"
            }
            self.runSaveHandlers()
        }
    }

    /// Deletes a stopped recording after the user confirms.
    func discard() {
        guard state == .paused, let writer = writer else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard confirmDiscard(keepTitle: "Keep") else { return }
        writer.cancel()
        reset()
    }

    func openPrivacySettings() {
        if let url = URL(string: Constants.Recording.privacySettingsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Displays

    @objc private func screensChanged() {
        refreshDisplays()
    }

    private func refreshDisplays() {
        displays = NSScreen.screens
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { screen in screen.displayID.map { DisplayOption(id: $0, name: screen.localizedName) } }
        if !displays.contains(where: { $0.id == selectedDisplayID }),
           let fallback = NSScreen.main?.displayID ?? displays.first?.id {
            selectedDisplayID = fallback
        }
    }

    // MARK: Recording

    private func begin(area: AreaSelection?) {
        guard #available(macOS 15.0, *) else { return }
        state = .starting
        Task { @MainActor in
            do {
                try await self.beginRecording(area: area)
            } catch {
                self.fail(error)
            }
        }
    }

    @available(macOS 15.0, *)
    @MainActor
    private func beginRecording(area: AreaSelection?) async throws {
        if capturesMicrophone {
            try await requestMicrophoneAccess()
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            NSLog("Nook: listing shareable content failed: \(error.localizedDescription)")
            throw RecorderError.screenAccessDenied
        }

        let chosen = chooseDisplays(from: content.displays, area: area)
        guard !chosen.isEmpty else { throw RecorderError.noDisplay }

        // Leave Nook's own island and overlays out of the video
        let nook = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filters = chosen.map { SCContentFilter(display: $0, excludingApplications: nook, exceptingWindows: []) }
        let pixelSizes = filters.map { filter -> CGSize in
            let points = area?.rect.size ?? filter.contentRect.size
            let scale = CGFloat(filter.pointPixelScale)
            return CGSize(width: points.width * scale, height: points.height * scale)
        }
        let layout = CanvasLayout(sourceSizes: pixelSizes)

        captures = zip(filters, layout.tiles).enumerated().map { index, pair in
            let (filter, tile) = pair
            let config = SCStreamConfiguration()
            config.width = Int(tile.width)
            config.height = Int(tile.height)
            if let area = area {
                config.sourceRect = area.rect
            }
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.minimumFrameInterval = CMTime(value: 1, timescale: Constants.Recording.framesPerSecond)
            config.queueDepth = Constants.Recording.queueDepth
            config.showsCursor = true
            // Audio comes from the first stream only, so it isn't recorded twice
            let recordsAudio = index == 0
            config.capturesAudio = recordsAudio && capturesSystemAudio
            config.captureMicrophone = recordsAudio && capturesMicrophone
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Constants.Recording.audioSampleRate
            config.channelCount = Constants.Recording.audioChannelCount
            return Capture(filter: filter, configuration: config)
        }

        let writer = try RecordingWriter(
            url: Self.makeOutputURL(),
            layout: layout,
            queue: sampleQueue,
            systemAudio: capturesSystemAudio,
            microphone: capturesMicrophone
        )
        writer.onFailure = { [weak self, weak writer] error in
            guard let self = self, self.writer === writer else { return }
            self.fail(error)
        }
        self.writer = writer
        recordedDuration = 0

        try await startStreams()
        state = .recording
    }

    /// The displays to record, in the order they appear in the movie (left to right).
    @available(macOS 15.0, *)
    private func chooseDisplays(from displays: [SCDisplay], area: AreaSelection?) -> [SCDisplay] {
        if let area = area {
            return displays.filter { $0.displayID == area.displayID }
        }
        switch source {
        case .allScreens:
            return displays.sorted { $0.frame.minX < $1.frame.minX }
        case .screen, .area:
            let mainID = NSScreen.main?.displayID
            let display = displays.first { $0.displayID == selectedDisplayID }
                ?? displays.first { $0.displayID == mainID }
                ?? displays.first
            return display.map { [$0] } ?? []
        }
    }

    @MainActor
    private func startStreams() async throws {
        guard #available(macOS 15.0, *), let writer = writer else { return }
        writer.setAccepting(true)
        do {
            for (index, capture) in captures.enumerated() {
                let stream = SCStream(filter: capture.filter, configuration: capture.configuration, delegate: self)
                let sink = StreamSink(index: index, writer: writer)
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sampleQueue)
                if capture.configuration.capturesAudio {
                    try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sampleQueue)
                }
                if capture.configuration.captureMicrophone {
                    try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sampleQueue)
                }
                streams.append(stream)
                sinks.append(sink)
                try await stream.startCapture()
            }
        } catch {
            await stopStreams()
            throw error
        }
        segmentStartedAt = Date()
    }

    @MainActor
    private func stopStreams() async {
        writer?.setAccepting(false)
        if let start = segmentStartedAt {
            recordedDuration += Date().timeIntervalSince(start)
        }
        segmentStartedAt = nil
        let current = streams
        streams = []
        sinks = []
        for stream in current {
            try? await stream.stopCapture()
        }
    }

    private func requestMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw RecorderError.microphoneAccessDenied
        default:
            throw RecorderError.microphoneAccessDenied
        }
    }

    /// Records into a temporary file; the user picks the final name and folder on save.
    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Nook Recording \(formatter.string(from: Date())).mov")
    }

    private func reset() {
        captures = []
        streams = []
        sinks = []
        writer = nil
        recordedDuration = 0
        segmentStartedAt = nil
        state = .idle
    }

    /// Shows a save panel (Desktop by default) until the recording is saved or
    /// the user confirms they want to delete it.
    private func promptToSave(_ recording: URL) {
        NSApp.activate(ignoringOtherApps: true)
        while true {
            let panel = NSSavePanel()
            panel.title = "Save Recording"
            panel.prompt = "Save"
            panel.nameFieldLabel = "Name:"
            panel.nameFieldStringValue = recording.lastPathComponent
            panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            panel.allowedContentTypes = [.quickTimeMovie]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false

            if panel.runModal() == .OK, let destination = panel.url {
                do {
                    try Self.move(recording, to: destination)
                    Notifier.post(title: "Recording saved", body: destination.lastPathComponent)
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    return
                } catch {
                    NSAlert(error: error).runModal()
                    continue
                }
            }

            if confirmDiscard(keepTitle: "Back to Save") {
                try? FileManager.default.removeItem(at: recording)
                return
            }
        }
    }

    private static func move(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        // The save panel has already asked the user before replacing a file
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    private func confirmDiscard(keepTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "It hasn't been saved yet. If you delete it, it can't be recovered."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: keepTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func fail(_ error: Error) {
        NSLog("Nook: screen recording failed: \(error.localizedDescription)")
        let recorderError = error as? RecorderError
        errorMessage = recorderError?.message ?? error.localizedDescription
        needsPrivacySettings = recorderError?.needsPrivacySettings ?? false
        let current = streams
        writer?.cancel()
        reset()
        for stream in current {
            Task { try? await stream.stopCapture() }
        }
        runSaveHandlers()
    }

    private func runSaveHandlers() {
        let handlers = saveHandlers
        saveHandlers.removeAll()
        handlers.forEach { $0() }
    }

    enum RecorderError: Error {
        case screenAccessDenied
        case microphoneAccessDenied
        case noDisplay

        var message: String {
            switch self {
            case .screenAccessDenied: return "Allow Nook under Screen & System Audio Recording"
            case .microphoneAccessDenied: return "Allow Nook under Microphone in Privacy settings"
            case .noDisplay: return "That screen isn't connected anymore"
            }
        }

        var needsPrivacySettings: Bool { self != .noDisplay }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Also fires when the user stops sharing from the system's menu bar
        // indicator; keep what was recorded so it can be resumed or saved
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.streams.contains(where: { $0 === stream }) else { return }
            NSLog("Nook: screen capture stopped: \(error.localizedDescription)")
            self.pause()
        }
    }
}

/// Forwards one stream's samples to the writer, tagged with the stream's tile.
private final class StreamSink: NSObject, SCStreamOutput {
    let index: Int
    let writer: RecordingWriter

    init(index: Int, writer: RecordingWriter) {
        self.index = index
        self.writer = writer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        writer.append(sampleBuffer, of: type, from: index)
    }
}

// MARK: - Recording Canvas

/// Places each recorded source side by side, left to right and vertically
/// centered, scaled down if needed to fit what the video encoder supports.
private struct CanvasLayout {
    let canvasSize: CGSize
    /// One rect per source, in pixels with a bottom-left origin (Core Image's)
    let tiles: [CGRect]
    let codec: AVVideoCodecType

    init(sourceSizes: [CGSize]) {
        let width = sourceSizes.reduce(0) { $0 + $1.width }
        let height = sourceSizes.map(\.height).max() ?? 0
        let h264Max = Constants.Recording.h264MaxSize
        let fitsH264 = width <= h264Max.width && height <= h264Max.height
        // H.264 tops out around 4K; wider canvases (two Retina screens) use HEVC
        codec = fitsH264 ? .h264 : .hevc
        let limit = fitsH264 ? h264Max : Constants.Recording.hevcMaxSize
        let scale = min(1, limit.width / max(width, 1), limit.height / max(height, 1))

        let canvasHeight = Self.even(height * scale)
        var x: CGFloat = 0
        tiles = sourceSizes.map { size in
            let tileWidth = Self.even(size.width * scale)
            let tileHeight = min(canvasHeight, Self.even(size.height * scale))
            let tile = CGRect(x: x, y: Self.even((canvasHeight - tileHeight) / 2), width: tileWidth, height: tileHeight)
            x += tileWidth
            return tile
        }
        canvasSize = CGSize(width: x, height: canvasHeight)
    }

    /// Video encoders need even dimensions
    private static func even(_ value: CGFloat) -> CGFloat {
        max(0, (value / 2).rounded(.down) * 2)
    }
}

/// Writes samples from one or more streams into a single movie. With several
/// streams, each frame is drawn into its tile on a shared canvas. Pauses leave
/// no gap: samples after a resume are shifted back to continue where the
/// movie left off. Everything after `init` runs on the sample queue.
private final class RecordingWriter {
    let url: URL
    var onFailure: ((Error) -> Void)?

    private let queue: DispatchQueue
    private let layout: CanvasLayout
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudioInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let frameDuration = CMTime(value: 1, timescale: Constants.Recording.framesPerSecond)

    private var latestFrames: [CVPixelBuffer?]
    private var isAccepting = false
    private var needsResync = false
    private var failed = false
    private var sessionStartTime = CMTime.invalid
    /// Total length of the pauses so far, subtracted from every sample's time
    private var timeOffset = CMTime.zero
    /// End of the last sample written, on the capture clock
    private var lastSourceTime = CMTime.invalid
    /// End of the last sample written, on the movie's clock
    private var lastOutputTime = CMTime.invalid
    private var lastVideoTime = CMTime.invalid

    init(url: URL, layout: CanvasLayout, queue: DispatchQueue, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        self.layout = layout
        self.queue = queue
        latestFrames = Array(repeating: nil, count: layout.tiles.count)

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = Int(layout.canvasSize.width)
        let height = Int(layout.canvasSize.height)
        let fps = Int(Constants.Recording.framesPerSecond)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: layout.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        systemAudioInput = systemAudio ? Self.makeAudioInput() : nil
        microphoneInput = microphone ? Self.makeAudioInput() : nil

        for input in [videoInput, systemAudioInput, microphoneInput].compactMap({ $0 }) where writer.canAdd(input) {
            writer.add(input)
        }
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    private static func makeAudioInput() -> AVAssetWriterInput {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Constants.Recording.audioSampleRate,
            AVNumberOfChannelsKey: Constants.Recording.audioChannelCount,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            AVEncoderBitRateKey: Constants.Recording.audioBitRate
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    /// Starts or stops taking samples; a restart closes the gap since the stop.
    func setAccepting(_ accepting: Bool) {
        queue.async {
            if accepting, !self.isAccepting {
                self.needsResync = self.lastSourceTime.isValid
            }
            if !accepting {
                // Let go of the capture buffers so the stopped streams can be freed
                self.latestFrames = Array(repeating: nil, count: self.layout.tiles.count)
            }
            self.isAccepting = accepting
        }
    }

    func append(_ sample: CMSampleBuffer, of type: SCStreamOutputType, from index: Int) {
        guard isAccepting, !failed, sample.isValid else { return }
        let sourceTime = sample.presentationTimeStamp
        guard sourceTime.isValid else { return }

        if needsResync {
            needsResync = false
            if sourceTime > lastSourceTime {
                timeOffset = timeOffset + (sourceTime - lastSourceTime)
            }
        }

        switch type {
        case .screen:
            appendVideo(sample, from: index, at: sourceTime)
        case .audio:
            appendAudio(sample, to: systemAudioInput)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                appendAudio(sample, to: microphoneInput)
            }
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer, from index: Int, at sourceTime: CMTime) {
        // Only complete frames carry an image; idle frames mean nothing changed
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let frame = sample.imageBuffer,
              latestFrames.indices.contains(index) else { return }
        latestFrames[index] = frame

        let time = sourceTime - timeOffset
        if !sessionStartTime.isValid {
            writer.startSession(atSourceTime: time)
            sessionStartTime = time
        } else if lastVideoTime.isValid, time <= lastVideoTime {
            return
        }
        guard videoInput.isReadyForMoreMediaData else { return }

        let buffer = layout.tiles.count == 1 ? frame : compose()
        guard let buffer = buffer else { return }
        guard adaptor.append(buffer, withPresentationTime: time) else {
            reportFailure()
            return
        }
        lastVideoTime = time
        noteWritten(sourceEnd: sourceTime + frameDuration, outputEnd: time + frameDuration)
    }

    /// Draws the latest frame from every stream into its tile on a fresh canvas.
    private func compose() -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output = output else { return nil }

        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        var image = CIImage(color: .black).cropped(to: canvas)
        for (frame, tile) in zip(latestFrames, layout.tiles) {
            guard let frame = frame else { continue }
            let source = CIImage(cvPixelBuffer: frame)
            let transform = CGAffineTransform(scaleX: tile.width / source.extent.width, y: tile.height / source.extent.height)
                .concatenating(CGAffineTransform(translationX: tile.minX, y: tile.minY))
            image = source.transformed(by: transform).composited(over: image)
        }
        ciContext.render(image, to: output, bounds: canvas, colorSpace: colorSpace)
        return output
    }

    private func appendAudio(_ sample: CMSampleBuffer, to input: AVAssetWriterInput?) {
        // Audio waits for the first video frame so the movie doesn't open on black
        guard let input = input, sessionStartTime.isValid, input.isReadyForMoreMediaData,
              let retimed = retime(sample) else { return }
        let time = retimed.presentationTimeStamp
        guard time >= sessionStartTime else { return }
        guard input.append(retimed) else {
            reportFailure()
            return
        }
        let duration = sample.duration.isValid ? sample.duration : .zero
        noteWritten(sourceEnd: sample.presentationTimeStamp + duration, outputEnd: time + duration)
    }

    private func retime(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard timeOffset != .zero else { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - timeOffset
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - timeOffset
            }
        }
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
            sampleTimingArray: &timing, sampleBufferOut: &retimed
        )
        return retimed
    }

    private func noteWritten(sourceEnd: CMTime, outputEnd: CMTime) {
        if !lastSourceTime.isValid || sourceEnd > lastSourceTime { lastSourceTime = sourceEnd }
        if !lastOutputTime.isValid || outputEnd > lastOutputTime { lastOutputTime = outputEnd }
    }

    private func reportFailure() {
        guard !failed else { return }
        failed = true
        let error = writer.error ?? CocoaError(.fileWriteUnknown)
        DispatchQueue.main.async { self.onFailure?(error) }
    }

    /// Closes the movie; `completion` gets its URL on the main queue, or nil if nothing was written.
    func finish(completion: @escaping (URL?) -> Void) {
        queue.async {
            self.isAccepting = false
            self.latestFrames = Array(repeating: nil, count: self.layout.tiles.count)
            guard self.sessionStartTime.isValid, self.writer.status == .writing else {
                self.discardFile()
                DispatchQueue.main.async { completion(nil) }
                return
            }
            for input in [self.videoInput, self.systemAudioInput, self.microphoneInput].compactMap({ $0 }) {
                input.markAsFinished()
            }
            if self.lastOutputTime.isValid {
                self.writer.endSession(atSourceTime: self.lastOutputTime)
            }
            self.writer.finishWriting {
                let saved = self.writer.status == .completed
                if !saved {
                    NSLog("Nook: finishing recording failed: \(self.writer.error?.localizedDescription ?? "unknown error")")
                    try? FileManager.default.removeItem(at: self.url)
                }
                DispatchQueue.main.async { completion(saved ? self.url : nil) }
            }
        }
    }

    /// Stops writing and deletes the file.
    func cancel() {
        queue.async {
            self.isAccepting = false
            self.latestFrames = Array(repeating: nil, count: self.layout.tiles.count)
            self.discardFile()
        }
    }

    private func discardFile() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Area Selection

/// Dims every screen and lets the user drag out the area to record. Esc cancels.
private final class AreaSelector {
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

// MARK: - Bluetooth

struct BluetoothDeviceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let isConnected: Bool
    let battery: String?
}

/// Lists paired Bluetooth devices and connects or disconnects them.
/// Uses IOBluetooth for the devices and CoreBluetooth only for the power and
/// permission state. Battery levels rely on undocumented IOBluetoothDevice
/// selectors, so they're checked before use.
final class BluetoothManager: NSObject, ObservableObject {
    enum Availability: Equatable {
        case loading
        case ready
        case poweredOff
        case unauthorized
    }

    @Published private(set) var availability: Availability = .loading
    @Published private(set) var devices: [BluetoothDeviceInfo] = []
    @Published private(set) var busyDevices: Set<String> = []
    @Published private(set) var errorMessage: String?

    /// Created on first use so the Bluetooth permission prompt only appears
    /// once the user opens the island, not at launch
    private var central: CBCentralManager?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var isRefreshScheduled = false
    private var refreshGeneration = 0
    private let reportQueue = DispatchQueue(label: "com.nook.bluetooth.report", qos: .userInitiated)

    /// Refreshes on the next main-loop turn, collapsing bursts into one. Callbacks
    /// must use this rather than `refresh()`: registering for connect
    /// notifications calls back synchronously once per connected device, and
    /// refreshing inside that call re-enters `refresh()` and deadlocks the
    /// ObservableObject publisher.
    private func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isRefreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        guard let central = central else {
            // The delegate's state callback triggers the first real refresh
            self.central = CBCentralManager(delegate: self, queue: .main)
            return
        }

        switch central.state {
        case .unauthorized:
            setUnavailable(.unauthorized)
        case .poweredOff:
            setUnavailable(.poweredOff)
        case .poweredOn:
            // Publishing re-renders the whole island, so skip it when nothing changed
            if availability != .ready { availability = .ready }
            watchConnections()
            refreshGeneration += 1
            let generation = refreshGeneration
            // Each IOBluetooth property read is a round trip to bluetoothd; doing
            // them on the main thread held up the island every time it opened
            reportQueue.async { [weak self] in
                let paired = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).map(Self.info)
                let report = SystemBluetoothReport.load()
                let devices = Self.merge(paired, with: report).sorted {
                    if $0.isConnected != $1.isConnected { return $0.isConnected }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                DispatchQueue.main.async {
                    // A newer refresh (or Bluetooth turning off) supersedes this one
                    guard let self = self, generation == self.refreshGeneration else { return }
                    if self.devices != devices { self.devices = devices }
                }
            }
        default:
            // .unknown / .resetting / .unsupported: keep what we have until it settles
            break
        }
    }

    // MARK: Actions

    func toggleConnection(_ info: BluetoothDeviceInfo) {
        guard !busyDevices.contains(info.id), let device = IOBluetoothDevice(addressString: info.id) else { return }
        errorMessage = nil
        busyDevices.insert(info.id)

        if device.isConnected() {
            let status = device.closeConnection()
            if status != kIOReturnSuccess {
                errorMessage = "Couldn't disconnect \(info.name)"
            }
            // The disconnect notification usually refreshes first; this catches the rest
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Bluetooth.refreshDelay) { [weak self] in
                self?.busyDevices.remove(info.id)
                self?.refresh()
            }
        } else {
            // With a target the call returns at once and reports to connectionComplete(_:status:)
            let status = device.openConnection(self)
            if status != kIOReturnSuccess {
                busyDevices.remove(info.id)
                errorMessage = "Couldn't connect to \(info.name)"
            }
        }
    }

    func openSettings() {
        let url = availability == .unauthorized
            ? Constants.Bluetooth.privacySettingsURL
            : Constants.Bluetooth.settingsURL
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Connection Callbacks

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        let address = device.addressString ?? ""
        busyDevices.remove(address)
        if status != kIOReturnSuccess {
            errorMessage = "Couldn't connect to \(device.name ?? "device") — is it on and nearby?"
        }
        scheduleRefresh()
    }

    private func watchConnections() {
        guard connectNotification == nil else { return }
        // Fires right away for devices that are already connected, too
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString, disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDisconnected(_:device:))
            )
        }
        scheduleRefresh()
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        if let address = device.addressString {
            disconnectNotifications[address] = nil
        }
        scheduleRefresh()
    }

    private func setUnavailable(_ state: Availability) {
        refreshGeneration += 1
        if availability != state { availability = state }
        if !devices.isEmpty { devices = [] }
    }

    // MARK: Device Details

    /// Keeps only devices macOS itself lists (IOBluetooth also returns stale
    /// pairing records, which showed up as duplicates) and prefers the system's
    /// name and battery levels, which include the AirPods case.
    private static func merge(_ paired: [BluetoothDeviceInfo], with report: [String: SystemBluetoothReport.Entry]) -> [BluetoothDeviceInfo] {
        var seen: Set<String> = []
        return paired.compactMap { device in
            let address = SystemBluetoothReport.normalize(device.id)
            guard seen.insert(address).inserted else { return nil }
            // An empty report means system_profiler failed; show everything rather than nothing
            guard !report.isEmpty else { return device }
            guard let entry = report[address] else { return nil }
            return BluetoothDeviceInfo(
                id: device.id,
                name: entry.name,
                icon: device.icon,
                isConnected: device.isConnected,
                battery: device.isConnected ? (entry.batteryText ?? device.battery) : nil
            )
        }
    }

    private static func info(for device: IOBluetoothDevice) -> BluetoothDeviceInfo {
        let isConnected = device.isConnected()
        return BluetoothDeviceInfo(
            id: device.addressString ?? UUID().uuidString,
            name: device.name ?? device.addressString ?? "Unknown device",
            icon: icon(for: device),
            isConnected: isConnected,
            battery: isConnected ? batteryText(for: device) : nil
        )
    }

    /// Reads an undocumented numeric property, or nil if this macOS lacks it.
    private static func number(_ key: String, of device: IOBluetoothDevice) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        return (device.value(forKey: key) as? NSNumber)?.intValue
    }

    private static func batteryText(for device: IOBluetoothDevice) -> String? {
        // 0 means "not reported", so only 1–100 counts as a reading
        func percent(_ key: String) -> Int? {
            guard let value = number(key, of: device), (1...100).contains(value) else { return nil }
            return value
        }

        let parts = [("L", "batteryPercentLeft"), ("R", "batteryPercentRight"), ("Case", "batteryPercentCase")]
            .compactMap { label, key in percent(key).map { "\(label) \($0)%" } }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return (percent("batteryPercentSingle") ?? percent("batteryPercentCombined")).map { "\($0)%" }
    }

    private static func icon(for device: IOBluetoothDevice) -> String {
        let name = (device.name ?? "").lowercased()
        if name.contains("airpods") { return "airpods" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("watch") { return "applewatch" }
        if number("isLowEnergyKeyboard", of: device) == 1 || name.contains("keyboard") { return "keyboard" }
        if number("isLowEnergyPointer", of: device) == 1 || name.contains("mouse") { return "computermouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }

        // Bluetooth Class of Device major/minor values
        switch device.deviceClassMajor {
        case 0x01: return "laptopcomputer"
        case 0x02: return "iphone"
        case 0x04:
            return device.deviceClassMinor == 0x05 ? "hifispeaker" : "headphones"
        case 0x05:
            if device.deviceClassMinor & 0x10 != 0 { return "keyboard" }
            if device.deviceClassMinor & 0x20 != 0 { return "computermouse" }
            return "gamecontroller"
        default:
            return "dot.radiowaves.left.and.right"
        }
    }
}

/// The Bluetooth section of `system_profiler`: the same device list and battery
/// levels System Settings shows. Takes well under a second, so it runs on each refresh.
private enum SystemBluetoothReport {
    struct Entry {
        let name: String
        let batteryText: String?
    }

    /// Devices keyed by normalized address, or empty if the report couldn't be read.
    static func load() -> [String: Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("Nook: couldn't run system_profiler: \(error.localizedDescription)")
            return [:]
        }
        // Read before waiting so a full pipe can't block the process
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }

        var entries: [String: Entry] = [:]
        for section in sections {
            for group in ["device_connected", "device_not_connected"] {
                for item in section[group] as? [[String: Any]] ?? [] {
                    for (name, value) in item {
                        guard let info = value as? [String: Any],
                              let address = info["device_address"] as? String else { continue }
                        entries[normalize(address)] = Entry(name: name, batteryText: batteryText(info))
                    }
                }
            }
        }
        return entries
    }

    /// IOBluetooth uses "b4-59-76-…", system_profiler "B4:59:76:…".
    static func normalize(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func batteryText(_ info: [String: Any]) -> String? {
        func percent(_ key: String) -> Int? {
            (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        }
        let parts = [("L", "device_batteryLevelLeft"), ("R", "device_batteryLevelRight"), ("Case", "device_batteryLevelCase")]
            .compactMap { label, key in percent(key).map { "\(label) \($0)%" } }
        if !parts.isEmpty {
            return parts.joined(separator: " · ")
        }
        return percent("device_batteryLevelMain").map { "\($0)%" }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Called from inside CoreBluetooth's own state update, so refresh after it returns
        scheduleRefresh()
    }
}

// MARK: - System Monitor

/// One reading of the Mac's vital signs. `nil` means unknown or not present
/// (no battery on a desktop, no GPU statistics, or the first sample).
struct SystemStats {
    var cpu: Double?
    var gpu: Double?
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var battery: BatteryStatus?
    var download: Double?
    var upload: Double?
    var diskAvailable: Int64?
    var diskTotal: Int64?
    /// What the whole Mac draws right now, in watts
    var systemPower: Double?
    /// The connected power adapter's rating, in watts
    var adapterWatts: Int?

    var memory: Double? {
        memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : nil
    }

    struct BatteryStatus {
        var level: Double
        var isCharging: Bool
        var isOnAC: Bool
    }
}

/// Samples CPU, GPU, memory, battery, network, disk and power while the
/// System page is open. It reads counters, so rates (CPU, network) appear
/// from the second sample on.
final class SystemMonitor: ObservableObject {
    @Published private(set) var stats = SystemStats()

    /// The island is open
    var isIslandShown = false { didSet { updateTimer() } }
    /// The System page is the one showing
    var isPageShown = false { didSet { updateTimer() } }

    private var timer: Timer?
    private let queue = DispatchQueue(label: "nook.system-monitor", qos: .utility)
    // Only touched on `queue`
    private var lastCPUTicks: (busy: UInt64, total: UInt64)?
    private var lastNetwork: (received: UInt64, sent: UInt64, at: Date)?

    private func updateTimer() {
        let shouldRun = isIslandShown && isPageShown
        guard shouldRun != (timer != nil) else { return }
        if shouldRun {
            sample()
            let timer = Timer(timeInterval: Constants.System.sampleInterval, repeats: true) { [weak self] _ in
                self?.sample()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func sample() {
        queue.async { [weak self] in
            guard let self = self else { return }
            var stats = SystemStats()
            stats.cpu = self.readCPU()
            stats.gpu = Self.readGPU()
            stats.memoryUsed = Self.readMemoryUsed()
            stats.battery = Self.readBattery()
            (stats.download, stats.upload) = self.readNetwork()
            (stats.diskAvailable, stats.diskTotal) = Self.readDisk()
            (stats.systemPower, stats.adapterWatts) = Self.readPower(isOnAC: stats.battery?.isOnAC ?? true)
            DispatchQueue.main.async {
                self.stats = stats
            }
        }
    }

    // MARK: Readers

    /// Busy share of all cores since the last sample
    private func readCPU() -> Double? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
        let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
        let ticks = (busy: user + system + nice, total: user + system + nice + idle)
        defer { lastCPUTicks = ticks }
        guard let last = lastCPUTicks, ticks.total > last.total else { return nil }
        return Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
    }

    /// The GPU driver's own utilization figure, as Activity Monitor shows it
    private static func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var utilization: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            utilization = max(utilization ?? 0, percent / 100)
        }
        return utilization
    }

    /// App memory, wired and compressed, like "Memory Used" in Activity Monitor
    private static func readMemoryUsed() -> UInt64 {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let appPages = UInt64(info.internal_page_count) - min(UInt64(info.internal_page_count), UInt64(info.purgeable_count))
        let pages = appPages + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private static func readBattery() -> SystemStats.BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return SystemStats.BatteryStatus(
                level: Double(current) / Double(maximum),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnAC: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return nil
    }

    /// Bytes per second in and out across all interfaces except loopback
    private func readNetwork() -> (Double?, Double?) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (nil, nil) }
        defer { freeifaddrs(addresses) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let data = entry.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date()
        defer { lastNetwork = (received, sent, now) }
        guard let last = lastNetwork else { return (nil, nil) }
        let seconds = now.timeIntervalSince(last.at)
        // Counters are 32-bit per interface and wrap; skip the odd sample where they did
        guard seconds > 0, received >= last.received, sent >= last.sent else { return (nil, nil) }
        return (Double(received - last.received) / seconds, Double(sent - last.sent) / seconds)
    }

    private static func readDisk() -> (Int64?, Int64?) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey
        ])
        return (values?.volumeAvailableCapacityForImportantUsage, values?.volumeTotalCapacity.map(Int64.init))
    }

    /// The Mac's power draw and the adapter's rating, from the battery controller.
    /// Macs without a battery don't report either.
    private static func readPower(isOnAC: Bool) -> (Double?, Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let battery = properties?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }

        let adapter = battery["AdapterDetails"] as? [String: Any]
        let adapterWatts = isOnAC ? (adapter?["Watts"] as? NSNumber)?.intValue : nil

        // On power, the telemetry has what the whole system draws (in mW)
        if isOnAC,
           let telemetry = battery["PowerTelemetryData"] as? [String: Any],
           let milliwatts = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue, milliwatts > 0 {
            return (milliwatts / 1000, adapterWatts)
        }
        // On battery, it's what the battery gives out: volts × amps.
        // Amperage is signed but may come back as its unsigned bit pattern.
        guard let millivolts = (battery["Voltage"] as? NSNumber)?.doubleValue,
              let rawAmperage = (battery["InstantAmperage"] as? NSNumber ?? battery["Amperage"] as? NSNumber)?.uint64Value else {
            return (nil, adapterWatts)
        }
        let milliamps = Double(Int64(bitPattern: rawAmperage))
        return (abs(millivolts * milliamps) / 1_000_000, adapterWatts)
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

// MARK: - Music

struct MusicStation: Codable, Identifiable, Equatable {
    enum Source: Codable, Equatable {
        case video(String)
        case playlist(String)
        /// Presets play the top live stream for a search, so they never go
        /// stale when a channel restarts its stream under a new ID
        case liveSearch(String)
        /// One of your own playlists, read through your signed-in account so
        /// private ones play too
        case accountPlaylist(String)
    }

    var id: String
    var name: String
    var emoji: String
    var source: Source

    var isPlaylist: Bool {
        switch source {
        case .playlist, .accountPlaylist: return true
        case .video, .liveSearch: return false
        }
    }

    /// Shortened, since saved video titles can run to a hundred characters
    var menuTitle: String {
        let limit = 48
        let shortName = name.count > limit ? name.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : name
        return "\(emoji)  \(shortName)"
    }

    static let presets = [
        MusicStation(id: "preset.study", name: "Study", emoji: "📚", source: .liveSearch("lofi hip hop radio")),
        MusicStation(id: "preset.sleep", name: "Sleep", emoji: "🌙", source: .liveSearch("sleep music")),
        MusicStation(id: "preset.focus", name: "Focus", emoji: "🎯", source: .liveSearch("deep focus music")),
        MusicStation(id: "preset.jazz", name: "Jazz", emoji: "☕", source: .liveSearch("jazz cafe music"))
    ]

    /// A station for a video or playlist. The ID comes from YouTube's, so the
    /// same video found twice is the same station.
    static func youTube(_ source: Source, name: String) -> MusicStation {
        let id: String
        switch source {
        case .video(let videoID): id = "video.\(videoID)"
        case .playlist(let listID): id = "playlist.\(listID)"
        case .liveSearch(let query): id = "search.\(query)"
        case .accountPlaylist(let listID): id = "account.\(listID)"
        }
        return MusicStation(id: id, name: name, emoji: "★", source: source)
    }

    /// Reads a YouTube link (watch, youtu.be, live, shorts, embed, playlist)
    /// or a bare 11-character video ID.
    static func source(fromLink text: String) -> Source? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isVideoID = { (id: String) in id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil }
        if isVideoID(trimmed) { return .video(trimmed) }

        guard let components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              let host = components.host?.lowercased(),
              host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }

        // Auto-generated mixes ("RD…") only play on YouTube itself
        if let list = components.queryItems?.first(where: { $0.name == "list" })?.value, !list.hasPrefix("RD") {
            return .playlist(list)
        }
        let path = components.path.split(separator: "/").map(String.init)
        var videoID = components.queryItems?.first(where: { $0.name == "v" })?.value
        if host == "youtu.be" {
            videoID = path.first
        } else if path.count >= 2, ["live", "shorts", "embed"].contains(path[0]) {
            videoID = path[1]
        }
        if let videoID = videoID, isVideoID(videoID) { return .video(videoID) }
        return nil
    }
}

enum MusicError: LocalizedError {
    case badLink
    case notEmbeddable
    case notFound
    case noLiveStream
    case player(Int)
    case network
    case signIn
    case emptyPlaylist

    var errorDescription: String? {
        switch self {
        case .badLink: return "That isn't a YouTube video or playlist link"
        case .notEmbeddable: return "This can only be played on YouTube"
        case .notFound: return "This video is private or was removed"
        case .noLiveStream: return "No live stream found right now"
        case .network: return "Can't reach YouTube"
        case .signIn: return "Connect your YouTube account again"
        case .emptyPlaylist: return "This playlist has no videos"
        case .player(let code):
            switch code {
            case 100: return "This video is private or was removed"
            case 101, 150: return "This can only be played on YouTube"
            case 2: return "That isn't a valid YouTube video"
            default: return "YouTube couldn't play this (error \(code))"
            }
        }
    }
}

enum MusicSearchFilter: String, CaseIterable, Identifiable {
    case all, live, playlists, long

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .live: return "Live"
        case .playlists: return "Playlists"
        case .long: return "Long (1h+)"
        }
    }

    /// The `params` youtube.com sends for its own search filters
    fileprivate var params: String? {
        switch self {
        case .all: return nil
        case .live: return "EgJAAQ=="
        case .playlists: return "EgIQAw=="
        case .long: return "EgIYAg=="
        }
    }
}

struct MusicSearchResult: Identifiable, Equatable {
    enum Kind { case video, live, playlist }

    let id: String
    let kind: Kind
    let title: String
    let channel: String
    /// Duration, "LIVE" or the number of videos
    let detail: String
    let thumbnail: URL?
    let durationSeconds: Int?

    var station: MusicStation {
        MusicStation.youTube(kind == .playlist ? .playlist(id) : .video(id), name: title)
    }
}

/// Talks to YouTube without an API key: search goes through the same API
/// youtube.com uses, and oEmbed tells whether a video may be embedded.
private enum YouTube {
    static func search(_ query: String, filter: MusicSearchFilter) async throws -> [MusicSearchResult] {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": Constants.Music.clientVersion, "hl": "en"]],
            "query": query
        ]
        if let params = filter.params { body["params"] = params }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MusicError.network
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MusicError.network }
        let json = try JSONSerialization.jsonObject(with: data)

        // Results come in sections; each item is a video or a playlist ("lockup")
        let sections = dig(json, "contents", "twoColumnSearchResultsRenderer", "primaryContents",
                           "sectionListRenderer", "contents") as? [Any] ?? []
        var results: [MusicSearchResult] = []
        var seen = Set<String>()
        for section in sections {
            for item in dig(section, "itemSectionRenderer", "contents") as? [Any] ?? [] {
                let result = (dig(item, "videoRenderer") as? [String: Any]).flatMap(video)
                    ?? (dig(item, "lockupViewModel") as? [String: Any]).flatMap(playlist)
                if let result = result, seen.insert(result.id).inserted {
                    results.append(result)
                }
            }
        }
        if filter == .long {
            results = results.filter { ($0.durationSeconds ?? 0) >= Constants.Music.longMinimumSeconds }
        }
        return Array(results.prefix(Constants.Music.searchResultLimit))
    }

    /// The title of a video or playlist, after checking it can be played
    /// outside YouTube. Throws `MusicError` when it can't.
    static func playableTitle(of source: MusicStation.Source) async throws -> String {
        let link: String
        switch source {
        case .video(let id): link = "https://www.youtube.com/watch?v=\(id)"
        case .playlist(let id), .accountPlaylist(let id): link = "https://www.youtube.com/playlist?list=\(id)"
        case .liveSearch(let query): return query
        }
        var components = URLComponents(string: "https://www.youtube.com/oembed")!
        components.queryItems = [URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "url", value: link)]

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: components.url!)
        } catch {
            throw MusicError.network
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            let title = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["title"] as? String
            return title ?? "YouTube"
        case 401, 403: throw MusicError.notEmbeddable
        case 400, 404: throw MusicError.notFound
        default: throw MusicError.network
        }
    }

    private static func video(_ renderer: [String: Any]) -> MusicSearchResult? {
        guard let id = renderer["videoId"] as? String else { return nil }
        let length = text(renderer["lengthText"])
        let badges = (renderer["badges"] as? [Any] ?? []).compactMap { dig($0, "metadataBadgeRenderer", "label") as? String }
        let isLive = badges.contains("LIVE") || length.isEmpty
        let channel = text(renderer["ownerText"]).isEmpty ? text(renderer["longBylineText"]) : text(renderer["ownerText"])
        return MusicSearchResult(
            id: id,
            kind: isLive ? .live : .video,
            title: text(renderer["title"]),
            channel: channel,
            detail: isLive ? "LIVE" : length,
            thumbnail: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"),
            durationSeconds: isLive ? nil : seconds(fromClock: length)
        )
    }

    private static func playlist(_ lockup: [String: Any]) -> MusicSearchResult? {
        guard lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_PLAYLIST",
              let id = lockup["contentId"] as? String,
              !id.hasPrefix("RD") else { return nil }
        let metadata = dig(lockup, "metadata", "lockupMetadataViewModel")
        let thumbnail = dig(lockup, "contentImage", "collectionThumbnailViewModel", "primaryThumbnail", "thumbnailViewModel")
        let overlays = dig(thumbnail, "overlays") as? [Any] ?? []
        let count = overlays.lazy.compactMap {
            dig($0, "thumbnailOverlayBadgeViewModel", "thumbnailBadges", 0, "thumbnailBadgeViewModel", "text") as? String
        }.first
        return MusicSearchResult(
            id: id,
            kind: .playlist,
            title: dig(metadata, "title", "content") as? String ?? "Playlist",
            channel: dig(metadata, "metadata", "contentMetadataViewModel", "metadataRows", 0,
                         "metadataParts", 0, "text", "content") as? String ?? "",
            detail: count ?? "Playlist",
            thumbnail: (dig(thumbnail, "image", "sources", 0, "url") as? String).flatMap(URL.init(string:)),
            durationSeconds: nil
        )
    }

    /// Follows dictionary keys and array indexes through decoded JSON
    static func dig(_ object: Any?, _ path: Any...) -> Any? {
        path.reduce(object) { current, step in
            if let key = step as? String { return (current as? [String: Any])?[key] }
            if let index = step as? Int, let array = current as? [Any], array.indices.contains(index) { return array[index] }
            return nil
        }
    }

    /// YouTube text is either `simpleText` or a list of styled `runs`
    private static func text(_ object: Any?) -> String {
        if let simple = dig(object, "simpleText") as? String { return simple }
        let runs = dig(object, "runs") as? [Any] ?? []
        return runs.compactMap { dig($0, "text") as? String }.joined()
    }

    private static func seconds(fromClock clock: String) -> Int? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

/// Plays YouTube in a WKWebView whose window is never shown, so the music
/// keeps going while the island is folded away.
// MARK: - YouTube Account

/// Signs in to Google so the station menu can list your own YouTube
/// playlists. Sign-in runs in the system browser sheet with PKCE (no client
/// secret); only the refresh token is kept, in the Keychain. Read-only: Nook
/// never changes anything in the account.
///
/// Needs Nook's Google OAuth client ID ("iOS" type, bundle ID com.nook.app),
/// which build.sh stamps into Info.plist from `NOOK_YOUTUBE_CLIENT_ID`.
final class YouTubeAccount: NSObject, ObservableObject {
    @Published private(set) var isSignedIn: Bool
    /// Liked videos first, then your playlists as YouTube orders them
    @Published private(set) var playlists: [MusicStation] = []

    /// Nook's OAuth client ID, built into the app
    private let clientID: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "NookYouTubeClientID") as? String
        return value?.isEmpty == false ? value : nil
    }()

    /// False in builds made without a client ID, which can't sign in
    var canSignIn: Bool { clientID != nil }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var authSession: ASWebAuthenticationSession?
    private var lastRefresh = Date.distantPast

    private enum Keys {
        static let refreshToken = "youtube.refreshToken"
    }
    private static let scope = "https://www.googleapis.com/auth/youtube.readonly"
    private static let api = "https://www.googleapis.com/youtube/v3/"
    /// The player takes at most this many videos in one playlist
    private static let maxVideos = 200

    override init() {
        isSignedIn = Keychain.read(Keys.refreshToken) != nil
        super.init()
    }

    // MARK: Signing in

    /// Opens Google's sign-in in the browser sheet
    func signIn() {
        guard let clientID = clientID else { return }
        let verifier = Self.randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let scheme = Self.redirectScheme(for: clientID)
        let redirect = scheme + ":/oauth2redirect"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: scheme) { [weak self] url, error in
            Task { @MainActor in
                guard let self = self else { return }
                self.authSession = nil
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin { return }
                guard let url = url,
                      let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value else {
                    self.showError("Google didn't sign you in. \(error?.localizedDescription ?? "")")
                    return
                }
                do {
                    try await self.exchange(code: code, verifier: verifier, redirect: redirect, clientID: clientID)
                    await self.refreshPlaylists(force: true)
                } catch {
                    self.showError((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
        session.presentationContextProvider = self
        authSession = session
        NSApp.activate(ignoringOtherApps: true)
        session.start()
    }

    func signOut() {
        if let token = Keychain.read(Keys.refreshToken) {
            // Best effort: revoke so the grant disappears from the Google account too
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(["token": token])
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.delete(Keys.refreshToken)
        accessToken = nil
        accessTokenExpiry = .distantPast
        playlists = []
        isSignedIn = false
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't connect YouTube"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Tokens

    @MainActor
    private func exchange(code: String, verifier: String, redirect: String, clientID: String) async throws {
        let json = try await Self.postToken([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect
        ])
        guard let refreshToken = json["refresh_token"] as? String else { throw MusicError.signIn }
        Keychain.write(refreshToken, for: Keys.refreshToken)
        store(json)
        isSignedIn = true
    }

    /// A valid access token, refreshed when the old one is about to expire
    @MainActor
    private func validAccessToken() async throws -> String {
        if let token = accessToken, accessTokenExpiry.timeIntervalSinceNow > 60 { return token }
        guard let clientID = clientID, let refreshToken = Keychain.read(Keys.refreshToken) else {
            throw MusicError.signIn
        }
        do {
            let json = try await Self.postToken([
                "client_id": clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token"
            ])
            store(json)
        } catch MusicError.signIn {
            // The grant was revoked or expired: sign out so the menu offers to connect again
            signOut()
            throw MusicError.signIn
        }
        guard let token = accessToken else { throw MusicError.signIn }
        return token
    }

    private func store(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        accessTokenExpiry = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)
    }

    private static func postToken(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MusicError.network
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return json
        case 400, 401: throw MusicError.signIn
        default: throw MusicError.network
        }
    }

    // MARK: Playlists

    /// Reloads the playlist list, at most once a minute unless `force`d
    @MainActor
    func refreshPlaylists(force: Bool = false) async {
        guard isSignedIn, force || Date().timeIntervalSince(lastRefresh) > 60 else { return }
        lastRefresh = Date()
        do {
            var stations: [MusicStation] = []
            let channels = try await get("channels", ["part": "contentDetails", "mine": "true"])
            if let likes = YouTube.dig(channels, "items", 0, "contentDetails", "relatedPlaylists", "likes") as? String {
                stations.append(MusicStation(id: "account.\(likes)", name: "Liked videos", emoji: "♥", source: .accountPlaylist(likes)))
            }
            var pageToken: String?
            repeat {
                var query = ["part": "snippet", "mine": "true", "maxResults": "50"]
                query["pageToken"] = pageToken
                let page = try await get("playlists", query)
                for item in page["items"] as? [[String: Any]] ?? [] {
                    guard let id = item["id"] as? String else { continue }
                    let name = YouTube.dig(item, "snippet", "title") as? String ?? "Playlist"
                    stations.append(MusicStation(id: "account.\(id)", name: name, emoji: "▶", source: .accountPlaylist(id)))
                }
                pageToken = page["nextPageToken"] as? String
            } while pageToken != nil
            playlists = stations
        } catch {
            // Keep the last list; the menu still works with it
            NSLog("Nook: couldn't load YouTube playlists: \(error.localizedDescription)")
        }
    }

    /// The video IDs in one of your playlists, private ones included, in order
    @MainActor
    func videoIDs(in playlistID: String) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var query = ["part": "contentDetails", "playlistId": playlistID, "maxResults": "50"]
            query["pageToken"] = pageToken
            let page = try await get("playlistItems", query)
            for item in page["items"] as? [[String: Any]] ?? [] {
                if let id = YouTube.dig(item, "contentDetails", "videoId") as? String { ids.append(id) }
            }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil && ids.count < Self.maxVideos
        return Array(ids.prefix(Self.maxVideos))
    }

    @MainActor
    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        let token = try await validAccessToken()
        var components = URLComponents(string: Self.api + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MusicError.network
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        case 401: accessToken = nil; throw MusicError.signIn
        case 404: throw MusicError.notFound
        default: throw MusicError.network
        }
    }

    // MARK: Helpers

    /// Google's redirect scheme for an iOS client: the client ID reversed
    private static func redirectScheme(for clientID: String) -> String {
        clientID.split(separator: ".").reversed().joined(separator: ".")
    }

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }
}

extension YouTubeAccount: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Generic passwords in the login keychain, under Nook's own service name
private enum Keychain {
    private static let service = "com.nook.app"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: String) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

final class MusicPlayer: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var station: MusicStation?
    @Published private(set) var status: Status = .idle {
        didSet { if status != oldValue { onChange?() } }
    }
    /// The title of the video playing now, which changes through a playlist
    @Published private(set) var title: String?
    /// The channel of the video playing now
    @Published private(set) var channel: String?
    /// The YouTube ID of the video playing now, for opening it in the browser
    @Published private(set) var videoID: String?
    /// Shown briefly when a station couldn't play and the previous one came back
    @Published private(set) var notice: String?
    @Published private(set) var customStations: [MusicStation] {
        didSet { save(customStations, forKey: Constants.Music.Keys.customStations) }
    }
    /// What played in Nook, newest first: presets, saved stations, search
    /// results and your playlists alike
    @Published private(set) var recentlyPlayed: [MusicStation] {
        didSet { save(recentlyPlayed, forKey: Constants.Music.Keys.recentlyPlayed) }
    }
    @Published var volume: Double {
        didSet {
            defaults.set(volume, forKey: Constants.Music.Keys.volume)
            run("nook.setVolume(\(Int(volume)))", onlyIfReady: true)
        }
    }

    /// Called whenever playback starts or stops, so the menu bar can refresh
    var onChange: (() -> Void)?
    /// Plays your own playlists, when you've connected YouTube
    weak var account: YouTubeAccount?

    var stations: [MusicStation] { MusicStation.presets + customStations }

    /// Playing, or on its way to playing
    var isActive: Bool { status == .playing || status == .loading }

    /// Types like Study play whichever stream tops a search, so once it's
    /// known they're labelled with that video's own title
    var stationTitle: String? {
        guard let station = station else { return nil }
        if case .liveSearch = station.source, let title = title {
            return MusicStation(id: station.id, name: title, emoji: station.emoji, source: station.source).menuTitle
        }
        return station.menuTitle
    }

    /// For a type like Study: the type and the channel, e.g. "Study · Lofi Girl"
    var stationDetail: String? {
        guard let station = station, case .liveSearch = station.source else { return nil }
        return [station.name, channel].compactMap { $0 }.joined(separator: " · ")
    }

    /// A station from search that isn't saved
    var isUnsaved: Bool {
        guard let station = station else { return false }
        return !stations.contains { $0.id == station.id }
    }

    private let defaults = UserDefaults.standard
    private var window: NSWindow?
    private var webView: WKWebView?
    private var isPlayerReady = false
    /// A command sent before the player finished loading
    private var pendingCommand: String?
    private var loadTask: Task<Void, Never>?
    /// What played before the current station; it comes back if the new one can't play
    private var fallback: MusicStation?
    /// Live stream IDs found for presets this session
    private var liveStreams: [String: String] = [:]
    private var noticeWork: DispatchWorkItem?

    override init() {
        defaults.register(defaults: [Constants.Music.Keys.volume: Constants.Music.defaultVolume])
        volume = defaults.double(forKey: Constants.Music.Keys.volume)
        customStations = Self.load([MusicStation].self, forKey: Constants.Music.Keys.customStations) ?? []
        recentlyPlayed = Self.load([MusicStation].self, forKey: Constants.Music.Keys.recentlyPlayed) ?? []
        station = Self.load(MusicStation.self, forKey: Constants.Music.Keys.lastStation) ?? MusicStation.presets[0]
        super.init()
    }

    // MARK: Actions

    func play(_ newStation: MusicStation) {
        if station != newStation, status == .playing || status == .paused {
            fallback = station
        }
        station = newStation
        title = nil
        channel = nil
        videoID = nil
        status = .loading
        save(newStation, forKey: Constants.Music.Keys.lastStation)

        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let item = try await self.playerItem(for: newStation)
                guard !Task.isCancelled, self.station == newStation else { return }
                self.run("nook.load(\(item))")
            } catch {
                guard !Task.isCancelled, self.station == newStation else { return }
                self.couldNotPlay(error)
            }
        }
    }

    func togglePlayPause() {
        switch status {
        case .playing, .loading:
            loadTask?.cancel()
            run("nook.pause()", onlyIfReady: true)
            status = .paused
        case .paused:
            run("nook.play()", onlyIfReady: true)
        case .idle, .failed:
            if let station = station { play(station) }
        }
    }

    func next() { run("nook.next()", onlyIfReady: true) }

    /// Opens the video playing now on youtube.com in the default browser, at
    /// the same moment, and pauses Nook so the two don't play over each other
    func openInBrowser() {
        guard let videoID = videoID else { return }
        let isLive: Bool = {
            if case .liveSearch = station?.source { return true }
            return false
        }()
        let open = { (seconds: Int) in
            var link = "https://www.youtube.com/watch?v=\(videoID)"
            if !isLive, seconds > 0 { link += "&t=\(seconds)s" }
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        if isActive { togglePlayPause() }
        guard isPlayerReady, let webView = webView, !isLive else {
            open(0)
            return
        }
        webView.evaluateJavaScript("player.getCurrentTime()") { result, _ in
            open(Int((result as? Double) ?? 0))
        }
    }
    func previous() { run("nook.previous()", onlyIfReady: true) }

    /// Saves the station playing from search, so it stays in the station list
    func saveCurrentStation() {
        guard let station = station, isUnsaved else { return }
        customStations.append(station)
    }

    func add(_ station: MusicStation) {
        guard !stations.contains(where: { $0.id == station.id }) else { return }
        customStations.append(station)
    }

    func removeCustomStation(_ station: MusicStation) {
        customStations.removeAll { $0.id == station.id }
    }

    func clearRecentlyPlayed() {
        recentlyPlayed = []
    }

    /// Moves `station` to the top of Recently Played once it actually plays
    private func remember(_ station: MusicStation) {
        guard recentlyPlayed.first?.id != station.id else { return }
        var list = recentlyPlayed.filter { $0.id != station.id }
        list.insert(station, at: 0)
        recentlyPlayed = Array(list.prefix(Constants.Music.recentlyPlayedLimit))
    }

    /// Checks a pasted link, saves it as a station and plays it
    func addStation(fromLink link: String) async throws {
        guard let source = MusicStation.source(fromLink: link) else { throw MusicError.badLink }
        let title = try await YouTube.playableTitle(of: source)
        let station = MusicStation.youTube(source, name: title)
        await MainActor.run {
            add(station)
            play(station)
        }
    }

    // MARK: Player

    /// The JS object `nook.load` takes: a video or a playlist to start
    private func playerItem(for station: MusicStation) async throws -> String {
        switch station.source {
        case .video(let id):
            return "{videoId: '\(id)'}"
        case .playlist(let id):
            return "{list: '\(id)'}"
        case .accountPlaylist(let id):
            guard let account = account else { throw MusicError.signIn }
            let ids = try await account.videoIDs(in: id)
            guard !ids.isEmpty else { throw MusicError.emptyPlaylist }
            let list = String(data: try JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
            return "{videos: \(list)}"
        case .liveSearch(let query):
            if let id = liveStreams[query] { return "{videoId: '\(id)'}" }
            guard let stream = try await YouTube.search(query, filter: .live).first(where: { $0.kind == .live }) else {
                throw MusicError.noLiveStream
            }
            await MainActor.run { liveStreams[query] = stream.id }
            return "{videoId: '\(stream.id)'}"
        }
    }

    private func couldNotPlay(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let fallback = fallback, fallback != station {
            let failedName = station?.name ?? "This station"
            self.fallback = nil
            play(fallback)
            show(notice: "Couldn't play “\(failedName)”: \(message)")
        } else {
            status = .failed(message)
        }
    }

    private func show(notice text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notice = nil }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Runs JS in the player, loading the player first if needed. With
    /// `onlyIfReady`, commands are dropped while there's no player to obey them.
    private func run(_ command: String, onlyIfReady: Bool = false) {
        guard isPlayerReady, let webView = webView else {
            guard !onlyIfReady else { return }
            pendingCommand = command
            loadPlayer()
            return
        }
        webView.evaluateJavaScript(command) { _, error in
            if let error = error {
                NSLog("Nook: music command failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadPlayer() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(self, name: "nook")

        let size = Constants.Music.playerSize
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        // Never ordered on screen: playback keeps going while it's hidden
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.window = window
        self.webView = webView
        webView.loadHTMLString(playerHTML, baseURL: URL(string: Constants.Music.origin + "/"))
    }

    private var playerHTML: String {
        let size = Constants.Music.playerSize
        return """
        <!doctype html><html><body style="margin:0;background:#000">
        <div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        const post = message => window.webkit.messageHandlers.nook.postMessage(message);
        let player, fadeTimer, volume = \(Int(volume));

        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            width: \(Int(size.width)), height: \(Int(size.height)),
            playerVars: { autoplay: 1, controls: 0, disablekb: 1, origin: '\(Constants.Music.origin)' },
            events: {
              onReady: () => { player.setVolume(volume); post({ event: 'ready' }); },
              onStateChange: e => post({ event: 'state', state: e.data, title: (player.getVideoData() || {}).title || '', channel: (player.getVideoData() || {}).author || '', videoId: (player.getVideoData() || {}).video_id || '' }),
              onError: e => post({ event: 'error', code: e.data })
            }
          });
        }

        function fade(to, ms, done) {
          clearInterval(fadeTimer);
          const from = player.getVolume(), steps = 10;
          let step = 0;
          fadeTimer = setInterval(() => {
            step++;
            player.setVolume(Math.round(from + (to - from) * step / steps));
            if (step >= steps) { clearInterval(fadeTimer); done(); }
          }, ms / steps);
        }

        window.nook = {
          load(item) {
            const start = () => {
              if (item.videos) { player.loadPlaylist(item.videos); }
              else if (item.list) { player.loadPlaylist({ list: item.list, listType: 'playlist' }); }
              else { player.loadVideoById(item.videoId); }
              player.setVolume(volume);
            };
            if (player.getPlayerState() === YT.PlayerState.PLAYING) { fade(0, \(Constants.Music.fadeMilliseconds), start); }
            else { start(); }
          },
          play() { player.playVideo(); },
          pause() { clearInterval(fadeTimer); player.pauseVideo(); },
          next() { player.nextVideo(); },
          previous() { player.previousVideo(); },
          setVolume(value) { volume = value; clearInterval(fadeTimer); player.setVolume(value); }
        };
        </script></body></html>
        """
    }

    private func handle(event: [String: Any]) {
        switch event["event"] as? String {
        case "ready":
            isPlayerReady = true
            if let command = pendingCommand {
                pendingCommand = nil
                run(command)
            }
        case "state":
            if let newTitle = event["title"] as? String, !newTitle.isEmpty {
                title = newTitle
            }
            if let newChannel = event["channel"] as? String, !newChannel.isEmpty {
                channel = newChannel
            }
            if let newVideoID = event["videoId"] as? String, !newVideoID.isEmpty {
                videoID = newVideoID
            }
            // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
            switch event["state"] as? Int {
            case 1:
                status = .playing
                fallback = nil
                if let station = station { remember(station) }
            case 0, 2, 5:
                if status != .loading || event["state"] as? Int == 0 { status = .paused }
            case 3, -1:
                if status != .paused { status = .loading }
            default:
                break
            }
        case "error":
            couldNotPlay(MusicError.player(event["code"] as? Int ?? 0))
        default:
            break
        }
    }

    // MARK: Saving

    private func save<Value: Encodable>(_ value: Value, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension MusicPlayer: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let event = message.body as? [String: Any] else { return }
        handle(event: event)
    }
}

/// The YouTube search shown in the island: results as you type, picked with
/// the arrow keys and played with Return.
final class MusicSearch: ObservableObject {
    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published var filter: MusicSearchFilter = .all {
        didSet { if filter != oldValue { scheduleSearch(after: 0) } }
    }
    @Published private(set) var results: [MusicSearchResult] = []
    @Published var selection = 0
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    /// Results that turned out not to play outside YouTube
    @Published private(set) var unplayable: [String: String] = [:]
    /// The result being checked before it plays
    @Published private(set) var checkingID: String?
    @Published private(set) var recentSearches: [String]

    private let player: MusicPlayer
    private var searchTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?

    init(player: MusicPlayer) {
        self.player = player
        recentSearches = UserDefaults.standard.stringArray(forKey: Constants.Music.Keys.recentSearches) ?? []
    }

    func present() {
        isPresented = true
        selection = 0
    }

    func dismiss() {
        isPresented = false
        searchTask?.cancel()
        playTask?.cancel()
        isSearching = false
        checkingID = nil
    }

    func playSelected(saving: Bool) {
        guard results.indices.contains(selection) else { return }
        play(results[selection], saving: saving)
    }

    /// Checks the result can play outside YouTube first, so a dud never
    /// interrupts what's playing now
    func play(_ result: MusicSearchResult, saving: Bool) {
        guard unplayable[result.id] == nil else { return }
        checkingID = result.id
        playTask?.cancel()
        playTask = Task { @MainActor [weak self] in
            do {
                _ = try await YouTube.playableTitle(of: result.station.source)
                guard let self = self, !Task.isCancelled else { return }
                self.checkingID = nil
                if saving { self.player.add(result.station) }
                self.player.play(result.station)
                self.remember(self.query)
                self.dismiss()
            } catch {
                guard let self = self, !Task.isCancelled else { return }
                self.checkingID = nil
                self.unplayable[result.id] = (error as? LocalizedError)?.errorDescription ?? "Can't play this"
            }
        }
    }

    /// Arrow keys, Return and Esc while the search is open. Returns false for
    /// keys the text field should get.
    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case Constants.Island.escapeKeyCode:
            dismiss()
        case 125: // down
            if !results.isEmpty { selection = min(selection + 1, results.count - 1) }
        case 126: // up
            selection = max(selection - 1, 0)
        case 36, 76: // return, keypad enter
            playSelected(saving: event.modifierFlags.contains(.command))
        default:
            return false
        }
        return true
    }

    private func scheduleSearch(after delay: TimeInterval = Constants.Music.searchDebounce) {
        searchTask?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            results = []
            isSearching = false
            errorMessage = nil
            return
        }
        let filter = self.filter
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                let results = try await YouTube.search(query, filter: filter)
                guard let self = self, !Task.isCancelled else { return }
                self.results = results
                self.selection = 0
                self.errorMessage = results.isEmpty ? "No results" : nil
            } catch {
                guard let self = self, !Task.isCancelled else { return }
                self.results = []
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Search failed"
            }
            self?.isSearching = false
        }
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Constants.Music.Keys.recentSearches)
    }

    private func remember(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(Constants.Music.recentSearchLimit))
        UserDefaults.standard.set(recentSearches, forKey: Constants.Music.Keys.recentSearches)
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
    var island: IslandController!
    var timer: Timer?
    @Published var shutdownDate: Date?
    var highlightView: NSView?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    /// A separate menu bar button, shown only while recording, that stops it in one click
    private var stopRecordingItem: NSStatusItem?
    private var stopRecordingTimer: Timer?
    let pomodoro = Pomodoro()
    let screenRecorder = ScreenRecorder()
    let bluetooth = BluetoothManager()
    let systemMonitor = SystemMonitor()
    let music = MusicPlayer()
    let youTubeAccount = YouTubeAccount()
    lazy var musicSearch = MusicSearch(player: music)

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNotificationPermissions()
        setupStatusBar()
        setupIsland()
        pomodoro.onChange = { [weak self] in
            self?.updateStatusItem()
        }
        screenRecorder.onChange = { [weak self] in
            self?.updateStatusItem()
            self?.updateStopRecordingItem()
        }
        music.onChange = { [weak self] in
            self?.updateStatusItem()
        }
        music.account = youTubeAccount
        Task { await youTubeAccount.refreshPlaylists() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting would lose an unsaved recording, so offer to save it first
        guard screenRecorder.hasUnsavedRecording else { return .terminateNow }
        afterClosingIsland { [weak self] in
            self?.screenRecorder.save {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func startRecording() {
        // Close the island so it isn't in the way of what's being recorded
        closeIsland()
        screenRecorder.start()
    }

    func resumeRecording() {
        closeIsland()
        screenRecorder.resume()
    }

    func saveRecording() {
        afterClosingIsland { [weak self] in
            self?.screenRecorder.save()
        }
    }

    func discardRecording() {
        afterClosingIsland { [weak self] in
            self?.screenRecorder.discard()
        }
    }

    /// Stops the recording from the menu bar, then opens the island so the
    /// user can resume, save or discard it.
    @objc private func stopRecordingFromMenuBar() {
        screenRecorder.pause { [weak self] in
            guard let self = self, self.screenRecorder.isPaused, !self.island.isShown else { return }
            self.toggleIsland()
        }
    }

    private func updateStopRecordingItem() {
        guard screenRecorder.state == .recording else {
            stopRecordingTimer?.invalidate()
            stopRecordingTimer = nil
            if let item = stopRecordingItem {
                NSStatusBar.system.removeStatusItem(item)
                stopRecordingItem = nil
            }
            return
        }
        guard stopRecordingItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop Recording")?
                .withSymbolConfiguration(config)
            button.contentTintColor = .systemRed
            button.imagePosition = .imageLeading
            button.toolTip = "Stop Recording"
            button.target = self
            button.action = #selector(stopRecordingFromMenuBar)
        }
        stopRecordingItem = item
        refreshStopRecordingTitle()

        let timer = Timer(timeInterval: Constants.Time.updateInterval, repeats: true) { [weak self] _ in
            self?.refreshStopRecordingTitle()
        }
        // .common keeps the timer ticking while a menu is open
        RunLoop.main.add(timer, forMode: .common)
        stopRecordingTimer = timer
    }

    private func refreshStopRecordingTitle() {
        guard let button = stopRecordingItem?.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.attributedTitle = NSAttributedString(
            string: " " + TimeRemaining(from: screenRecorder.elapsed).clockFormat,
            attributes: [.font: font]
        )
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerPomodoroCategory()
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
        button.action = #selector(statusItemClicked)
        button.target = self
        // Right-click opens the music menu; left-click toggles the island
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        // An accessibility press has no event of its own, so a right-click
        // from earlier would still be current: only trust a fresh one
        if let event = NSApp.currentEvent, event.type == .rightMouseUp,
           ProcessInfo.processInfo.systemUptime - event.timestamp < 1 {
            showMusicMenu()
        } else {
            toggleIsland()
        }
    }

    /// Switch music without opening the island
    private func showMusicMenu() {
        let menu = musicMenu()
        // Showing a menu from a status item means attaching it for one click
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// The station menu, shared by the menu bar icon and the Music tile. The
    /// tile passes `onAddLink` to also offer adding and removing stations.
    func musicMenu(onAddLink: (() -> Void)? = nil) -> NSMenu {
        let menu = NSMenu()
        if let station = music.station {
            let nowPlaying = music.title ?? station.name
            let heading = NSMenuItem(title: nowPlaying.count > 52 ? nowPlaying.prefix(51) + "…" : nowPlaying,
                                     action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
        }
        menu.addItem(ClosureMenuItem(title: music.isActive ? "Pause" : "Play") { [weak self] in
            self?.music.togglePlayPause()
        })
        if music.station?.isPlaylist == true {
            menu.addItem(ClosureMenuItem(title: "Next") { [weak self] in self?.music.next() })
        }
        if music.videoID != nil {
            menu.addItem(ClosureMenuItem(title: "Open in YouTube") { [weak self] in
                self?.afterClosingIsland { self?.music.openInBrowser() }
            })
        }
        menu.addItem(.separator())
        for station in music.stations {
            let item = ClosureMenuItem(title: station.menuTitle) { [weak self] in self?.music.play(station) }
            item.state = station.id == music.station?.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addRecentlyPlayedItems(to: menu)
        addYouTubeAccountItems(to: menu)
        menu.addItem(ClosureMenuItem(title: "Search YouTube…") { [weak self] in
            guard let self = self else { return }
            if !self.island.isShown { self.toggleIsland() }
            self.musicSearch.present()
        })
        if let onAddLink = onAddLink {
            menu.addItem(ClosureMenuItem(title: "Add from YouTube Link…", handler: onAddLink))
            if !music.customStations.isEmpty {
                let remove = NSMenuItem(title: "Remove Station", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for station in music.customStations {
                    submenu.addItem(ClosureMenuItem(title: station.menuTitle) { [weak self] in
                        self?.music.removeCustomStation(station)
                    })
                }
                remove.submenu = submenu
                menu.addItem(remove)
            }
        }
        return menu
    }

    /// The last stations played, as a submenu so the main menu stays short
    private func addRecentlyPlayedItems(to menu: NSMenu) {
        guard !music.recentlyPlayed.isEmpty else { return }
        let recent = NSMenuItem(title: "Recently Played", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for station in music.recentlyPlayed {
            let item = ClosureMenuItem(title: station.menuTitle) { [weak self] in self?.music.play(station) }
            item.state = station.id == music.station?.id ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(title: "Clear Recently Played") { [weak self] in
            self?.music.clearRecentlyPlayed()
        })
        recent.submenu = submenu
        menu.addItem(recent)
        menu.addItem(.separator())
    }

    /// Your own playlists, or the item that connects your YouTube account
    private func addYouTubeAccountItems(to menu: NSMenu) {
        let account = youTubeAccount
        guard account.canSignIn else { return }
        guard account.isSignedIn else {
            menu.addItem(ClosureMenuItem(title: "Connect YouTube Account…") { [weak self] in
                self?.afterClosingIsland { account.signIn() }
            })
            menu.addItem(.separator())
            return
        }
        // Picks up playlists made since the last look; shows next time the menu opens
        Task { await account.refreshPlaylists() }

        let heading = NSMenuItem(title: "Your Playlists", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        if account.playlists.isEmpty {
            let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
        }
        for station in account.playlists {
            let item = ClosureMenuItem(title: station.menuTitle) { [weak self] in self?.music.play(station) }
            item.state = station.id == music.station?.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(ClosureMenuItem(title: "Disconnect YouTube Account") {
            account.signOut()
        })
        menu.addItem(.separator())
    }

    private func setupIsland() {
        island = IslandController(content: ContentView(appDelegate: self, pomodoro: pomodoro, screenRecorder: screenRecorder, bluetooth: bluetooth, system: systemMonitor, music: music, musicSearch: musicSearch))
        island.onDismiss = { [weak self] in
            self?.closeIsland()
        }
    }

    @objc func toggleIsland() {
        if island.isShown {
            closeIsland()
            return
        }
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        // A menu-bar-only app isn't active by default, so activate it for the
        // island to take key presses (Esc closes it)
        NSApp.activate(ignoringOtherApps: true)
        island.show(on: screen)
        systemMonitor.isIslandShown = true
        addHighlight()
        startOutsideClickMonitor()
        startEscapeMonitor()
        // Battery levels and connections change while the island is closed.
        // Refresh once it's opening so the work never delays it appearing.
        DispatchQueue.main.async { [weak self] in
            self?.bluetooth.refresh()
        }
    }

    /// Closes the island, then runs `action` once it has folded away. The
    /// island floats at the menu bar's level, above alerts and save panels,
    /// so anything `action` opens would otherwise appear behind it.
    func afterClosingIsland(_ action: @escaping () -> Void) {
        guard island.isShown else {
            action()
            return
        }
        closeIsland()
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Island.closeDuration, execute: action)
    }

    func closeIsland() {
        guard island.isShown else { return }
        musicSearch.dismiss()
        island.hide()
        systemMonitor.isIslandShown = false
        removeHighlight()
        stopOutsideClickMonitor()
        stopEscapeMonitor()
    }

    // Clicks in other apps close the island; clicks on the menu bar icon toggle it
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeIsland()
        }
    }

    private func startEscapeMonitor() {
        stopEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // The music search takes Esc (back to the tiles), arrows and Return
            if self.musicSearch.isPresented {
                return self.musicSearch.handle(event) ? nil : event
            }
            guard event.keyCode == Constants.Island.escapeKeyCode else { return event }
            self.closeIsland()
            return nil
        }
    }

    private func stopEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
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
        // Follow the button if its size changes while the island is open
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
        // the countdowns live in the island
        guard let button = statusItem.button else { return }
        let image: NSImage?
        if screenRecorder.isRecording {
            // Recording takes priority so it's always obvious the screen is being captured
            image = StatusIcon.recording
        } else if screenRecorder.isPaused {
            image = StatusIcon.recordingPaused
        } else if pomodoro.isOnBreak {
            // Break state takes priority while a break is running
            image = StatusIcon.onBreak
        } else if shutdownDate != nil {
            image = StatusIcon.shutdown
        } else if music.isActive {
            image = StatusIcon.music
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

/// A menu item that runs a closure, for menus built on the fly
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
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
            guard let pomodoro = self?.pomodoro else { return }
            switch action {
            case Constants.Pomodoro.Action.start:
                pomodoro.startBreak()
            case Constants.Pomodoro.Action.snooze:
                pomodoro.snooze()
            case Constants.Pomodoro.Action.skip:
                pomodoro.skipBreak()
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
    @ObservedObject var pomodoro: Pomodoro
    @ObservedObject var screenRecorder: ScreenRecorder
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var system: SystemMonitor
    @ObservedObject var music: MusicPlayer
    @ObservedObject var musicSearch: MusicSearch
    @State private var shutdownMinutes = Constants.Shutdown.defaultMinutes
    @State private var showsAllDevices = false
    @State private var showsSystem = false
    /// The link field shown in the Music tile, nil when it's closed
    @State private var musicLink: String?
    @State private var musicLinkError: String?
    @State private var isAddingMusicLink = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: Constants.UI.gridSpacing) {
            headerView
            if showsSystem {
                systemView
            } else if musicSearch.isPresented {
                tile(musicSearchView)
            } else {
                // Two columns of tiles keep the island short enough to fit on screen
                HStack(alignment: .top, spacing: Constants.UI.gridSpacing) {
                    VStack(spacing: Constants.UI.gridSpacing) {
                        tile(pomodoroView)
                        tile(powerOffView)
                    }
                    VStack(spacing: Constants.UI.gridSpacing) {
                        tile(musicView)
                        tile(screenRecordingView)
                        tile(bluetoothView)
                    }
                }
            }
        }
        .padding(.horizontal, Constants.UI.gridPadding)
        .padding(.bottom, Constants.UI.gridPadding)
        .frame(width: Constants.UI.panelWidth)
    }

    private func tile<Content: View>(_ content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Constants.UI.tileCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(nsImage: NookGlyph.image)
                .renderingMode(.template)
                .resizable()
                .frame(width: 20, height: 20)
            Text(showsSystem ? "System" : "Nook")
                .font(.headline)
            Spacer()
            Button(action: { setShowsSystem(!showsSystem) }) {
                HStack(spacing: 4) {
                    Image(systemName: showsSystem ? "square.grid.2x2" : "cpu")
                    Text(showsSystem ? "Utilities" : "System")
                }
                .font(.caption)
                .foregroundColor(showsSystem ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(CustomPlainButtonStyle())
            .clipShape(Capsule())
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("Quit")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(CustomPlainButtonStyle())
            .clipShape(Capsule())
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
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
                HStack(alignment: .center, spacing: 12) {
                    TickRuler(
                        value: $shutdownMinutes,
                        range: Constants.Shutdown.minMinutes...Constants.Shutdown.maxMinutes,
                        step: Constants.Shutdown.stepMinutes,
                        labelEvery: Constants.Shutdown.labelEveryMinutes,
                        tint: Constants.Shutdown.tint
                    )
                    Spacer(minLength: 0)
                    Text(TimeRemaining(from: TimeInterval(shutdownMinutes * Constants.Time.secondsPerMinute)).clockFormat)
                        .font(.system(size: 24, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Constants.Shutdown.tint)
                        // Shrink rather than wrap once it reaches hours ("2:00:00")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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

    // MARK: Pomodoro

    private var pomodoroView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Only the card redraws each second, not the whole island
            TimelineView(.periodic(from: .now, by: Constants.Time.updateInterval)) { _ in
                pomodoroCard
            }

            settingRow("Focus") {
                minuteStepper($pomodoro.intervalMinutes, in: Constants.Pomodoro.minIntervalMinutes...Constants.Pomodoro.maxIntervalMinutes)
            }

            settingRow("Break") {
                SegmentedPicker(selection: $pomodoro.durationSeconds, options: Constants.Pomodoro.durationOptions) { seconds in
                    shortDurationText(seconds)
                }
            }

            settingRow("Style") {
                SegmentedPicker(selection: $pomodoro.mode, options: Array(BreakMode.allCases)) { mode in
                    mode.title
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var pomodoroCard: some View {
        let theme = PomodoroTheme(phase: pomodoro.phase)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("🍅")
                Text("Pomodoro")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                if pomodoro.isEnabled {
                    Button(action: { pomodoro.isEnabled = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.2)))
                    }
                    .buttonStyle(PillButtonStyle())
                    .help("Turn off Pomodoro")
                }
            }

            if pomodoro.isEnabled {
                pomodoroActiveBody(theme: theme)
            } else {
                pomodoroIdleBody(theme: theme)
            }
        }
        .foregroundColor(.white)
        .padding(14)
        .background(theme.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: theme.colors[0].opacity(0.35), radius: 8, y: 3)
    }

    private func pomodoroIdleBody(theme: PomodoroTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Focus in sprints, rest in between.")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(pomodoro.intervalMinutes) min focus · \(Pomodoro.durationText(pomodoro.durationSeconds)) break")
                    .font(.caption)
                    .opacity(0.85)
            }
            pomodoroPill("Start focusing", systemImage: "play.fill", theme: theme, prominent: true) {
                pomodoro.isEnabled = true
            }
        }
    }

    private func pomodoroActiveBody(theme: PomodoroTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                pomodoroRing(theme: theme)

                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.label)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(1.5)
                        .opacity(0.85)
                    Text(pomodoro.timeRemaining.map { TimeRemaining(from: $0).clockFormat } ?? "––:––")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(pomodoroSubtitle)
                        .font(.caption)
                        .opacity(0.85)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            switch pomodoro.phase {
            case .focusing:
                pomodoroPill("Break now", systemImage: "cup.and.saucer.fill", theme: theme, prominent: true, action: pomodoro.startBreak)
            case .onBreak:
                HStack(spacing: 8) {
                    pomodoroPill("Snooze \(Constants.Pomodoro.snoozeMinutes)m", systemImage: "moon.zzz.fill", theme: theme, prominent: false, action: pomodoro.snooze)
                    pomodoroPill("Back to focus", systemImage: "bolt.fill", theme: theme, prominent: true, action: pomodoro.skipBreak)
                }
            case .paused, .off:
                EmptyView()
            }
        }
    }

    private var pomodoroSubtitle: String {
        switch pomodoro.phase {
        case .focusing:
            return "then a \(Pomodoro.durationText(pomodoro.durationSeconds)) break"
        case .onBreak:
            return "Look away, stretch, breathe"
        case .paused:
            return "While your Mac is locked or asleep"
        case .off:
            return ""
        }
    }

    private func pomodoroRing(theme: PomodoroTheme) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 5)
            Circle()
                .trim(from: 0, to: pomodoro.progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // No animation between ticks: each second moves the ring a
                // fraction of a point, and a one-second animation restarted
                // every second would redraw the island on every frame.
            Image(systemName: theme.symbol)
                .font(.system(size: 18, weight: .semibold))
        }
        .frame(width: 58, height: 58)
    }

    private func pomodoroPill(_ title: String, systemImage: String, theme: PomodoroTheme, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(prominent ? theme.colors[0] : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(prominent ? 0.95 : 0.2)))
        }
        .buttonStyle(PillButtonStyle())
    }

    // MARK: Screen Recording

    private var screenRecordingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Screen Recording", systemImage: "record.circle")
                .frame(minHeight: 20)

            if ScreenRecorder.isSupported {
                if screenRecorder.state == .idle {
                    recordingOptionsView
                }

                if screenRecorder.isPaused, let error = screenRecorder.errorMessage {
                    statusRow(icon: "exclamationmark.triangle", text: error)
                }

                TimelineView(.periodic(from: .now, by: Constants.Time.updateInterval)) { _ in
                    recordingStatusView
                }
            } else {
                statusRow(icon: "exclamationmark.triangle", text: "Needs macOS 15 or later")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var recordingOptionsView: some View {
        settingRow("Source") {
            SegmentedPicker(selection: $screenRecorder.source, options: Array(RecordingSource.allCases)) { source in
                source.title
            }
        }

        if screenRecorder.source == .screen, screenRecorder.displays.count > 1 {
            settingRow("Screen") {
                Picker("", selection: $screenRecorder.selectedDisplayID) {
                    ForEach(screenRecorder.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
        }

        settingRow("Audio") {
            Toggle("System", isOn: $screenRecorder.capturesSystemAudio)
            Toggle("Microphone", isOn: $screenRecorder.capturesMicrophone)
            Spacer()
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    @ViewBuilder
    private var recordingStatusView: some View {
        let elapsed = TimeRemaining(from: screenRecorder.elapsed).clockFormat
        switch screenRecorder.state {
        case .recording:
            statusRow(
                icon: "record.circle.fill",
                text: "Recording · \(elapsed)",
                actionTitle: "Stop",
                action: { screenRecorder.pause() }
            )
        case .paused:
            statusRow(
                icon: "pause.circle.fill",
                text: "Stopped · \(elapsed)",
                actions: [
                    ("Resume", appDelegate.resumeRecording),
                    ("Save", appDelegate.saveRecording),
                    ("Discard", appDelegate.discardRecording)
                ]
            )
        case .selectingArea:
            statusRow(icon: "crop", text: "Drag to select an area · Esc to cancel")
        case .starting:
            statusRow(icon: "hourglass", text: "Starting…")
        case .pausing:
            statusRow(icon: "hourglass", text: "Stopping…")
        case .saving:
            statusRow(icon: "hourglass", text: "Saving…")
        case .idle:
            if let error = screenRecorder.errorMessage {
                statusRow(
                    icon: "exclamationmark.triangle",
                    text: error,
                    actionTitle: screenRecorder.needsPrivacySettings ? "Settings" : "Retry",
                    action: screenRecorder.needsPrivacySettings ? screenRecorder.openPrivacySettings : appDelegate.startRecording
                )
            } else {
                statusRow(
                    icon: recordingSourceIcon,
                    text: recordingSourceText,
                    actionTitle: "Record",
                    action: appDelegate.startRecording
                )
            }
        }
    }

    private var recordingSourceIcon: String {
        switch screenRecorder.source {
        case .screen: return "display"
        case .allScreens: return "display.2"
        case .area: return "crop"
        }
    }

    private var recordingSourceText: String {
        switch screenRecorder.source {
        case .screen:
            return screenRecorder.selectedDisplayName
        case .allScreens:
            let count = screenRecorder.displays.count
            return count > 1 ? "\(count) screens side by side" : "Only one screen connected"
        case .area:
            return "Drag to pick the area after Record"
        }
    }

    // MARK: Bluetooth

    private var bluetoothView: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                .frame(minHeight: 20)

            switch bluetooth.availability {
            case .loading:
                statusRow(icon: "hourglass", text: "Looking for devices…")
            case .unauthorized:
                statusRow(
                    icon: "exclamationmark.triangle",
                    text: "Allow Nook under Bluetooth in Privacy settings",
                    actionTitle: "Settings",
                    action: bluetooth.openSettings
                )
            case .poweredOff:
                statusRow(icon: "slash.circle", text: "Bluetooth is off", actionTitle: "Settings", action: bluetooth.openSettings)
            case .ready:
                if bluetooth.devices.isEmpty {
                    statusRow(icon: "dot.radiowaves.left.and.right", text: "No paired devices", actionTitle: "Settings", action: bluetooth.openSettings)
                } else {
                    deviceList
                }
            }

            if let error = bluetooth.errorMessage {
                statusRow(icon: "exclamationmark.triangle", text: error)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private var deviceList: some View {
        let devices = bluetooth.devices
        let collapsedCount = Constants.Bluetooth.collapsedCount
        let visible = showsAllDevices ? devices : Array(devices.prefix(collapsedCount))

        return VStack(spacing: 4) {
            ForEach(visible) { device in
                deviceRow(device)
            }

            if devices.count > collapsedCount {
                Button(action: { showsAllDevices.toggle() }) {
                    Text(showsAllDevices ? "Show less" : "Show all \(devices.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(CustomPlainButtonStyle())
                .cornerRadius(5)
            }
        }
    }

    private func deviceRow(_ device: BluetoothDeviceInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: device.icon)
                .frame(width: 18)
                .foregroundColor(device.isConnected ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(deviceSubtitle(device))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            // The subtitle truncates when every battery level is shown, so hovering reveals it in full
            .contentShape(Rectangle())
            .help("\(device.name)\n\(deviceSubtitle(device))")

            Spacer(minLength: 4)

            if bluetooth.busyDevices.contains(device.id) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 8)
            } else {
                Button(action: { bluetooth.toggleConnection(device) }) {
                    Text(device.isConnected ? "Disconnect" : "Connect")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(CustomPlainButtonStyle())
                .cornerRadius(5)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(device.isConnected ? 0.1 : 0.05))
        .cornerRadius(8)
    }

    private func deviceSubtitle(_ device: BluetoothDeviceInfo) -> String {
        guard device.isConnected else { return "Not connected" }
        guard let battery = device.battery else { return "Connected" }
        return "Connected · \(battery)"
    }

    // MARK: Music

    private var musicView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Music", systemImage: "music.note")
                Spacer()
                Button(action: { appDelegate.afterClosingIsland(music.openInBrowser) }) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(CustomPlainButtonStyle())
                .cornerRadius(5)
                .disabled(music.videoID == nil)
                .opacity(music.videoID == nil ? 0.35 : 1)
                .accessibilityLabel("Open in YouTube")
                Button(action: musicSearch.present) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(CustomPlainButtonStyle())
                .cornerRadius(5)
                .accessibilityLabel("Search YouTube")
            }
            .frame(minHeight: 20)

            HStack(spacing: 8) {
                stationMenu
                Spacer(minLength: 4)
                musicTransport
            }

            if musicLink != nil {
                musicLinkField
            } else if let notice = music.notice {
                statusRow(icon: "exclamationmark.triangle", text: notice)
            } else {
                // Song titles can be long; one line keeps the tile from jumping
                musicStatusRow
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Slider(value: $music.volume, in: 0...100)
                    .controlSize(.small)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    /// A plain button opening an AppKit menu. SwiftUI's `Menu` is backed by a
    /// pop-up button that kept re-laying out the hidden island with long titles.
    private var stationMenu: some View {
        Button(action: {
            appDelegate.musicMenu(onAddLink: startAddingMusicLink)
                .popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }) {
            HStack(spacing: 4) {
                Text(music.stationTitle ?? "Choose a station")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .buttonStyle(CustomPlainButtonStyle())
        .cornerRadius(5)
        .frame(width: 190, alignment: .leading)
    }

    private var musicTransport: some View {
        let canSkip = music.station?.isPlaylist == true && music.status != .idle
        return HStack(spacing: 2) {
            musicButton("backward.fill", label: "Previous", enabled: canSkip, action: music.previous)
            musicButton(music.isActive ? "pause.fill" : "play.fill", label: music.isActive ? "Pause" : "Play",
                        enabled: music.station != nil, action: music.togglePlayPause)
            musicButton("forward.fill", label: "Next", enabled: canSkip, action: music.next)
        }
    }

    private func musicButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(CustomPlainButtonStyle())
        .cornerRadius(5)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var musicStatusRow: some View {
        switch music.status {
        case .failed(let message):
            statusRow(icon: "exclamationmark.triangle", text: message, actionTitle: "Retry", action: music.togglePlayPause)
        case .loading:
            // Buffering after a song had started usually means the network dropped
            statusRow(icon: "hourglass", text: music.title == nil ? "Loading…" : "Reconnecting…")
        case .idle:
            statusRow(icon: "music.note", text: "Press play for \(music.station?.name ?? "music")")
        case .playing, .paused:
            if music.isUnsaved {
                statusRow(icon: "magnifyingglass", text: music.title ?? "From search",
                          actionTitle: "☆ Save", action: music.saveCurrentStation)
            } else {
                statusRow(icon: music.status == .playing ? "waveform" : "pause.circle",
                          text: music.stationDetail ?? music.title ?? "…")
            }
        }
    }

    private var musicLinkField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Paste a YouTube link", text: Binding(
                    get: { musicLink ?? "" },
                    set: { musicLink = $0; musicLinkError = nil }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(addMusicLink)

                if isAddingMusicLink {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add", action: addMusicLink)
                        .controlSize(.small)
                        .disabled((musicLink ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button(action: { musicLink = nil; musicLinkError = nil }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(IconButtonStyle())
            }
            if let error = musicLinkError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private func startAddingMusicLink() {
        // Start from a YouTube link on the clipboard, if there is one
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        musicLink = MusicStation.source(fromLink: clipboard) == nil ? "" : clipboard
        musicLinkError = nil
    }

    private func addMusicLink() {
        guard let link = musicLink, !isAddingMusicLink else { return }
        isAddingMusicLink = true
        Task { @MainActor in
            do {
                try await music.addStation(fromLink: link)
                musicLink = nil
            } catch {
                musicLinkError = (error as? LocalizedError)?.errorDescription ?? "Couldn't add this link"
            }
            isAddingMusicLink = false
        }
    }

    // MARK: Music Search

    private var musicSearchView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search YouTube", text: $musicSearch.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isSearchFieldFocused)
                if musicSearch.isSearching {
                    ProgressView().controlSize(.small)
                }
                Button(action: musicSearch.dismiss) {
                    Text("Esc")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(CustomPlainButtonStyle())
                .cornerRadius(5)
            }
            .padding(10)
            .background(Color.white.opacity(0.08))
            .cornerRadius(10)

            SegmentedPicker(selection: $musicSearch.filter, options: MusicSearchFilter.allCases) { $0.title }

            if musicSearch.query.trimmingCharacters(in: .whitespaces).isEmpty {
                recentSearchesView
            } else if let error = musicSearch.errorMessage, musicSearch.results.isEmpty {
                statusRow(icon: "exclamationmark.triangle", text: error)
            } else {
                searchResultsList
            }

            Text("↑↓ select · ⏎ play now · ⌘⏎ play and save · Esc back")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .onAppear {
            // The island has to finish becoming key before the field can focus
            DispatchQueue.main.async { isSearchFieldFocused = true }
        }
    }

    @ViewBuilder
    private var recentSearchesView: some View {
        if musicSearch.recentSearches.isEmpty {
            statusRow(icon: "music.note.list", text: "Try “lofi”, “rain sounds” or “piano for sleep”")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Recent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: musicSearch.clearRecentSearches) {
                        Text("Clear")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(CustomPlainButtonStyle())
                    .cornerRadius(5)
                }
                ForEach(musicSearch.recentSearches, id: \.self) { recent in
                    Button(action: { musicSearch.query = recent }) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text(recent)
                            Spacer()
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(CustomPlainButtonStyle())
                    .cornerRadius(6)
                }
            }
        }
    }

    private var searchResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(musicSearch.results.enumerated()), id: \.element.id) { index, result in
                        searchResultRow(result, isSelected: index == musicSearch.selection)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture { musicSearch.play(result, saving: false) }
                            .onHover { if $0 { musicSearch.selection = index } }
                    }
                }
            }
            .frame(height: 380)
            .onChange(of: musicSearch.selection) { selection in
                guard musicSearch.results.indices.contains(selection) else { return }
                proxy.scrollTo(musicSearch.results[selection].id)
            }
        }
    }

    private func searchResultRow(_ result: MusicSearchResult, isSelected: Bool) -> some View {
        let problem = musicSearch.unplayable[result.id]
        return HStack(spacing: 10) {
            AsyncImage(url: result.thumbnail) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.08)
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(problem ?? result.channel)
                    .font(.caption)
                    .foregroundColor(problem == nil ? .secondary : .orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if musicSearch.checkingID == result.id {
                ProgressView().controlSize(.small)
            } else {
                searchResultBadge(result)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(isSelected ? 0.14 : 0))
        .cornerRadius(8)
        .opacity(problem == nil ? 1 : 0.5)
    }

    private func searchResultBadge(_ result: MusicSearchResult) -> some View {
        let isLive = result.kind == .live
        return HStack(spacing: 4) {
            if isLive {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            } else if result.kind == .playlist {
                Image(systemName: "music.note.list")
            }
            Text(result.detail)
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundColor(isLive ? .red : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    // MARK: System

    private func setShowsSystem(_ shows: Bool) {
        showsSystem = shows
        system.isPageShown = shows
    }

    private var systemView: some View {
        let stats = system.stats
        return VStack(spacing: Constants.UI.gridSpacing) {
            systemRow {
                metricTile("CPU", systemImage: "cpu", value: percentText(stats.cpu), fraction: stats.cpu)
                metricTile("GPU", systemImage: "display", value: percentText(stats.gpu), fraction: stats.gpu)
                metricTile(
                    "Memory", systemImage: "memorychip", value: percentText(stats.memory),
                    detail: "\(byteText(Int64(stats.memoryUsed))) of \(byteText(Int64(stats.memoryTotal)))",
                    fraction: stats.memory
                )
            }
            systemRow {
                metricTile(
                    "Battery", systemImage: batterySymbol(stats.battery),
                    value: percentText(stats.battery?.level), detail: batteryDetail(stats.battery),
                    fraction: stats.battery?.level, highIsBad: false
                )
                metricTile(
                    "Network", systemImage: "network",
                    value: "↓ \(rateText(stats.download))", detail: "↑ \(rateText(stats.upload))"
                )
            }
            systemRow {
                metricTile(
                    "Available", systemImage: "internaldrive",
                    value: stats.diskAvailable.map(byteText) ?? "–",
                    detail: stats.diskTotal.map { "of \(byteText($0))" },
                    fraction: diskUsedFraction(stats)
                )
                metricTile(
                    "Power", systemImage: "powerplug",
                    value: stats.systemPower.map { String(format: "%.0f W", $0) } ?? "–",
                    detail: stats.adapterWatts.map { "\($0) W adapter" } ?? (stats.battery.map { $0.isOnAC ? "On power" : "On battery" })
                )
            }
        }
    }

    /// Tiles side by side, all as tall as the tallest
    private func systemRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Constants.UI.gridSpacing) {
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func metricTile(
        _ title: String, systemImage: String, value: String, detail: String? = nil,
        fraction: Double? = nil, highIsBad: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let fraction = fraction {
                usageBar(fraction, color: highIsBad && fraction > Constants.System.highUsage ? .orange : .white)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Constants.UI.tileCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func usageBar(_ fraction: Double, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
        }
        .frame(height: 5)
    }

    private func percentText(_ fraction: Double?) -> String {
        fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func rateText(_ bytesPerSecond: Double?) -> String {
        bytesPerSecond.map { "\(byteText(Int64($0)))/s" } ?? "–"
    }

    private func batterySymbol(_ battery: SystemStats.BatteryStatus?) -> String {
        guard let battery = battery else { return "battery.0" }
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.level {
        case 0.75...: return "battery.100"
        case 0.5..<0.75: return "battery.75"
        case 0.25..<0.5: return "battery.50"
        case 0.1..<0.25: return "battery.25"
        default: return "battery.0"
        }
    }

    private func batteryDetail(_ battery: SystemStats.BatteryStatus?) -> String {
        guard let battery = battery else { return "No battery" }
        if battery.isCharging { return "Charging" }
        return battery.isOnAC ? "On power, not charging" : "On battery"
    }

    private func diskUsedFraction(_ stats: SystemStats) -> Double? {
        guard let available = stats.diskAvailable, let total = stats.diskTotal, total > 0 else { return nil }
        return 1 - Double(available) / Double(total)
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
        var actions: [(String, () -> Void)] = []
        if let actionTitle = actionTitle, let action = action {
            actions.append((actionTitle, action))
        }
        return statusRow(icon: icon, text: text, actions: actions)
    }

    private func statusRow(icon: String, text: String, actions: [(String, () -> Void)]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
                .monospacedDigit()
            Spacer()
            ForEach(actions.indices, id: \.self) { index in
                let (title, action) = actions[index]
                Button(action: action) {
                    Text(title)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, actions.count > 1 ? 5 : 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(CustomPlainButtonStyle())
                .cornerRadius(5)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(8)
        .background(Color.white.opacity(0.08))
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
    @ObservedObject var pomodoro: Pomodoro

    var body: some View {
        ZStack {
            VisualEffectBackground()
            LinearGradient(colors: PomodoroTheme.breakColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(0.55)

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
                    overlayButton("Snooze \(Constants.Pomodoro.snoozeMinutes)m", systemImage: "moon.zzz.fill", action: pomodoro.snooze)
                    overlayButton("Back to focus", systemImage: "bolt.fill", action: pomodoro.skipBreak)
                        .keyboardShortcut(.cancelAction)
                }

                Text("Press Esc to get back to focus")
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
                .trim(from: 0, to: pomodoro.progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: Constants.Time.updateInterval), value: pomodoro.progress)
            Text(TimeRemaining(from: pomodoro.timeRemaining ?? 0).clockFormat)
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

/// Colors and labels for each Pomodoro phase: tomato for focus, mint for breaks.
struct PomodoroTheme {
    let colors: [Color]
    let label: String
    let symbol: String

    static let focusColors = [Color(red: 0.93, green: 0.27, blue: 0.24), Color(red: 0.98, green: 0.55, blue: 0.22)]
    static let breakColors = [Color(red: 0.07, green: 0.6, blue: 0.5), Color(red: 0.2, green: 0.72, blue: 0.85)]
    static let pausedColors = [Color(red: 0.4, green: 0.42, blue: 0.55), Color(red: 0.55, green: 0.57, blue: 0.68)]

    init(phase: Pomodoro.Phase) {
        switch phase {
        case .focusing:
            colors = Self.focusColors
            label = "FOCUS"
            symbol = "flame.fill"
        case .onBreak:
            colors = Self.breakColors
            label = "BREAK"
            symbol = "cup.and.saucer.fill"
        case .paused:
            colors = Self.pausedColors
            label = "PAUSED"
            symbol = "pause.fill"
        case .off:
            colors = Self.focusColors
            label = ""
            symbol = "flame.fill"
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Brightens on hover and shrinks a little on press, for the Pomodoro card's pills.
struct PillButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(isHovered ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }
}

/// A segmented control drawn in SwiftUI. AppKit's segmented control can lose
/// its segment widths when the island hides it and lays it out again, leaving
/// one squashed "…" segment, so Nook draws its own.
struct SegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .fixedSize()
    }

    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection
        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selection = option
            }
        }) {
            Text(title(option))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Picks a value by clicking or dragging along a ruler of ticks. Ticks up to
/// the value glow, the rest stay dim, and a pointer sits under the value.
struct TickRuler: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// Ticks whose value is a multiple of this get a number above them
    let labelEvery: Int
    let tint: Color

    private let tickWidth: CGFloat = 3
    private let tickGap: CGFloat = 5
    private let tickHeight: CGFloat = 26
    private let labelWidth: CGFloat = 28
    private let pointerSize = CGSize(width: 10, height: 7)

    private var ticks: [Int] {
        Array(stride(from: range.lowerBound, through: range.upperBound, by: step))
    }

    private var pitch: CGFloat { tickWidth + tickGap }
    private var width: CGFloat { CGFloat(ticks.count) * pitch - tickGap }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .leading) {
                ForEach(Array(ticks.enumerated()), id: \.element) { index, tick in
                    if tick % labelEvery == 0 {
                        Text("\(tick)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(tint.opacity(tick <= value ? 1 : 0.35))
                            .frame(width: labelWidth)
                            .offset(x: center(of: index) - labelWidth / 2)
                    }
                }
            }
            .frame(width: width, height: 12, alignment: .leading)

            HStack(spacing: tickGap) {
                ForEach(ticks, id: \.self) { tick in
                    Capsule()
                        .fill(tick <= value ? tint : tint.opacity(0.22))
                        .frame(width: tickWidth, height: tickHeight)
                }
            }

            Triangle()
                .fill(tint)
                .frame(width: pointerSize.width, height: pointerSize.height)
                .offset(x: center(of: ticks.firstIndex(of: value) ?? 0) - pointerSize.width / 2)
                .frame(width: width, alignment: .leading)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: value)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            select(at: drag.location.x)
        })
        .accessibilityElement()
        .accessibilityValue("\(value) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func center(of index: Int) -> CGFloat {
        CGFloat(index) * pitch + tickWidth / 2
    }

    private func select(at x: CGFloat) {
        let index = Int((x / pitch).rounded(.down))
        let tick = ticks[max(0, min(ticks.count - 1, index))]
        guard tick != value else { return }
        value = tick
        // A light tick on the trackpad for each step, like a physical dial
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// A small triangle pointing up.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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

// MARK: - Island

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
/// to the content's size while the content fades and un-blurs into place.
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
                .blur(radius: expanded ? 0 : 12)
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
    /// The panel's content view
    private let root = NSView()
    /// Holds the hosting view; in `root` only while the island is on screen
    private let container = NSView()
    private var pendingHide: DispatchWorkItem?

    /// True from the moment the island starts opening until it starts closing
    var isShown: Bool { model.isExpanded }

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
        model.notchSize = Self.notchSize(of: screen)
        layoutPanel(on: screen)
        attachContent()
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            model.isExpanded = true
        }
    }

    func hide() {
        guard model.isExpanded else { return }
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

