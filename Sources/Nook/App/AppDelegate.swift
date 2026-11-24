import AppKit
import Combine
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem!
    var island: IslandController!
    var timer: Timer?
    @Published var shutdownDate: Date?
    /// The last Start couldn't schedule a shutdown: Nook may not control System Events
    @Published var shutdownNeedsPermission = false
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
    let permissions = Permissions()
    let music = MusicPlayer()
    let youTubeAccount = YouTubeAccount()
    let updater = Updater()
    lazy var musicSearch = MusicSearch(player: music)
    lazy var quietResume = QuietResume(music: music)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpNotifications()
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
        _ = quietResume
        updater.start()
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
        // For the "Recording saved" notification
        Notifier.requestAuthorizationIfNeeded()
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

    /// Permission is asked for on first use (see `Notifier.requestAuthorizationIfNeeded`),
    /// so a new install shows no prompt at launch
    private func setUpNotifications() {
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerPomodoroCategory()
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

    /// "Resume When Quiet": Off, or after a few minutes without any sound
    private func resumeWhenQuietItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Resume When Quiet", action: nil, keyEquivalent: "")
        item.toolTip = Constants.Music.resumeWhenQuietHelp
        let submenu = NSMenu()
        let choices = [0] + Constants.Music.resumeWhenQuietChoices
        for minutes in choices {
            let choice = ClosureMenuItem(title: minutes == 0 ? "Off" : "After \(Self.minutesText(minutes))") { [weak self] in
                self?.quietResume.custom.isSelected = false
                self?.quietResume.minutes = minutes
            }
            choice.state = !quietResume.custom.isSelected && quietResume.minutes == minutes ? .on : .off
            submenu.addItem(choice)
        }
        // Its value is set in the island's Music tile
        let custom = ClosureMenuItem(title: "Custom: After \(Self.minutesText(quietResume.custom.value))") { [weak self] in
            self?.quietResume.custom.isSelected = true
        }
        custom.state = quietResume.custom.isSelected ? .on : .off
        submenu.addItem(custom)
        item.submenu = submenu
        return item
    }

    private static func minutesText(_ minutes: Int) -> String {
        "\(minutes) Minute\(minutes == 1 ? "" : "s")"
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
        if music.canGoNext {
            menu.addItem(ClosureMenuItem(title: "Next") { [weak self] in self?.music.next() })
        }
        if music.progress.canSeek {
            let step = Constants.Music.seekStepSeconds
            menu.addItem(ClosureMenuItem(title: "Back \(Int(step)) Seconds") { [weak self] in self?.music.skip(by: -step) })
            menu.addItem(ClosureMenuItem(title: "Forward \(Int(step)) Seconds") { [weak self] in self?.music.skip(by: step) })
        }
        if music.videoID != nil {
            menu.addItem(ClosureMenuItem(title: "Open in YouTube") { [weak self] in
                self?.afterClosingIsland { self?.music.openInBrowser() }
            })
        }
        let autoplay = ClosureMenuItem(title: "Autoplay Related Videos") { [weak self] in
            self?.music.autoplay.toggle()
        }
        autoplay.state = music.autoplay ? .on : .off
        autoplay.toolTip = "When a video or playlist ends, play a related video next"
        menu.addItem(autoplay)
        menu.addItem(resumeWhenQuietItem())
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
            guard case .accountPlaylist(let listID) = station.source else { continue }
            let item = NSMenuItem(title: station.menuTitle, action: nil, keyEquivalent: "")
            item.state = station.id == music.station?.id ? .on : .off
            item.submenu = PlaylistVideosMenu(station: station, listID: listID, account: account, music: music)
            menu.addItem(item)
        }
        menu.addItem(ClosureMenuItem(title: "Disconnect YouTube Account") {
            account.signOut()
        })
        menu.addItem(.separator())
    }

    private func setupIsland() {
        island = IslandController(content: ContentView(appDelegate: self, pomodoro: pomodoro, screenRecorder: screenRecorder, bluetooth: bluetooth, system: systemMonitor, music: music, musicSearch: musicSearch, quietResume: quietResume, updater: updater, permissions: permissions))
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
        pomodoro.refreshNotificationPermission()
        systemMonitor.isIslandShown = true
        permissions.isIslandShown = true
        addHighlight()
        startOutsideClickMonitor()
        startEscapeMonitor()
        // Battery levels and connections change while the island is closed.
        // Refresh once it's opening so the work never delays it appearing.
        DispatchQueue.main.async { [weak self] in
            self?.bluetooth.refresh()
        }
        // Read here rather than at launch, so a signed-in account costs nothing
        // until the island (and its Music tile) is first opened. Throttled to
        // once a minute, and the playlists menu refreshes again when it opens.
        Task { [weak self] in await self?.youTubeAccount.refreshPlaylists() }
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
        permissions.isIslandShown = false
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
            // A full-screen break that started while the island was open owns
            // its keys: Esc there means "back to focus", not "close the island"
            if event.window is BreakOverlayWindow { return event }
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

    /// Schedules a shutdown once Nook may control System Events, asking for that
    /// now rather than when the shutdown runs (when nobody may be there to answer)
    func requestShutdown(inMinutes minutes: Int) {
        shutdownNeedsPermission = false
        // Notifications are settled first, so the "Shutdown Scheduled" post
        // isn't dropped and the two macOS prompts never show at once
        Notifier.requestAuthorizationIfNeeded { [weak self] in
            self?.requestAutomationThenSchedule(inMinutes: minutes)
        }
    }

    private func requestAutomationThenSchedule(inMinutes minutes: Int) {
        let schedule = { [weak self] (status: PermissionStatus) in
            guard let self = self else { return }
            if status == .granted {
                // Counted from now, so time spent on the prompt isn't lost
                self.scheduleShutdown(at: Date().addingTimeInterval(TimeInterval(minutes * Constants.Time.secondsPerMinute)))
            } else {
                self.shutdownNeedsPermission = true
            }
        }
        // Launches System Events if needed, so a permission granted earlier is
        // read without closing the island
        permissions.checkAutomationLaunchingIfNeeded { [weak self] status in
            switch status {
            case .granted, .denied, .unknown:
                // `.unknown`: System Events couldn't be launched, so asking would fail too
                schedule(status)
            case .notAsked:
                // The island floats above the prompt, so it closes first
                self?.afterClosingIsland {
                    self?.permissions.askAutomation(schedule)
                }
            }
        }
    }

    func scheduleShutdown(at date: Date) {
        shutdownNeedsPermission = false
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
        // The schedule is spent either way. If the Mac is still running (an
        // app refused to quit, or Automation permission was denied), the
        // countdown and menu bar icon must not linger past their time.
        timer?.invalidate()
        timer = nil
        shutdownDate = nil
        updateStatusItem()

        // Shutting down waits for every app to agree to quit, which can take
        // minutes. NSAppleScript only works on the main thread, so the script
        // runs in osascript instead and the island stays responsive meanwhile.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to shut down"]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        process.terminationHandler = { [weak self] process in
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus != 0 else { return }
            let message = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self?.reportShutdownFailure(message.isEmpty ? "Unknown error." : message)
            }
        }
        do {
            try process.run()
        } catch {
            reportShutdownFailure(error.localizedDescription)
        }
    }

    private func reportShutdownFailure(_ message: String) {
        NSLog("Nook: shutdown failed: \(message)")
        showNotification(
            title: "Couldn't Shut Down",
            body: "\(message) Check that Nook may control System Events in System Settings › Privacy & Security › Automation."
        )
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

/// One of your playlists as a submenu: Play All, then each video in order,
/// so you can start from any of them. The videos load when the submenu
/// first opens and fill in while it's showing.
private final class PlaylistVideosMenu: NSMenu, NSMenuDelegate {
    private let station: MusicStation
    private let listID: String
    private let account: YouTubeAccount
    private let music: MusicPlayer
    private var loadTask: Task<Void, Never>?

    init(station: MusicStation, listID: String, account: YouTubeAccount, music: MusicPlayer) {
        self.station = station
        self.listID = listID
        self.account = account
        self.music = music
        super.init(title: station.name)
        delegate = self
        rebuild(videos: account.cachedVideos(in: listID), error: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard loadTask == nil else { return }
        loadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                self.rebuild(videos: try await self.account.videos(in: self.listID), error: nil)
            } catch {
                // Keep showing an older list if there is one
                if self.account.cachedVideos(in: self.listID) == nil {
                    self.rebuild(videos: nil, error: error)
                }
            }
        }
    }

    private func rebuild(videos: [YouTubeAccount.PlaylistVideo]?, error: Error?) {
        removeAllItems()
        let isThisPlaylist = music.station?.id == station.id
        addItem(ClosureMenuItem(title: "Play All") { [music, station] in music.play(station) })
        addItem(.separator())
        guard let videos = videos else {
            let text = error.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription } ?? "Loading videos…"
            let status = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            status.isEnabled = false
            addItem(status)
            return
        }
        guard !videos.isEmpty else {
            let empty = NSMenuItem(title: MusicError.emptyPlaylist.errorDescription ?? "", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            addItem(empty)
            return
        }
        let limit = 56
        for (index, video) in videos.enumerated() {
            let name = video.title.count > limit
                ? video.title.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
                : video.title
            let item = ClosureMenuItem(title: "\(index + 1).  \(name)") { [music, station] in
                music.play(station, startingAt: index)
            }
            item.toolTip = video.title
            item.state = isThisPlaylist && music.videoID == video.id ? .on : .off
            addItem(item)
        }
    }
}

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
