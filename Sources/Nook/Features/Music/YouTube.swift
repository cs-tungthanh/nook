import Foundation

/// Talks to YouTube without an API key: search goes through the same API
/// youtube.com uses, and oEmbed tells whether a video may be embedded.
enum YouTube {
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

    /// The videos YouTube lists as "Up next" beside `videoID`, which needs no
    /// sign-in. Recommendations on the empty search page are built from these.
    static func related(to videoID: String) async throws -> [MusicSearchResult] {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/next?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": Constants.Music.clientVersion, "hl": "en"]],
            "videoId": videoID
        ])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MusicError.network
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MusicError.network }
        let json = try JSONSerialization.jsonObject(with: data)
        let items = dig(json, "contents", "twoColumnWatchNextResults", "secondaryResults",
                        "secondaryResults", "results") as? [Any] ?? []
        return items.compactMap { item in
            (dig(item, "lockupViewModel") as? [String: Any]).flatMap(lockupVideo)
                ?? (dig(item, "compactVideoRenderer") as? [String: Any]).flatMap(video)
        }
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

    /// A video in YouTube's newer "lockup" layout, used by the Up next list
    private static func lockupVideo(_ lockup: [String: Any]) -> MusicSearchResult? {
        guard lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
              let id = lockup["contentId"] as? String else { return nil }
        let metadata = dig(lockup, "metadata", "lockupMetadataViewModel")
        // The length, or LIVE, is a badge on the thumbnail
        let overlays = dig(lockup, "contentImage", "thumbnailViewModel", "overlays") as? [Any] ?? []
        let badge = overlays.lazy.compactMap { overlay -> [String: Any]? in
            (dig(overlay, "thumbnailBottomOverlayViewModel", "badges", 0, "thumbnailBadgeViewModel")
                ?? dig(overlay, "thumbnailOverlayBadgeViewModel", "thumbnailBadges", 0, "thumbnailBadgeViewModel")) as? [String: Any]
        }.first
        let badgeText = badge?["text"] as? String ?? ""
        let isLive = badgeText.uppercased() == "LIVE" || (badge?["badgeStyle"] as? String ?? "").contains("LIVE")
        return MusicSearchResult(
            id: id,
            kind: isLive ? .live : .video,
            title: dig(metadata, "title", "content") as? String ?? "Video",
            channel: dig(metadata, "metadata", "contentMetadataViewModel", "metadataRows", 0,
                         "metadataParts", 0, "text", "content") as? String ?? "",
            detail: isLive ? "LIVE" : badgeText,
            thumbnail: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"),
            durationSeconds: isLive ? nil : seconds(fromClock: badgeText)
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
