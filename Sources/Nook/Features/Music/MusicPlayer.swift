import AppKit
import Combine
import WebKit

/// Where the video playing now is, reported by the player about once a
/// second. Kept apart from `MusicPlayer` so only the progress bar redraws
/// that often, not everything watching the player.
final class MusicProgress: ObservableObject {
    @Published fileprivate(set) var time: Double = 0
    @Published fileprivate(set) var duration: Double = 0
    @Published fileprivate(set) var isLive = false

    /// A live stream has no fixed end to seek within
    var canSeek: Bool { !isLive && duration > 0 }

    fileprivate func reset() {
        time = 0
        duration = 0
        isLive = false
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
    /// When a video ends with nothing after it, play a related one next
    @Published var autoplay: Bool {
        didSet { defaults.set(autoplay, forKey: Constants.Music.Keys.autoplay) }
    }
    @Published var volume: Double {
        didSet {
            defaults.set(volume, forKey: Constants.Music.Keys.volume)
            run("nook.setVolume(\(Int(volume)))")
        }
    }

    /// Called whenever playback starts or stops, so the menu bar can refresh
    var onChange: (() -> Void)?
    let progress = MusicProgress()
    /// Plays your own playlists, when you've connected YouTube
    weak var account: YouTubeAccount?

    var stations: [MusicStation] { MusicStation.presets + customStations }

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
    /// The `nook.load` item waiting for the player to finish loading
    private var pendingItem: String?
    /// The station last handed to the player; differs from `station` when a
    /// pause cancelled the load before it got there
    private var loadedStation: MusicStation?
    /// Set when a cached live stream failed and is being searched for again,
    /// so a fresh stream that also fails falls back instead of looping
    private var isRetryingLiveSearch = false
    private var loadTask: Task<Void, Never>?
    /// Set from a seek until the player settles, so its brief buffering
    /// doesn't show as "Reconnecting…"
    private var isSeeking = false
    /// What played before the current station; it comes back if the new one can't play
    private var fallback: Fallback?

    private struct Fallback {
        let station: MusicStation
        let status: Status
        let title: String?
        let channel: String?
        let videoID: String?
    }
    /// Live stream IDs found for presets this session
    private var liveStreams: [String: String] = [:]
    /// Videos autoplay picked this session, so it doesn't circle back to them
    private var autoplayed: [String] = []
    private var autoplayTask: Task<Void, Never>?
    private var noticeWork: DispatchWorkItem?

    override init() {
        defaults.register(defaults: [Constants.Music.Keys.volume: Constants.Music.defaultVolume,
                                     Constants.Music.Keys.autoplay: true])
        volume = defaults.double(forKey: Constants.Music.Keys.volume)
        autoplay = defaults.bool(forKey: Constants.Music.Keys.autoplay)
        customStations = Self.load([MusicStation].self, forKey: Constants.Music.Keys.customStations) ?? []
        recentlyPlayed = Self.load([MusicStation].self, forKey: Constants.Music.Keys.recentlyPlayed) ?? []
        station = Self.load(MusicStation.self, forKey: Constants.Music.Keys.lastStation) ?? MusicStation.presets[0]
        super.init()
    }

    // MARK: Actions

    func play(_ newStation: MusicStation) {
        play(newStation, resuming: false)
    }

    /// Plays a playlist from its `index`th video (counting from 0), so Next
    /// and Previous still move through the rest of it
    func play(_ newStation: MusicStation, startingAt index: Int) {
        play(newStation, resuming: false, startIndex: index)
    }

    /// With `resuming`, the player picks up where it was before the last
    /// switch: same playlist entry, same moment
    private func play(_ newStation: MusicStation, resuming: Bool, startIndex: Int = 0) {
        if let station = station, station != newStation, status == .playing || status == .paused {
            fallback = Fallback(station: station, status: status, title: title, channel: channel, videoID: videoID)
        }
        station = newStation
        title = nil
        channel = nil
        videoID = nil
        progress.reset()
        isSeeking = false
        status = .loading
        save(newStation, forKey: Constants.Music.Keys.lastStation)

        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let item = try await self.playerItem(for: newStation, startIndex: startIndex)
                guard !Task.isCancelled, self.station == newStation else { return }
                self.load(item, resuming: resuming)
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
            run("nook.pause()")
            status = .paused
        case .paused:
            if let station = station, loadedStation != station {
                // Paused before the station reached the player: load it now
                play(station)
            } else if isPlayerReady {
                run("nook.play()")
            } else {
                // The waiting load starts playing once the player is ready
                status = .loading
            }
        case .idle, .failed:
            if let station = station { play(station) }
        }
    }

    /// Moves on in a playlist; at its end, or on a single video, plays a
    /// related video when autoplay is on
    func next() { run("nook.next()") }

    /// A playlist always has somewhere to go; a single video only with autoplay
    var canGoNext: Bool {
        guard let station = station, status != .idle else { return false }
        if station.isPlaylist { return true }
        if case .video = station.source { return autoplay }
        return false
    }

    var canGoPrevious: Bool { station?.isPlaylist == true && status != .idle }

    /// Plays the first video in `videoID`'s Up next list that hasn't played
    /// lately and can play outside YouTube. Gives up quietly if none can.
    private func playRelated(after videoID: String) {
        guard let current = station else { return }
        var known = Set(autoplayed + [videoID])
        for station in recentlyPlayed + customStations {
            if case .video(let id) = station.source { known.insert(id) }
        }
        autoplayTask?.cancel()
        autoplayTask = Task { @MainActor [weak self] in
            let candidates = ((try? await YouTube.related(to: videoID)) ?? [])
                .filter { $0.kind == .video && !known.contains($0.id) }
            for candidate in candidates.prefix(5) {
                // Stop if you picked something else meanwhile
                guard let self = self, !Task.isCancelled, self.station == current else { return }
                guard (try? await YouTube.playableTitle(of: .video(candidate.id))) != nil else { continue }
                guard !Task.isCancelled, self.station == current else { return }
                self.autoplayed = Array((self.autoplayed + [candidate.id]).suffix(100))
                self.play(MusicStation.youTube(.video(candidate.id), name: candidate.title))
                return
            }
        }
    }

    func seek(to seconds: Double) {
        guard progress.canSeek else { return }
        let target = min(max(seconds, 0), max(progress.duration - 1, 0))
        progress.time = target
        isSeeking = true
        run("nook.seek(\(target))")
    }

    /// Rewinds (negative) or skips forward by `seconds`
    func skip(by seconds: Double) {
        seek(to: progress.time + seconds)
    }

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
    func previous() { run("nook.previous()") }

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

    /// The JS object `nook.load` takes: a video or a playlist to start.
    /// Built as JSON so no ID can break out of the JavaScript it's put in.
    private func playerItem(for station: MusicStation, startIndex: Int = 0) async throws -> String {
        switch station.source {
        case .video(let id):
            return try Self.jsObject(["videoId": id])
        case .playlist(let id):
            return try Self.jsObject(["list": id, "index": startIndex])
        case .accountPlaylist(let id):
            guard let account = account else { throw MusicError.signIn }
            let ids = try await account.videos(in: id).map(\.id)
            guard !ids.isEmpty else { throw MusicError.emptyPlaylist }
            return try Self.jsObject(["videos": ids, "index": min(max(startIndex, 0), ids.count - 1)])
        case .liveSearch(let query):
            if let id = liveStreams[query] { return try Self.jsObject(["videoId": id]) }
            guard let stream = try await YouTube.search(query, filter: .live).first(where: { $0.kind == .live }) else {
                throw MusicError.noLiveStream
            }
            await MainActor.run { liveStreams[query] = stream.id }
            return try Self.jsObject(["videoId": stream.id])
        }
    }

    private static func jsObject(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// Hands `item` to the player, loading the player first if needed
    private func load(_ item: String, resuming: Bool = false) {
        loadedStation = station
        guard isPlayerReady, webView != nil else {
            pendingItem = item
            loadPlayer()
            return
        }
        run("nook.load(\(item), true, \(resuming))")
    }

    /// Forgets the live stream found for the current station, so the next
    /// play searches again instead of loading a stream that has ended
    @discardableResult
    private func forgetLiveStream() -> Bool {
        guard case .liveSearch(let query)? = station?.source else { return false }
        return liveStreams.removeValue(forKey: query) != nil
    }

    private func couldNotPlay(_ error: Error) {
        // A cached live stream may simply have ended: search once more
        if forgetLiveStream(), !isRetryingLiveSearch, let station = station {
            isRetryingLiveSearch = true
            play(station)
            return
        }
        isRetryingLiveSearch = false
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let fallback = fallback, fallback.station != station {
            let failedName = station?.name ?? "This station"
            self.fallback = nil
            if loadedStation == fallback.station {
                // The new station never reached the player, so the old one is
                // still playing: just show it again
                loadTask?.cancel()
                station = fallback.station
                status = fallback.status
                title = fallback.title
                channel = fallback.channel
                videoID = fallback.videoID
                save(fallback.station, forKey: Constants.Music.Keys.lastStation)
            } else {
                // A live stream has no earlier moment to go back to
                let isLive: Bool = {
                    if case .liveSearch = fallback.station.source { return true }
                    return false
                }()
                play(fallback.station, resuming: !isLive)
            }
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

    /// Runs JS in the player. Commands are dropped while there's no player
    /// to obey them; `load` is what starts the player.
    private func run(_ command: String) {
        guard isPlayerReady, let webView = webView else { return }
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
        // Through a weak proxy: the content controller retains its handlers,
        // and the player owns the web view, so adding `self` is a retain cycle
        config.userContentController.add(WeakScriptMessageHandler(self), name: "nook")

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
        let player, fadeTimer, pendingStart, resumePoint, lastReport, volume = \(Int(volume));

        // Tells Nook where the video is, only when the shown second changes
        function reportTime() {
          if (!player || !player.getDuration) { return; }
          const time = player.getCurrentTime() || 0, duration = player.getDuration() || 0;
          const live = !!(player.getVideoData() || {}).isLive;
          const key = Math.floor(time) + '/' + Math.floor(duration) + '/' + live;
          if (key === lastReport) { return; }
          lastReport = key;
          post({ event: 'time', time: time, duration: duration, live: live });
        }

        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            width: \(Int(size.width)), height: \(Int(size.height)),
            playerVars: { autoplay: 1, controls: 0, disablekb: 1, origin: '\(Constants.Music.origin)' },
            events: {
              onReady: () => { player.setVolume(volume); post({ event: 'ready' }); setInterval(reportTime, 1000); },
              onStateChange: e => {
                post({ event: 'state', state: e.data, title: (player.getVideoData() || {}).title || '', channel: (player.getVideoData() || {}).author || '', videoId: (player.getVideoData() || {}).video_id || '' });
                if (e.data === YT.PlayerState.ENDED) { finishedOrNext(false); }
              },
              onError: e => post({ event: 'error', code: e.data })
            }
          });
        }

        // Nothing follows the video playing now (a single video, or a playlist's
        // last): tell Nook, which may autoplay something related. Mid-playlist,
        // YouTube moves on by itself, or `advance` does.
        function finishedOrNext(advance) {
          const list = player.getPlaylist() || [], index = player.getPlaylistIndex();
          if (list.length > 1 && index >= 0 && index < list.length - 1) {
            if (advance) { player.nextVideo(); }
            return;
          }
          post({ event: 'finished', videoId: (player.getVideoData() || {}).video_id || '' });
        }

        // Fades the old station out, then starts the new one. Pausing or a
        // new load mid-fade still starts it, so the switch is never lost.
        function fadeOutThen(start) {
          clearInterval(fadeTimer);
          pendingStart = start;
          const from = player.getVolume(), steps = 10;
          let step = 0;
          fadeTimer = setInterval(() => {
            step++;
            player.setVolume(Math.round(from * (1 - step / steps)));
            if (step >= steps) { finishFade(true); }
          }, \(Constants.Music.fadeMilliseconds) / steps);
        }

        function finishFade(autoplay) {
          clearInterval(fadeTimer);
          const start = pendingStart;
          pendingStart = null;
          if (start) { start(autoplay); }
        }

        window.nook = {
          load(item, autoplay, resume) {
            // Where the outgoing station was, so a failed switch can return to it
            const here = { index: Math.max(0, player.getPlaylistIndex()), time: player.getCurrentTime() || 0 };
            const at = resume && resumePoint ? resumePoint : { index: item.index || 0, time: 0 };
            resumePoint = resume ? null : here;
            const start = play => {
              if (play) {
                if (item.videos) { player.loadPlaylist(item.videos, at.index, at.time); }
                else if (item.list) { player.loadPlaylist({ list: item.list, listType: 'playlist', index: at.index, startSeconds: at.time }); }
                else { player.loadVideoById(item.videoId, at.time); }
              } else {
                if (item.videos) { player.cuePlaylist(item.videos); }
                else if (item.list) { player.cuePlaylist({ list: item.list, listType: 'playlist' }); }
                else { player.cueVideoById(item.videoId); }
              }
              player.setVolume(volume);
            };
            if (autoplay && player.getPlayerState() === YT.PlayerState.PLAYING) { fadeOutThen(start); }
            else { pendingStart = null; clearInterval(fadeTimer); start(autoplay); }
          },
          play() { player.playVideo(); },
          pause() {
            if (pendingStart) { finishFade(false); }
            else { player.pauseVideo(); }
          },
          next() { finishedOrNext(true); },
          seek(seconds) { if (!pendingStart) { player.seekTo(seconds, true); lastReport = null; } },
          previous() { player.previousVideo(); },
          // During a fade only remember the volume; the new station starts at it
          setVolume(value) { volume = value; if (!pendingStart) { player.setVolume(value); } }
        };
        </script></body></html>
        """
    }

    private func handle(event: [String: Any]) {
        switch event["event"] as? String {
        case "ready":
            isPlayerReady = true
            if let item = pendingItem {
                pendingItem = nil
                // Paused while the player loaded: cue the station without playing it
                run("nook.load(\(item), \(status != .paused))")
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
                isSeeking = false
                status = .playing
                fallback = nil
                isRetryingLiveSearch = false
                if let station = station { remember(station) }
            case 0, 2, 5:
                isSeeking = false
                // An ended live stream is gone for good
                if event["state"] as? Int == 0 { forgetLiveStream() }
                if status != .loading || event["state"] as? Int == 0 { status = .paused }
            case 3, -1:
                if status != .paused, !isSeeking { status = .loading }
            default:
                break
            }
        case "finished":
            guard autoplay, let station = station,
                  let finished = event["videoId"] as? String, !finished.isEmpty else { return }
            // Live stations stay themselves; only videos and playlists autoplay
            if case .liveSearch = station.source { return }
            playRelated(after: finished)
        case "time":
            // A new station is on its way: the old video's last ticks don't count
            guard status != .loading || isSeeking else { return }
            let isLiveSearch: Bool = {
                if case .liveSearch = station?.source { return true }
                return false
            }()
            progress.isLive = (event["live"] as? Bool ?? false) || isLiveSearch
            progress.duration = event["duration"] as? Double ?? 0
            if !isSeeking { progress.time = event["time"] as? Double ?? 0 }
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

/// Forwards script messages without keeping the real handler alive.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

extension MusicPlayer: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let event = message.body as? [String: Any] else { return }
        handle(event: event)
    }
}
