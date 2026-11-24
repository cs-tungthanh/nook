import AppKit
import Combine
import CryptoKit

/// Checks GitHub for a newer Nook release and installs it.
///
/// Installing downloads the release zip, checks it against the SHA-256 GitHub
/// publishes, and hands a small shell script the job of swapping the app once
/// Nook has quit. A Homebrew install is upgraded with `brew` first, so
/// Homebrew's records stay right; the downloaded copy is the fallback if that fails.
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let sha256: String?
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// Where `brew` lives when Homebrew installed this copy of Nook, else nil
    var homebrewPath: String? {
        guard Bundle.main.bundleURL.path == "/Applications/Nook.app" else { return nil }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let brew = prefix + "/bin/brew"
            if FileManager.default.isExecutableFile(atPath: brew),
               FileManager.default.fileExists(atPath: prefix + "/Caskroom/nook") {
                return brew
            }
        }
        return nil
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    init() {
        lastChecked = defaults.object(forKey: Constants.Update.Keys.lastCheck) as? Date
    }

    /// Reports how the last update went, then keeps checking in the background
    func start() {
        reportFinishedUpdate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Update.launchDelay) { [weak self] in
            self?.checkIfDue()
        }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        if let last = lastChecked, Date().timeIntervalSince(last) < Constants.Update.checkInterval { return }
        check(userInitiated: false)
    }

    // MARK: Checking

    func check(userInitiated: Bool = true) {
        guard !isBusy else { return }
        if userInitiated { state = .checking }
        Task { @MainActor in
            do {
                let release = try await Self.fetchLatestRelease()
                lastChecked = Date()
                defaults.set(lastChecked, forKey: Constants.Update.Keys.lastCheck)
                guard !isBusy || state == .checking else { return }
                if Self.isVersion(release.version, newerThan: currentVersion) {
                    state = .available(release)
                    notifyOnce(about: release)
                } else {
                    state = .upToDate
                }
            } catch {
                // A failed background check stays quiet; the next one will try again
                if userInitiated { state = .failed(Self.message(for: error)) }
            }
        }
    }

    /// Asks for notification permission first if nothing has yet, since a post
    /// made before that is dropped. The version is marked notified only once a
    /// post can show, so a "Don't Allow" later turned on still gets the notice.
    private func notifyOnce(about release: Release) {
        guard defaults.string(forKey: Constants.Update.Keys.notifiedVersion) != release.version else { return }
        Notifier.requestAuthorizationIfNeeded { [weak self] in
            Notifier.checkAllowed { allowed in
                guard let self = self, allowed,
                      self.defaults.string(forKey: Constants.Update.Keys.notifiedVersion) != release.version else { return }
                self.defaults.set(release.version, forKey: Constants.Update.Keys.notifiedVersion)
                Notifier.post(title: "Nook \(release.version) is available",
                              body: "Open Nook › About to update. You have \(self.currentVersion).")
            }
        }
    }

    private static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: Constants.Update.latestReleaseAPI)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError.noRelease
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { $0["name"] as? String == "Nook-\(version).zip" }),
              let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError.noRelease
        }
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, zipURL: zip, sha256: digest, pageURL: page)
    }

    /// Compares dotted versions number by number: 1.10.0 is newer than 1.9.2
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let parse = { (version: String) in version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parse(candidate), b = parse(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    func install() {
        guard case .available(let release) = state else { return }
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            state = .failed("Nook can't write to \(destination.deletingLastPathComponent().path). Update it with Homebrew or reinstall it there.")
            return
        }
        state = .downloading(release)
        // Hashing runs in a detached task and the tools are awaited, so no
        // thread (main or otherwise) sits blocked while the update unpacks
        Task { @MainActor in
            do {
                let app = try await Self.download(release)
                finish(release, newApp: app, destination: destination)
            } catch {
                state = .failed(Self.message(for: error))
            }
        }
    }

    /// Downloads, verifies and unpacks the release; returns the new Nook.app
    private static func download(_ release: Release) async throws -> URL {
        let (zip, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }

        if let expected = release.sha256 {
            let actual = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: zip, options: .mappedIfSafe)
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }.value
            guard actual == expected.lowercased() else { throw UpdateError.checksum }
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookUpdate-\(release.version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])

        let app = folder.appendingPathComponent("Nook.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError.wrongApp
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private func finish(_ release: Release, newApp: URL, destination: URL) {
        state = .installing(release)
        defaults.set(release.version, forKey: Constants.Update.Keys.pendingVersion)
        let log = (Constants.Update.logPath as NSString).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Values go in as arguments, never into the script text
        process.arguments = ["-c", Self.installScript, "nook-update",
                             String(ProcessInfo.processInfo.processIdentifier),
                             newApp.path, destination.path, release.version,
                             homebrewPath ?? "", Constants.Update.cask, log]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            defaults.removeObject(forKey: Constants.Update.Keys.pendingVersion)
            state = .failed("Couldn't start the update: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Waits for Nook to quit, upgrades it, and opens the new version.
    /// $1 pid, $2 new app, $3 installed app, $4 version, $5 brew or empty, $6 cask, $7 log
    private static let installScript = #"""
    pid="$1"; new="$2"; dest="$3"; want="$4"; brew="$5"; cask="$6"; log="$7"
    mkdir -p "$(dirname "$log")"
    exec >>"$log" 2>&1
    echo "=== $(date): updating Nook to $want"
    n=0
    while kill -0 "$pid" 2>/dev/null; do
      n=$((n + 1)); [ "$n" -gt 3000 ] && { echo "Nook didn't quit; giving up"; exit 1; }
      sleep 0.2
    done
    version() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null; }
    if [ -n "$brew" ]; then
      echo "Upgrading with Homebrew"
      "$brew" upgrade --cask "$cask" || echo "brew upgrade failed"
    fi
    if [ "$(version "$dest")" != "$want" ]; then
      echo "Installing the downloaded copy"
      rm -rf "$dest.old"
      [ -d "$dest" ] && mv "$dest" "$dest.old"
      if /usr/bin/ditto "$new" "$dest"; then
        rm -rf "$dest.old"
      else
        echo "Copy failed; restoring the previous version"
        rm -rf "$dest"; [ -d "$dest.old" ] && mv "$dest.old" "$dest"
      fi
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null
    rm -rf "$(dirname "$new")"
    echo "Installed version: $(version "$dest")"
    /usr/bin/open "$dest"
    """#

    /// After a relaunch, says whether the update that quit Nook worked
    private func reportFinishedUpdate() {
        guard let wanted = defaults.string(forKey: Constants.Update.Keys.pendingVersion) else { return }
        defaults.removeObject(forKey: Constants.Update.Keys.pendingVersion)
        if Self.isVersion(wanted, newerThan: currentVersion) {
            state = .failed("The update to \(wanted) didn't finish. Details are in \(Constants.Update.logPath).")
            Notifier.post(title: "Nook wasn't updated",
                          body: "Still on \(currentVersion). Details are in \(Constants.Update.logPath).")
        } else {
            state = .upToDate
            Notifier.post(title: "Nook updated", body: "You're now on version \(currentVersion).")
        }
    }

    // MARK: Helpers

    /// Runs a tool and resumes once it exits, without blocking a thread to wait
    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let name = URL(fileURLWithPath: tool).lastPathComponent
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.tool(name))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        if (error as? URLError) != nil { return "Can't reach GitHub. Check your connection and try again." }
        return error.localizedDescription
    }

    enum UpdateError: LocalizedError {
        case noRelease, download, checksum, wrongApp, tool(String)

        var errorDescription: String? {
            switch self {
            case .noRelease: return "Couldn't find the latest Nook release on GitHub."
            case .download: return "The download didn't finish. Try again."
            case .checksum: return "The download doesn't match its published checksum, so it wasn't installed."
            case .wrongApp: return "The download isn't the expected Nook version, so it wasn't installed."
            case .tool(let name): return "Couldn't check the downloaded app (\(name) failed)."
            }
        }
    }
}
