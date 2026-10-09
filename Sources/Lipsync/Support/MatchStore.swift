import Foundation
import LipsyncCore

/// Spotify URI → Apple Music answer, persisted in Application Support.
@MainActor final class MatchStore {
    private struct Entry: Codable {
        var apple: AppleTrack?
        var song: Data?
        /// For "not on Apple Music" answers, when to ask again.
        var retryAfter: Date?
        /// The search that found nothing. Answers from an older search are asked again at once.
        var search: Int?
    }

    /// Raise when the catalog search improves, so the songs it missed are looked up again.
    private static let searchVersion = 2

    private var entries: [String: Entry] = [:]
    private var uriForSong: [String: String] = [:]
    private var saveScheduled = false

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lipsync", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("matches.json")
    }()

    init() {
        guard let data = try? Data(contentsOf: Self.url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
        for (uri, entry) in decoded {
            if let id = entry.apple?.id { uriForSong[id] = uri }
        }
        Log.info("Loaded \(entries.count) cached matches")
    }

    func resolution(for uri: String) -> Resolution? {
        guard let entry = entries[uri] else { return nil }
        if let apple = entry.apple { return .matched(apple) }
        if let retryAfter = entry.retryAfter, retryAfter > Date(), (entry.search ?? 1) >= Self.searchVersion { return .unavailable }
        return nil
    }

    func songData(for appleID: String) -> Data? {
        uriForSong[appleID].flatMap { entries[$0]?.song }
    }

    func setMatched(_ apple: AppleTrack, song: Data?, for uri: String) {
        entries[uri] = Entry(apple: apple, song: song, retryAfter: nil)
        uriForSong[apple.id] = uri
        scheduleSave()
    }

    func setUnavailable(for uri: String, for seconds: TimeInterval) {
        entries[uri] = Entry(apple: nil, song: nil, retryAfter: Date().addingTimeInterval(seconds), search: Self.searchVersion)
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let snapshot = self.entries
            let url = Self.url
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
