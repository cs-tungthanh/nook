import AppKit
import Combine
import CoreAudio

/// Starts the music again once the Mac has been silent for a while, so a
/// pause for a call or a video doesn't end the music for the day. It asks
/// CoreAudio whether anything is playing on the output device and is told
/// when that changes, so it costs nothing while waiting.
final class QuietResume: ObservableObject {
    /// Minutes of silence before resuming; 0 turns it off
    @Published var minutes: Int {
        didSet {
            defaults.set(minutes, forKey: Constants.Music.Keys.resumeWhenQuiet)
            updateWatching()
            evaluate()
        }
    }
    /// The user's own delay; while it's picked, `minutes` follows it
    @Published var custom: CustomValue {
        didSet {
            custom.save(forKey: Constants.Music.Keys.resumeWhenQuietCustom)
            if custom.isSelected { minutes = custom.value }
        }
    }

    private let music: MusicPlayer
    private let defaults = UserDefaults.standard
    private var device = AudioDeviceID(0)
    private var timer: Timer?
    /// Sleep, display sleep or a locked screen: nobody is there to listen
    private var awayReasons: Set<String> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var statusSubscription: AnyCancellable?

    private var runningAddress = QuietResume.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private var defaultDeviceAddress = QuietResume.address(kAudioHardwarePropertyDefaultOutputDevice)
    private lazy var runningListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.evaluate()
    }
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.attachToDefaultDevice()
    }

    init(music: MusicPlayer) {
        self.music = music
        let stored = defaults.integer(forKey: Constants.Music.Keys.resumeWhenQuiet)
        minutes = stored
        custom = .load(forKey: Constants.Music.Keys.resumeWhenQuietCustom, current: stored,
                       presets: Constants.Music.resumeWhenQuietChoices, defaultValue: 15)
        updateWatching()
    }

    /// Whether the audio listeners and away observers are installed
    private var isWatching = false

    /// Listens for audio, sleep and lock changes only while the feature is on,
    /// so leaving it off costs nothing
    private func updateWatching() {
        let shouldWatch = minutes > 0
        guard shouldWatch != isWatching else { return }
        isWatching = shouldWatch
        let system = AudioObjectID(kAudioObjectSystemObject)
        if shouldWatch {
            AudioObjectAddPropertyListenerBlock(system, &defaultDeviceAddress, .main, deviceListener)
            attachToDefaultDevice()
            observeAway()
            statusSubscription = music.$status.dropFirst().receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.evaluate() }
        } else {
            AudioObjectRemovePropertyListenerBlock(system, &defaultDeviceAddress, .main, deviceListener)
            if device != 0 {
                AudioObjectRemovePropertyListenerBlock(device, &runningAddress, .main, runningListener)
                device = 0
            }
            for (center, token) in observers { center.removeObserver(token) }
            observers = []
            // Nothing tracks sleep or lock while off; turning it back on starts fresh
            awayReasons = []
            statusSubscription = nil
            timer?.invalidate()
            timer = nil
        }
    }

    /// Starts the countdown when everything is quiet, and stops it when anything isn't
    private func evaluate() {
        timer?.invalidate()
        timer = nil
        guard isQuiet else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            guard let self = self, self.isQuiet else { return }
            // Plays the current station, or the last one, or the first preset
            self.music.togglePlayPause()
        }
    }

    private var isQuiet: Bool {
        minutes > 0 && awayReasons.isEmpty && !music.isActive && !isOutputRunning
    }

    private var isOutputRunning: Bool {
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &size, &running)
        return running != 0
    }

    private func attachToDefaultDevice() {
        if device != 0 {
            AudioObjectRemovePropertyListenerBlock(device, &runningAddress, .main, runningListener)
        }
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &defaultDeviceAddress, 0, nil, &size, &device)
        AudioObjectAddPropertyListenerBlock(device, &runningAddress, .main, runningListener)
        evaluate()
    }

    private func observeAway() {
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
        observers = events.map { center, name, reason, isAway in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                if isAway { self.awayReasons.insert(reason) } else { self.awayReasons.remove(reason) }
                // Coming back restarts the countdown from zero
                self.evaluate()
            }
            return (center, token)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
