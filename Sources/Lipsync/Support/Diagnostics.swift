import Foundation
import LipsyncCore

/// Command-line checks, for confirming the moving parts on a new Mac:
///
///     Lipsync.app/Contents/MacOS/Lipsync --play-in-music [store id]
///     Lipsync.app/Contents/MacOS/Lipsync --match "Title" "Artist" ["Album"] [seconds]
enum Diagnostics {
    static func run(_ arguments: [String]) -> Never {
        Task { @MainActor in
            switch arguments[1] {
            case "--play-in-music":
                await playInMusic(arguments.count > 2 ? arguments[2] : nil)
            case "--match":
                await match(Array(arguments.dropFirst(2)))
            default:
                print("""
                usage:
                  Lipsync --play-in-music [store id]   start a song in Music the way Lipsync does
                  Lipsync --match "Title" "Artist" ["Album"] [seconds]   show how a track matches
                """)
            }
            exit(0)
        }
        dispatchMain()
    }

    @MainActor private static func playInMusic(_ storeID: String?) async {
        let remote = MediaRemote.shared
        print("MediaRemote playback queue functions: \(remote.isAvailable ? "found" : "MISSING")")
        guard remote.isAvailable else { return }
        var id = storeID
        if id == nil, case .success(let songs) = await ITunesCatalog.search("Bohemian Rhapsody Queen", storefront: "us"), let first = songs.first {
            id = first.id
            print("Using \(first.title) — \(first.artist) (\(first.id))")
        }
        guard let id else {
            print("No store id to play")
            return
        }
        let scripting = MusicScripting()
        if !scripting.runner.isRunning { print("Open the Music app first, then run this again."); return }
        let accepted = await remote.setQueue(storeIDs: [id], playNow: true)
        print("Music \(accepted ? "accepted" : "refused") the queue")
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if let snapshot = await scripting.snapshot() {
            print("Music is \(snapshot.state): \(snapshot.name) — \(snapshot.artist) at \(String(format: "%.1f", snapshot.position))s")
        } else {
            print("Couldn't read Music (allow Automation for the app running this command)")
        }
    }

    @MainActor private static func match(_ args: [String]) async {
        guard args.count >= 2 else {
            print("usage: Lipsync --match \"Title\" \"Artist\" [\"Album\"] [seconds]")
            return
        }
        let seconds = args.count > 3 ? Double(args[3]) : nil
        let track = SpotifyTrack(uri: "spotify:track:diagnostic", name: args[0], artists: [args[1]],
                                 album: args.count > 2 ? args[2] : "", durationMs: Int((seconds ?? 0) * 1000))
        let storefront = (UserDefaults.standard.string(forKey: "storefront") ?? Locale.current.region?.identifier ?? "us").lowercased()
        let term = Matcher.searchTerm(for: track)
        print("Searching Apple Music (\(storefront)) for: \(term)")
        switch await ITunesCatalog.search(term, storefront: storefront) {
        case .failure(let error):
            print("Search failed: \(error)")
        case .success(let candidates):
            for candidate in candidates {
                let verdict: String
                if seconds == nil {
                    verdict = "(give a length to score)"
                } else if let score = Matcher.score(track, candidate, sameISRC: false) {
                    verdict = String(format: "score %.2f", score)
                } else {
                    verdict = "rejected"
                }
                print("  \(candidate.id)  \(candidate.title) — \(candidate.artist) [\(candidate.album ?? "")] \(String(format: "%.0f", candidate.duration))s  \(verdict)")
            }
            guard seconds != nil else { return }
            var best = Matcher.best(for: track, among: candidates, sameISRC: false)
            if best == nil {
                print("Not in the search results; checking \(args[1])'s catalog")
                if case .success(let id?) = await ITunesCatalog.artistID(named: args[1], storefront: storefront),
                   case .success(let songs) = await ITunesCatalog.songs(ofArtist: id, storefront: storefront) {
                    best = Matcher.best(for: track, among: songs, sameISRC: false)
                }
            }
            print(best.map { "Match: \($0.id) \($0.title) — \($0.artist) [\($0.album ?? "")]" } ?? "No match: Lipsync would play this from Spotify")
        }
    }
}
