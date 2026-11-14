import SwiftUI
import AppKit
import UserNotifications
import ScreenCaptureKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers
import IOBluetooth
import CoreBluetooth

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

    enum Tooltip {
        static let delay: TimeInterval = 0.5
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
        /// Grace period before re-reading state after a disconnect or forget
        static let refreshDelay: TimeInterval = 1
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

        // Leave Nook's own popover and overlays out of the video
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

/// Lists paired Bluetooth devices and connects, disconnects or forgets them.
/// Uses IOBluetooth for the devices and CoreBluetooth only for the power and
/// permission state. Battery levels and "forget" rely on undocumented
/// IOBluetoothDevice selectors, so both are checked before use.
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
    /// True when the error is fixed in Bluetooth Settings, so the popover offers a button
    @Published private(set) var needsBluetoothSettings = false

    /// Created on first use so the Bluetooth permission prompt only appears
    /// once the user opens the popover, not at launch
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
            availability = .ready
            watchConnections()
            let paired = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).map(Self.info)
            refreshGeneration += 1
            let generation = refreshGeneration
            reportQueue.async { [weak self] in
                let report = SystemBluetoothReport.load()
                DispatchQueue.main.async {
                    // A newer refresh (or Bluetooth turning off) supersedes this one
                    guard let self = self, generation == self.refreshGeneration else { return }
                    self.devices = Self.merge(paired, with: report).sorted {
                        if $0.isConnected != $1.isConnected { return $0.isConnected }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
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
        needsBluetoothSettings = false
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

    func forget(_ info: BluetoothDeviceInfo) {
        let remove = NSSelectorFromString("remove")
        guard let device = IOBluetoothDevice(addressString: info.id), device.responds(to: remove) else {
            errorMessage = "Forget isn't supported on this macOS — use Bluetooth Settings"
            needsBluetoothSettings = true
            return
        }
        errorMessage = nil
        needsBluetoothSettings = false
        if device.isConnected() {
            device.closeConnection()
        }
        _ = device.perform(remove)
        // `remove` is undocumented and recent macOS can ignore it without any
        // error, so check the system's own list to see whether it really worked
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Bluetooth.refreshDelay) { [weak self] in
            self?.reportQueue.async {
                let stillPaired = SystemBluetoothReport.load()[SystemBluetoothReport.normalize(info.id)] != nil
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if stillPaired {
                        self.errorMessage = "macOS didn't let Nook forget \(info.name) — forget it in Bluetooth Settings"
                        self.needsBluetoothSettings = true
                    }
                    self.refresh()
                }
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
        availability = state
        devices = []
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
    private var outsideClickMonitor: Any?
    /// A separate menu bar button, shown only while recording, that stops it in one click
    private var stopRecordingItem: NSStatusItem?
    private var stopRecordingTimer: Timer?
    let breakReminder = BreakReminder()
    let screenRecorder = ScreenRecorder()
    let bluetooth = BluetoothManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNotificationPermissions()
        setupStatusBar()
        setupPopover()
        breakReminder.onChange = { [weak self] in
            self?.updateStatusItem()
        }
        screenRecorder.onChange = { [weak self] in
            self?.updateStatusItem()
            self?.updateStopRecordingItem()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting would lose an unsaved recording, so offer to save it first
        guard screenRecorder.hasUnsavedRecording else { return .terminateNow }
        screenRecorder.save {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func startRecording() {
        // Close the popover so it isn't in the way of what's being recorded
        popover.performClose(nil)
        screenRecorder.start()
    }

    func resumeRecording() {
        popover.performClose(nil)
        screenRecorder.resume()
    }

    func saveRecording() {
        popover.performClose(nil)
        screenRecorder.save()
    }

    /// Stops the recording from the menu bar, then opens the popover so the
    /// user can resume, save or discard it.
    @objc private func stopRecordingFromMenuBar() {
        screenRecorder.pause { [weak self] in
            guard let self = self, self.screenRecorder.isPaused, !self.popover.isShown else { return }
            self.togglePopover()
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
        let hostingController = NSHostingController(rootView: ContentView(appDelegate: self, breakReminder: breakReminder, screenRecorder: screenRecorder, bluetooth: bluetooth))
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
                // A menu-bar-only app isn't active by default, so the transient
                // popover's window never becomes key and outside clicks don't close it
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
                addHighlight()
                startOutsideClickMonitor()
            }
        }
    }

    // Fallback for clicks in other apps, which a transient popover can miss
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            self.popover.performClose(nil)
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
        if screenRecorder.isRecording {
            // Recording takes priority so it's always obvious the screen is being captured
            image = StatusIcon.recording
        } else if screenRecorder.isPaused {
            image = StatusIcon.recordingPaused
        } else if breakReminder.breakTimeRemaining != nil {
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
    func popoverWillShow(_ notification: Notification) {
        // Battery levels and connections change while the popover is closed
        bluetooth.refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        // Remove highlight and the outside-click monitor when popover closes
        DispatchQueue.main.async { [weak self] in
            self?.removeHighlight()
            self?.stopOutsideClickMonitor()
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
    @ObservedObject var screenRecorder: ScreenRecorder
    @ObservedObject var bluetooth: BluetoothManager
    @State private var shutdownMinutes = Constants.Shutdown.defaultMinutes
    @State private var showsAllDevices = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            powerOffView
            Divider()
            breakReminderView
            Divider()
            screenRecordingView
            Divider()
            bluetoothView
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
            Picker("", selection: $screenRecorder.source) {
                ForEach(RecordingSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
                    ("Discard", screenRecorder.discard)
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
                statusRow(
                    icon: "exclamationmark.triangle",
                    text: error,
                    actionTitle: bluetooth.needsBluetoothSettings ? "Settings" : nil,
                    action: bluetooth.needsBluetoothSettings ? bluetooth.openSettings : nil
                )
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
            .hoverTooltip("\(device.name)\n\(deviceSubtitle(device))")

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

            Menu {
                Button("Forget This Device…") { confirmForget(device) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(device.isConnected ? 0.08 : 0.03))
        .cornerRadius(8)
    }

    private func deviceSubtitle(_ device: BluetoothDeviceInfo) -> String {
        guard device.isConnected else { return "Not connected" }
        guard let battery = device.battery else { return "Connected" }
        return "Connected · \(battery)"
    }

    private func confirmForget(_ device: BluetoothDeviceInfo) {
        let alert = NSAlert()
        alert.messageText = "Forget \(device.name)?"
        alert.informativeText = "You'll need to pair it again from Bluetooth Settings to use it with this Mac."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Forget Device")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            bluetooth.forget(device)
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

// MARK: - Hover Tooltip

/// A tooltip Nook draws itself. System tooltips (`.help`) don't appear inside
/// a menu bar app's popover, so this shows a small popover after a short hover.
private struct HoverTooltip: ViewModifier {
    let text: String
    @State private var isHovering = false
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                guard hovering else {
                    isShown = false
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Tooltip.delay) {
                    if isHovering { isShown = true }
                }
            }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                Text(text)
                    .font(.caption)
                    .monospacedDigit()
                    .multilineTextAlignment(.leading)
                    .fixedSize()
                    .padding(8)
            }
    }
}

extension View {
    fileprivate func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltip(text: text))
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
