import SwiftUI

enum Constants {
    enum Update {
        static let repository = "cs-tungthanh/nook"
        static let cask = "cs-tungthanh/tap/nook"
        static let latestReleaseAPI = "https://api.github.com/repos/\(repository)/releases/latest"
        static let releasesPage = "https://github.com/\(repository)/releases"
        static let projectPage = "https://github.com/\(repository)"
        /// Background checks run at most this often
        static let checkInterval: TimeInterval = 6 * 60 * 60
        /// First background check after launch, so it never slows startup
        static let launchDelay: TimeInterval = 15
        static let logPath = "~/Library/Logs/Nook/update.log"

        enum Keys {
            static let lastCheck = "update.lastCheck"
            static let notifiedVersion = "update.notifiedVersion"
            static let pendingVersion = "update.pendingVersion"
        }
    }

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
        /// Presets for the Focus and Break pickers; anything else is Custom
        static let intervalOptions = [20, 25, 50]
        static let durationOptions = [120, 300, 600]
        static let minDurationSeconds = 60
        static let maxDurationSeconds = 3600
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
        enum Keys {
            static let enabled = "breakReminder.enabled"
            static let intervalMinutes = "breakReminder.intervalMinutes"
            static let durationSeconds = "breakReminder.durationSeconds"
            static let mode = "breakReminder.mode"
            static let customInterval = "breakReminder.customInterval"
            static let customDuration = "breakReminder.customDuration"
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

    enum Permissions {
        /// How often the Permissions page re-reads each status while it's on screen,
        /// so a change made in System Settings shows up without reopening it
        static let refreshInterval: TimeInterval = 2
        static let microphoneSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        static let automationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        static let notificationsSettingsURL = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        static let systemEventsBundleID = "com.apple.systemevents"
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
        /// Videos played recently that recommendations are drawn from
        static let recommendationSeeds = 3
        static let recommendationLimit = 15
        /// How long recommendations are reused while what you played stays the same
        static let recommendationLifetime: TimeInterval = 600
        /// Stations kept in "Recently Played"
        static let recentlyPlayedLimit = 15
        /// How far the rewind and forward buttons jump
        static let seekStepSeconds = 10.0
        /// The thumbnail and play button on the Music tile
        static let artworkSize: CGFloat = 76
        /// "Long" results are an hour or more; YouTube's own filter only means over 20 minutes
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
            static let autoplay = "music.autoplay"
            static let resumeWhenQuiet = "music.resumeWhenQuiet"
            static let resumeWhenQuietCustom = "music.resumeWhenQuietCustom"
        }

        /// Minutes of silence before "Resume When Quiet" starts the music again
        static let resumeWhenQuietChoices = [1, 5]
        /// How far a custom delay can go
        static let resumeWhenQuietCustomRange = 1...120
        static let resumeWhenQuietHelp = "When nothing on your Mac has made a sound for a while, start the music again"
    }
}
