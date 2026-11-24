import AppKit
import Combine

/// The YouTube search shown in the island: results as you type, picked with
/// the arrow keys and played with Return.
final class MusicSearch: ObservableObject {
    @Published private(set) var isPresented = false
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    @Published var filter: MusicSearchFilter = .all {
        didSet { if filter != oldValue { scheduleSearch(after: 0) } }
    }
    @Published private(set) var results: [MusicSearchResult] = []
    @Published var selection = 0
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?
    /// Results that turned out not to play outside YouTube
    @Published private(set) var unplayable: [String: String] = [:]
    /// The result being checked before it plays
    @Published private(set) var checkingID: String?
    @Published private(set) var recentSearches: [String]
    /// Shown while nothing is typed: videos related to what you played
    @Published private(set) var recommendations: [MusicSearchResult] = []
    /// The title of the video the recommendations mostly come from
    @Published private(set) var recommendationSource: String?
    @Published private(set) var isLoadingRecommendations = false

    /// What the arrow keys and Return act on: the recommendations while
    /// nothing is typed, the search results otherwise
    var visibleResults: [MusicSearchResult] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? recommendations : results
    }

    private let player: MusicPlayer
    private var recommendationTask: Task<Void, Never>?
    /// The videos the current recommendations were drawn from, and when
    private var recommendationSeedIDs: [String] = []
    private var recommendationsLoaded = Date.distantPast
    private var searchTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?

    init(player: MusicPlayer) {
        self.player = player
        recentSearches = UserDefaults.standard.stringArray(forKey: Constants.Music.Keys.recentSearches) ?? []
    }

    func present() {
        isPresented = true
        selection = 0
        refreshRecommendations()
    }

    func dismiss() {
        isPresented = false
        searchTask?.cancel()
        playTask?.cancel()
        isSearching = false
        checkingID = nil
    }

    func playSelected(saving: Bool) {
        let results = visibleResults
        guard results.indices.contains(selection) else { return }
        play(results[selection], saving: saving)
    }

    /// Checks the result can play outside YouTube first, so a dud never
    /// interrupts what's playing now
    func play(_ result: MusicSearchResult, saving: Bool) {
        guard unplayable[result.id] == nil else { return }
        checkingID = result.id
        playTask?.cancel()
        playTask = Task { @MainActor [weak self] in
            do {
                _ = try await YouTube.playableTitle(of: result.station.source)
                guard let self = self, !Task.isCancelled else { return }
                self.checkingID = nil
                if saving { self.player.add(result.station) }
                self.player.play(result.station)
                self.remember(self.query)
                self.dismiss()
            } catch {
                guard let self = self, !Task.isCancelled else { return }
                self.checkingID = nil
                self.unplayable[result.id] = (error as? LocalizedError)?.errorDescription ?? "Can't play this"
            }
        }
    }

    /// Arrow keys, Return and Esc while the search is open. Returns false for
    /// keys the text field should get.
    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case Constants.Island.escapeKeyCode:
            dismiss()
        case 125: // down
            let count = visibleResults.count
            if count > 0 { selection = min(selection + 1, count - 1) }
        case 126: // up
            selection = max(selection - 1, 0)
        case 36, 76: // return, keypad enter
            playSelected(saving: event.modifierFlags.contains(.command))
        default:
            return false
        }
        return true
    }

    private func scheduleSearch(after delay: TimeInterval = Constants.Music.searchDebounce) {
        searchTask?.cancel()
        let query = self.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            results = []
            isSearching = false
            errorMessage = nil
            selection = 0
            return
        }
        let filter = self.filter
        isSearching = true
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                let results = try await YouTube.search(query, filter: filter)
                guard let self = self, !Task.isCancelled else { return }
                self.results = results
                self.selection = 0
                self.errorMessage = results.isEmpty ? "No results" : nil
            } catch {
                guard let self = self, !Task.isCancelled else { return }
                self.results = []
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? "Search failed"
            }
            self?.isSearching = false
        }
    }

    // MARK: Recommendations

    /// Loads videos related to the last few you played, unless the ones
    /// shown were drawn from the same videos a short while ago
    private func refreshRecommendations() {
        var seeds: [(id: String, title: String)] = []
        if let id = player.videoID { seeds.append((id, player.title ?? "")) }
        for station in player.recentlyPlayed {
            if case .video(let id) = station.source { seeds.append((id, station.name)) }
        }
        var seen = Set<String>()
        seeds = Array(seeds.filter { seen.insert($0.id).inserted }.prefix(Constants.Music.recommendationSeeds))
        let seedIDs = seeds.map(\.id)
        guard !seedIDs.isEmpty else {
            recommendations = []
            recommendationSource = nil
            return
        }
        if seedIDs == recommendationSeedIDs, !recommendations.isEmpty,
           Date().timeIntervalSince(recommendationsLoaded) < Constants.Music.recommendationLifetime {
            return
        }

        // Played or saved already: not worth recommending
        var known = Set(seedIDs)
        for station in player.recentlyPlayed + player.customStations {
            if case .video(let id) = station.source { known.insert(id) }
        }
        recommendationTask?.cancel()
        isLoadingRecommendations = true
        recommendationTask = Task { @MainActor [weak self] in
            // Each seed's list in its own order, fetched side by side
            let lists = await withTaskGroup(of: (Int, [MusicSearchResult]).self) { group in
                for (index, seed) in seeds.enumerated() {
                    group.addTask { (index, (try? await YouTube.related(to: seed.id)) ?? []) }
                }
                var lists = Array(repeating: [MusicSearchResult](), count: seeds.count)
                for await (index, list) in group { lists[index] = list }
                return lists
            }
            guard let self = self, !Task.isCancelled else { return }
            // Take turns between the seeds so no single video crowds out the rest
            var picked: [MusicSearchResult] = []
            var pickedIDs = known
            var position = 0
            while picked.count < Constants.Music.recommendationLimit,
                  lists.contains(where: { $0.count > position }) {
                for list in lists where list.count > position {
                    let candidate = list[position]
                    if pickedIDs.insert(candidate.id).inserted { picked.append(candidate) }
                }
                position += 1
            }
            self.recommendations = Array(picked.prefix(Constants.Music.recommendationLimit))
            self.recommendationSource = seeds.first.map { $0.title.isEmpty ? nil : $0.title } ?? nil
            self.recommendationSeedIDs = seedIDs
            self.recommendationsLoaded = Date()
            self.isLoadingRecommendations = false
            if self.query.trimmingCharacters(in: .whitespaces).isEmpty { self.selection = 0 }
        }
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Constants.Music.Keys.recentSearches)
    }

    private func remember(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(Constants.Music.recentSearchLimit))
        UserDefaults.standard.set(recentSearches, forKey: Constants.Music.Keys.recentSearches)
    }
}
