import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var pomodoro: Pomodoro
    @ObservedObject var screenRecorder: ScreenRecorder
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var system: SystemMonitor
    @ObservedObject var music: MusicPlayer
    @ObservedObject var musicSearch: MusicSearch
    @ObservedObject var quietResume: QuietResume
    @ObservedObject var updater: Updater
    @ObservedObject var permissions: Permissions
    @State private var shutdownMinutes = Constants.Shutdown.defaultMinutes
    @State private var showsAllDevices = false
    @State private var page: Page = .utilities

    private enum Page {
        case utilities, system, about, permissions
    }

    private var showsSystem: Bool { page == .system }
    /// The link field shown in the Music tile, nil when it's closed
    @State private var musicLink: String?
    @State private var musicLinkError: String?
    @State private var isAddingMusicLink = false
    @State private var isHoveringArtwork = false
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: Constants.UI.gridSpacing) {
            headerView
            if page == .system {
                systemView
            } else if page == .about {
                tile(aboutView)
            } else if page == .permissions {
                tile(permissionsView)
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
            // The icon and title lead back to the tiles from any other page
            Button(action: showHome) {
                HStack(spacing: 8) {
                    Image(nsImage: NookGlyph.image)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(page == .system ? "System" : page == .about ? "About Nook" : page == .permissions ? "Permissions" : "Nook")
                        .font(.headline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Nook")
            Spacer()
            if let release = updater.availableRelease, page != .about {
                Button(action: { setPage(.about) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update to \(release.version)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(CustomPlainButtonStyle())
                .clipShape(Capsule())
            }
            Button(action: { setPage(showsSystem ? .utilities : .system) }) {
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
            Button(action: { setPage(page == .about ? .utilities : .about) }) {
                Image(systemName: page == .about ? "info.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundColor(page == .about ? .primary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(page == .about ? 0.1 : 0)))
            }
            .buttonStyle(CustomPlainButtonStyle())
            .clipShape(Capsule())
            .help("About Nook")
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
}

// MARK: - Power Off

extension ContentView {
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

                // Hidden once Automation reads as allowed (e.g. after the
                // Permissions page), without waiting for the next Start
                if appDelegate.shutdownNeedsPermission && permissions.status(of: .automation) != .granted {
                    statusRow(
                        icon: "exclamationmark.triangle",
                        text: "Nook needs Automation access to shut down",
                        actionTitle: "Permissions",
                        action: { setPage(.permissions) }
                    )
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
}

// MARK: - Pomodoro

extension ContentView {
    private var pomodoroView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Only the card redraws each second, not the whole island
            TimelineView(.periodic(from: .now, by: Constants.Time.updateInterval)) { _ in
                pomodoroCard
            }

            settingRow("Focus") {
                PresetPicker(value: $pomodoro.intervalMinutes, custom: $pomodoro.customInterval,
                             presets: Constants.Pomodoro.intervalOptions,
                             customRange: Constants.Pomodoro.minIntervalMinutes...Constants.Pomodoro.maxIntervalMinutes) { minutes in
                    "\(minutes)m"
                }
            }

            settingRow("Break") {
                PresetPicker(value: $pomodoro.durationSeconds, custom: $pomodoro.customDuration,
                             presets: Constants.Pomodoro.durationOptions,
                             customRange: Constants.Pomodoro.minDurationSeconds...Constants.Pomodoro.maxDurationSeconds,
                             unit: Constants.Time.secondsPerMinute) { seconds in
                    shortDurationText(seconds)
                }
            }

            settingRow("Style") {
                SegmentedPicker(selection: $pomodoro.mode, options: Array(BreakMode.allCases)) { mode in
                    mode.title
                }
            }

            if pomodoro.mode == .notification && !pomodoro.notificationsAllowed {
                statusRow(
                    icon: "bell.slash",
                    text: "Notifications are off, so break reminders won't show",
                    actionTitle: "Permissions",
                    action: { setPage(.permissions) }
                )
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
                // Re-read once answered, so a "Don't Allow" shows the warning
                // right away (startCycle's read runs before the answer)
                Notifier.requestAuthorizationIfNeeded { [weak pomodoro] in
                    pomodoro?.refreshNotificationPermission()
                }
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
                HStack(spacing: 8) {
                    pomodoroPill("Snooze \(Constants.Pomodoro.snoozeMinutes)m", systemImage: "moon.zzz.fill", theme: theme, prominent: false, action: pomodoro.postponeBreak)
                    pomodoroPill("Break now", systemImage: "cup.and.saucer.fill", theme: theme, prominent: true, action: pomodoro.startBreak)
                }
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
}

// MARK: - Screen Recording

extension ContentView {
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
                    actionTitle: screenRecorder.needsPrivacySettings ? "Permissions" : "Retry",
                    action: screenRecorder.needsPrivacySettings ? { setPage(.permissions) } : appDelegate.startRecording
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
}

// MARK: - Bluetooth

extension ContentView {
    private var bluetoothView: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                .frame(minHeight: 20)

            switch bluetooth.availability {
            case .loading:
                statusRow(icon: "hourglass", text: "Looking for devices…")
            case .notAsked:
                statusRow(
                    icon: "lock",
                    text: "Allow Bluetooth to list your devices",
                    actionTitle: "Allow",
                    action: { appDelegate.afterClosingIsland(bluetooth.requestAccess) }
                )
            case .unauthorized:
                statusRow(
                    icon: "exclamationmark.triangle",
                    text: "Nook isn't allowed to use Bluetooth",
                    actionTitle: "Permissions",
                    action: { setPage(.permissions) }
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
}

// MARK: - Music

extension ContentView {
    private var musicView: some View {
        VStack(alignment: .leading, spacing: 10) {
            musicCard

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

            HStack(spacing: 8) {
                Text("Resume when quiet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help(Constants.Music.resumeWhenQuietHelp)
                Spacer(minLength: 4)
                PresetPicker(value: $quietResume.minutes, custom: $quietResume.custom,
                             presets: [0] + Constants.Music.resumeWhenQuietChoices,
                             customRange: Constants.Music.resumeWhenQuietCustomRange) { minutes in
                    minutes == 0 ? "Off" : "\(minutes)m"
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }


    /// The player as a colored card, like Pomodoro's: it glows while music
    /// plays and dims when it's paused or stopped
    private var musicCard: some View {
        let colors = music.isActive ? MusicTheme.playingColors : MusicTheme.restingColors
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("🎵")
                Text("Music")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Spacer()
                musicCardIcon("arrow.up.forward.app", label: "Open in YouTube", enabled: music.videoID != nil) {
                    appDelegate.afterClosingIsland(music.openInBrowser)
                }
                musicCardIcon("magnifyingglass", label: "Search YouTube", enabled: true, action: musicSearch.present)
            }
            .frame(minHeight: 20)

            HStack(alignment: .center, spacing: 12) {
                musicArtwork
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 2) {
                        stationMenu
                        Spacer(minLength: 4)
                        musicButton("backward.fill", label: "Previous", enabled: music.canGoPrevious, action: music.previous)
                        musicButton("forward.fill", label: "Next", enabled: music.canGoNext, action: music.next)
                    }
                    if let notice = music.notice {
                        statusRow(icon: "exclamationmark.triangle", text: notice)
                            .lineLimit(1)
                    } else {
                        // Song titles can be long; one line keeps the tile from jumping
                        musicStatusRow
                            .lineLimit(1)
                    }
                }
            }

            if musicLink != nil {
                musicLinkField
            }

            MusicProgressRow(music: music, progress: music.progress)
        }
        .foregroundColor(.white)
        // The seek bar and "Save" use the accent color, which blue on violet hides
        .accentColor(.white)
        .padding(14)
        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: colors[0].opacity(music.isActive ? 0.45 : 0.2), radius: 8, y: 3)
        .animation(.easeInOut(duration: 0.3), value: music.isActive)
    }

    private func musicCardIcon(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.18)))
        }
        .buttonStyle(PillButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .help(label)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The video's thumbnail with a large play/pause button over it; the whole
    /// square is one click target, so it's easy to hit without aiming
    private var musicArtwork: some View {
        let enabled = music.station != nil
        let size = Constants.Music.artworkSize
        return Button(action: music.togglePlayPause) {
            ZStack {
                if let id = music.videoID, let url = URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.15)
                    }
                } else {
                    Color.white.opacity(0.15)
                }
                Circle()
                    .fill(Color.black.opacity(isHoveringArtwork ? 0.6 : 0.45))
                    .frame(width: 42, height: 42)
                Image(systemName: music.isActive ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    // The triangle's weight sits left of its frame's center
                    .offset(x: music.isActive ? 0 : 1.5)
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(isHoveringArtwork && enabled ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: isHoveringArtwork)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringArtwork = $0 }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(music.isActive ? "Pause" : "Play")
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
}

// MARK: - Music Search

extension ContentView {
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
                if musicSearch.recommendations.isEmpty && !musicSearch.isLoadingRecommendations {
                    recentSearchesView
                } else {
                    recentSearchChips
                    recommendationsView
                }
            } else if let error = musicSearch.errorMessage, musicSearch.results.isEmpty {
                statusRow(icon: "exclamationmark.triangle", text: error)
            } else {
                searchResultsList(musicSearch.results, height: 380)
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

    /// Recent searches in one row, so the recommendations get the room
    @ViewBuilder
    private var recentSearchChips: some View {
        if !musicSearch.recentSearches.isEmpty {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(musicSearch.recentSearches, id: \.self) { recent in
                            Button(action: { musicSearch.query = recent }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock.arrow.circlepath")
                                    Text(recent).lineLimit(1)
                                }
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Search \(recent)")
                        }
                    }
                }
                Button(action: musicSearch.clearRecentSearches) {
                    Text("Clear")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(CustomPlainButtonStyle())
                .cornerRadius(5)
                .accessibilityLabel("Clear recent searches")
            }
        }
    }

    private var recommendationsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Recommended")
                    .font(.caption.weight(.semibold))
                if let source = musicSearch.recommendationSource {
                    Text("· Because you played \(source)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            if musicSearch.recommendations.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding videos like the ones you played…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 330)
            } else {
                searchResultsList(musicSearch.recommendations, height: 330)
            }
        }
    }

    private func searchResultsList(_ results: [MusicSearchResult], height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        searchResultRow(result, isSelected: index == musicSearch.selection)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture { musicSearch.play(result, saving: false) }
                            .onHover { if $0 { musicSearch.selection = index } }
                    }
                }
            }
            .frame(height: height)
            .onChange(of: musicSearch.selection) { selection in
                guard results.indices.contains(selection) else { return }
                proxy.scrollTo(results[selection].id)
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
}

// MARK: - System

extension ContentView {
    private func setPage(_ newPage: Page) {
        page = newPage
        system.isPageShown = newPage == .system
        permissions.isPageShown = newPage == .permissions
    }

    /// The default view: the Utilities tiles, with music search closed
    private func showHome() {
        if musicSearch.isPresented { musicSearch.dismiss() }
        if page != .utilities { setPage(.utilities) }
    }
}

// MARK: - Permissions

extension ContentView {
    private var permissionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What Nook may use on this Mac. Changes made in System Settings show up here within a few seconds.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(PermissionKind.allCases) { kind in
                permissionRow(kind)
            }
            if permissions.status(of: .screenRecording) != .granted {
                Text("Just allowed Screen Recording? macOS shows the change after you quit and reopen Nook.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = permissions.status(of: kind)
        let (symbol, color): (String, Color) = {
            switch status {
            case .granted: return ("checkmark.circle.fill", .green)
            case .denied: return ("xmark.circle.fill", .red)
            case .notAsked: return ("questionmark.circle.fill", .orange)
            case .unknown: return ("circle.dashed", .secondary)
            }
        }()
        // Allowed rows keep Settings too, so access can be turned off again
        let actionTitle: String = {
            switch status {
            case .granted: return "Settings"
            case .notAsked: return kind == .screenRecording ? "Settings" : "Allow"
            case .unknown: return permissions.isCheck(kind) ? "Check" : "Settings"
            case .denied: return "Settings"
            }
        }()
        return HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .frame(width: 18)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                Text(kind.purpose)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundColor(color)
                Text(status.label)
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            // A prompt or System Settings would sit under the island, so it
            // closes first; a Check stays open to show the new status
            Button(action: {
                if permissions.isCheck(kind) {
                    permissions.request(kind)
                } else {
                    appDelegate.afterClosingIsland { permissions.request(kind) }
                }
            }) {
                Text(actionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
            .buttonStyle(CustomPlainButtonStyle())
            .cornerRadius(5)
        }
        .padding(8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(8)
    }
}

// MARK: - About

extension ContentView {
    private var aboutView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nook")
                        .font(.title2.weight(.bold))
                    Text("Version \(updater.currentVersion)")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Text(updater.homebrewPath != nil ? "Installed with Homebrew" : "Installed from GitHub")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            updateRow

            HStack(spacing: 14) {
                linkButton("GitHub", systemImage: "chevron.left.forwardslash.chevron.right", url: Constants.Update.projectPage)
                linkButton("Release notes", systemImage: "doc.text", url: Constants.Update.releasesPage)
                Button(action: { setPage(.permissions) }) {
                    Label("Permissions", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                Spacer()
                if let checked = updater.lastChecked {
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var updateRow: some View {
        switch updater.state {
        case .idle:
            statusRow(icon: "arrow.triangle.2.circlepath", text: "Check whether a newer version is out",
                      actionTitle: "Check for Updates", action: { updater.check() })
        case .checking:
            progressRow("Checking for updates…")
        case .upToDate:
            statusRow(icon: "checkmark.circle", text: "Nook is up to date",
                      actionTitle: "Check Again", action: { updater.check() })
        case .available(let release):
            statusRow(icon: "arrow.down.circle", text: "Version \(release.version) is available",
                      actions: [("What's New", { NSWorkspace.shared.open(release.pageURL) }),
                                ("Update & Relaunch", { updater.install() })])
        case .downloading(let release):
            progressRow("Downloading \(release.version)…")
        case .installing(let release):
            progressRow("Installing \(release.version); Nook will relaunch…")
        case .failed(let message):
            statusRow(icon: "exclamationmark.triangle", text: message,
                      actionTitle: "Try Again", action: { updater.check() })
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
            Spacer()
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(8)
        .background(Color.white.opacity(0.08))
        .cornerRadius(8)
    }

    private func linkButton(_ title: String, systemImage: String, url: String) -> some View {
        Button(action: {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        }) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
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
}

// MARK: - Shared Rows

extension ContentView {
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
        appDelegate.requestShutdown(inMinutes: minutes)
    }
}
