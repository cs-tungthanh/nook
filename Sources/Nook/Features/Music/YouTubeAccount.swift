import AppKit
import Combine
import AuthenticationServices
import CryptoKit

/// Signs in to Google so the station menu can list your own YouTube
/// playlists. Sign-in runs in the system browser sheet with PKCE (no client
/// secret); only the refresh token is kept, in the Keychain. Read-only: Nook
/// never changes anything in the account.
///
/// Needs Nook's Google OAuth client ID ("iOS" type, bundle ID com.nook.app),
/// which scripts/build.sh stamps into Info.plist from `NOOK_YOUTUBE_CLIENT_ID`.
final class YouTubeAccount: NSObject, ObservableObject {
    /// Remembered in UserDefaults, so launch doesn't wait on the keychain to know it
    @Published private(set) var isSignedIn: Bool {
        didSet { UserDefaults.standard.set(isSignedIn, forKey: Keys.signedIn) }
    }
    /// Liked videos first, then your playlists as YouTube orders them
    @Published private(set) var playlists: [MusicStation] = []

    private let clientID: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "NookYouTubeClientID") as? String
        return value?.isEmpty == false ? value : nil
    }()

    var canSignIn: Bool { clientID != nil }

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    /// The token refresh under way, shared so parallel requests don't each start one
    private var tokenRefresh: Task<String, Error>?
    private var authSession: ASWebAuthenticationSession?
    private var lastRefresh = Date.distantPast

    private enum Keys {
        static let refreshToken = "youtube.refreshToken"
        static let signedIn = "youtube.signedIn"
    }
    private static let scope = "https://www.googleapis.com/auth/youtube.readonly"
    private static let api = "https://www.googleapis.com/youtube/v3/"
    /// The player takes at most this many videos in one playlist
    private static let maxVideos = 200

    override init() {
        let stored = UserDefaults.standard.object(forKey: Keys.signedIn) as? Bool
        isSignedIn = stored ?? false
        super.init()
        guard stored == nil else { return }
        // Versions before the flag only kept the keychain item: check it once,
        // off the main thread, and remember the answer from then on. A failed
        // read stores nothing, so the next launch checks again.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hasToken: Bool
            switch Keychain.lookup(Keys.refreshToken) {
            case .found: hasToken = true
            case .missing: hasToken = false
            case .failed: return
            }
            DispatchQueue.main.async { self?.isSignedIn = hasToken }
        }
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
        videoCache = [:]
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
        try Keychain.write(refreshToken, for: Keys.refreshToken)
        store(json)
        isSignedIn = true
    }

    /// A valid access token, refreshed when the old one is about to expire
    @MainActor
    private func validAccessToken() async throws -> String {
        if let token = accessToken, accessTokenExpiry.timeIntervalSinceNow > 60 { return token }
        if let refresh = tokenRefresh { return try await refresh.value }
        guard let clientID = clientID else { throw MusicError.signIn }
        let refreshToken: String
        switch Keychain.lookup(Keys.refreshToken) {
        case .found(let token):
            refreshToken = token
        case .missing:
            // The flag said signed in but the token is gone (removed in Keychain Access)
            isSignedIn = false
            throw MusicError.signIn
        case .failed(let status):
            // Still signed in: the token may be there, just unreadable this time
            throw MusicError.keychain(status)
        }
        let refresh = Task { @MainActor () throws -> String in
            defer { tokenRefresh = nil }
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
        tokenRefresh = refresh
        return try await refresh.value
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

    struct PlaylistVideo: Equatable {
        let id: String
        let title: String
    }

    /// Videos read this session, by playlist ID, so the menu opens a
    /// playlist instantly the second time
    private var videoCache: [String: (videos: [PlaylistVideo], loaded: Date)] = [:]

    /// The videos last read for a playlist, if any, however old
    func cachedVideos(in playlistID: String) -> [PlaylistVideo]? {
        videoCache[playlistID]?.videos
    }

    /// The videos in one of your playlists, private ones included, in order.
    /// Reads again once the cached copy is a minute old.
    @MainActor
    func videos(in playlistID: String) async throws -> [PlaylistVideo] {
        if let cached = videoCache[playlistID], Date().timeIntervalSince(cached.loaded) < 60 {
            return cached.videos
        }
        var videos: [PlaylistVideo] = []
        var pageToken: String?
        repeat {
            var query = ["part": "snippet,contentDetails", "playlistId": playlistID, "maxResults": "50"]
            query["pageToken"] = pageToken
            let page = try await get("playlistItems", query)
            for item in page["items"] as? [[String: Any]] ?? [] {
                guard let id = YouTube.dig(item, "contentDetails", "videoId") as? String else { continue }
                let title = YouTube.dig(item, "snippet", "title") as? String ?? "Untitled video"
                videos.append(PlaylistVideo(id: id, title: title))
            }
            pageToken = page["nextPageToken"] as? String
        } while pageToken != nil && videos.count < Self.maxVideos
        videos = Array(videos.prefix(Self.maxVideos))
        videoCache[playlistID] = (videos, Date())
        return videos
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

    /// What a read found. `failed` means the item may still be there, e.g. the
    /// user denied the access prompt a newly signed build can show
    enum Lookup {
        case found(String)
        case missing
        case failed(OSStatus)
    }

    static func lookup(_ account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return .failed(status) }
        return .found(value)
    }

    static func read(_ account: String) -> String? {
        if case .found(let value) = lookup(account) { return value }
        return nil
    }

    static func write(_ value: String, for account: String) throws {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw MusicError.keychain(status) }
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
