import Foundation

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
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .badLink: return "That isn't a YouTube video or playlist link"
        case .notEmbeddable: return "This can only be played on YouTube"
        case .notFound: return "This video is private or was removed"
        case .noLiveStream: return "No live stream found right now"
        case .network: return "Can't reach YouTube"
        case .signIn: return "Connect your YouTube account again"
        case .emptyPlaylist: return "This playlist has no videos"
        case .keychain(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Couldn't access the YouTube sign-in in the keychain: \(reason)"
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
    var params: String? {
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
