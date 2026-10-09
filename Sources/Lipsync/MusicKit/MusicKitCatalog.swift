import Foundation
import LipsyncCore
import MusicKit

/// Finds the Apple Music version of Spotify tracks through MusicKit, for builds with a
/// MusicKit-enabled bundle ID (see README: optional MusicKit backend).
///
/// With an ISRC (from the Spotify Web API) the match is exact. Without one, Apple Music search
/// plus `Matcher` decides, and refuses anything that looks like a different version. Answers
/// are kept on disk, so each song is looked up once, ever.
@MainActor final class MusicKitCatalog: LipsyncCatalog {
    weak var engine: SyncEngine?
    var webAPI: SpotifyWebAPI?
    /// Reports catalog failures the user can act on (sign-in, subscription, developer token).
    var onError: ((Error) -> Void)?

    private let store = MatchStore()
    private var songs: [String: Song] = [:]
    private var inFlight: Set<String> = []
    private var urgentInFlight: Set<String> = []
    /// Lookups that failed for a transient reason, kept out of retries for a little while.
    private var recentFailures: [String: Date] = [:]

    private struct Match {
        var apple: AppleTrack
        var song: Song
        var confident: Bool
    }

    private enum Lookup {
        case found(Match)
        case notFound
        /// The request failed, so nothing was learned about the track.
        case failed
    }

    // MARK: TrackResolving

    func resolution(for track: SpotifyTrack) -> Resolution? {
        store.resolution(for: track.uri)
    }

    func resolve(_ tracks: [SpotifyTrack], urgent: Bool) {
        let now = Date()
        recentFailures = recentFailures.filter { $0.value > now }
        // An urgent lookup doesn't wait behind a background batch that happens to hold the
        // same track; whichever answers first is recorded.
        let fresh = tracks.filter {
            $0.kind.isMusic && store.resolution(for: $0.uri) == nil && recentFailures[$0.uri] == nil
                && !(urgent ? urgentInFlight : inFlight).contains($0.uri)
        }
        guard !fresh.isEmpty else { return }
        for track in fresh {
            if urgent {
                urgentInFlight.insert(track.uri)
            } else {
                inFlight.insert(track.uri)
            }
        }
        Task { @MainActor in
            if urgent {
                for track in fresh { await self.resolveNow(track) }
            } else {
                await self.resolveBatch(fresh)
            }
        }
    }

    func prefetch(_ tracks: [SpotifyTrack]) {
        resolve(tracks, urgent: false)
    }

    func markUnplayable(_ track: SpotifyTrack) {
        store.setUnavailable(for: track.uri, for: 24 * 3600)
    }

    /// The MusicKit song to hand to the player: from memory, the disk cache, or the catalog.
    func song(for appleID: String) async -> Song? {
        if let song = songs[appleID] { return song }
        if let data = store.songData(for: appleID), let song = try? JSONDecoder().decode(Song.self, from: data) {
            songs[appleID] = song
            return song
        }
        do {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(appleID))
            let song = try await request.response().items.first
            if let song { songs[appleID] = song }
            return song
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: Lookups

    /// A track the user just picked. Search by name and fetch its ISRC at the same time, and
    /// take the first confident answer.
    private func resolveNow(_ track: SpotifyTrack) async {
        var failed = false
        if track.isrc != nil {
            switch await lookUpByISRC([track])[track.uri] {
            case .found(let match)?:
                record(track, .found(match))
                return
            case .failed?:
                failed = true
            default:
                break
            }
        }
        let webAPI = self.webAPI
        let canFetchISRC = track.isrc == nil && track.trackID != nil && (webAPI?.isAvailable ?? false)
        var best: Match?
        var fuller: SpotifyTrack?
        await withTaskGroup(of: (Lookup, SpotifyTrack?).self) { group in
            group.addTask { @MainActor in (await self.search(track), nil) }
            if canFetchISRC, let webAPI, let id = track.trackID {
                group.addTask { @MainActor in
                    guard let full = try? await webAPI.tracks(ids: [id]).first else { return (.failed, nil) }
                    guard full.isrc != nil else { return (.notFound, full) }
                    return (await self.lookUpByISRC([full])[full.uri] ?? .notFound, full)
                }
            }
            for await (lookup, full) in group {
                if let full { fuller = full }
                switch lookup {
                case .found(let match):
                    if match.confident {
                        best = match
                        group.cancelAll()
                        return
                    }
                    best = best ?? match
                case .failed:
                    failed = true
                case .notFound:
                    break
                }
            }
        }
        if let best {
            record(track, .found(best))
            return
        }
        // The Web API's fuller credits can rescue a search that the notification's single
        // artist string couldn't.
        if let fuller, fuller.artists.count > track.artists.count {
            switch await search(fuller) {
            case .found(let match):
                record(track, .found(match))
                return
            case .failed:
                failed = true
            case .notFound:
                break
            }
        }
        record(track, failed ? .failed : .notFound)
    }

    /// Upcoming and context tracks: fetch missing ISRCs in bulk, match those in bulk, search the rest.
    private func resolveBatch(_ tracks: [SpotifyTrack]) async {
        var pending = tracks
        let missing = pending.filter { $0.isrc == nil }.compactMap(\.trackID)
        if !missing.isEmpty, let webAPI, webAPI.isAvailable, let full = try? await webAPI.tracks(ids: missing) {
            let byURI = Dictionary(full.map { ($0.uri, $0) }, uniquingKeysWith: { first, _ in first })
            pending = pending.map { byURI[$0.uri] ?? $0 }
        }
        let withISRC = pending.filter { $0.isrc != nil }
        var byISRC: [String: Lookup] = [:]
        for start in stride(from: 0, to: withISRC.count, by: 20) {
            let chunk = Array(withISRC[start..<min(start + 20, withISRC.count)])
            byISRC.merge(await lookUpByISRC(chunk), uniquingKeysWith: { first, _ in first })
        }
        for track in pending {
            if case .found(let match)? = byISRC[track.uri] {
                record(track, .found(match))
                continue
            }
            let searched = await search(track)
            if case .notFound = searched, case .failed? = byISRC[track.uri] {
                record(track, .failed)
            } else {
                record(track, searched)
            }
        }
    }

    private func lookUpByISRC(_ tracks: [SpotifyTrack]) async -> [String: Lookup] {
        let isrcs = tracks.compactMap(\.isrc)
        guard !isrcs.isEmpty else { return [:] }
        do {
            var request = MusicCatalogResourceRequest<Song>(matching: \.isrc, memberOf: isrcs)
            request.limit = 100
            let found = try await request.response().items
            let grouped = Dictionary(grouping: found, by: { ($0.isrc ?? "").uppercased() })
            var out: [String: Lookup] = [:]
            for track in tracks {
                guard let isrc = track.isrc?.uppercased(), let candidates = grouped[isrc],
                      let match = bestMatch(for: track, in: candidates, sameISRC: true) else {
                    out[track.uri] = .notFound
                    continue
                }
                out[track.uri] = .found(match)
            }
            return out
        } catch {
            report(error)
            return Dictionary(tracks.map { ($0.uri, Lookup.failed) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func search(_ track: SpotifyTrack) async -> Lookup {
        do {
            var request = MusicCatalogSearchRequest(term: Matcher.searchTerm(for: track), types: [Song.self])
            request.limit = 10
            let candidates = Array(try await request.response().songs)
            // A search result with the same ISRC is as good as an ISRC lookup.
            if let isrc = track.isrc?.uppercased(),
               let match = bestMatch(for: track, in: candidates.filter { $0.isrc?.uppercased() == isrc }, sameISRC: true) {
                return .found(match)
            }
            return bestMatch(for: track, in: candidates, sameISRC: false).map(Lookup.found) ?? .notFound
        } catch is CancellationError {
            return .notFound
        } catch {
            report(error)
            return .failed
        }
    }

    private func bestMatch(for track: SpotifyTrack, in songs: [Song], sameISRC: Bool) -> Match? {
        let bySongID = Dictionary(songs.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        guard let best = Matcher.best(for: track, among: songs.map(Self.appleTrack), sameISRC: sameISRC),
              let song = bySongID[best.id], let score = Matcher.score(track, best, sameISRC: sameISRC) else { return nil }
        return Match(apple: best, song: song, confident: sameISRC || score >= 0.95)
    }

    private func record(_ track: SpotifyTrack, _ lookup: Lookup) {
        inFlight.remove(track.uri)
        urgentInFlight.remove(track.uri)
        if case .matched? = store.resolution(for: track.uri) {
            // The other lookup already answered.
            engine?.resolutionChanged(for: track.uri)
            return
        }
        switch lookup {
        case .found(let match):
            songs[match.apple.id] = match.song
            store.setMatched(match.apple, song: try? JSONEncoder().encode(match.song), for: track.uri)
            Log.info("Matched \(track.name) — \(track.primaryArtist) → Apple Music \(match.apple.id) (\(match.apple.title), \(String(format: "%.1f", match.apple.duration))s vs \(String(format: "%.1f", track.duration))s)")
        case .notFound:
            store.setUnavailable(for: track.uri, for: 3 * 24 * 3600)
            Log.info("Not on Apple Music: \(track.name) — \(track.primaryArtist)")
        case .failed:
            recentFailures[track.uri] = Date().addingTimeInterval(30)
        }
        engine?.resolutionChanged(for: track.uri)
    }

    private func report(_ error: Error) {
        Log.warn("Apple Music catalog request failed: \(error)")
        onError?(error)
    }

    static func appleTrack(_ song: Song) -> AppleTrack {
        AppleTrack(id: song.id.rawValue, title: song.title, artist: song.artistName, album: song.albumTitle,
                   duration: song.duration ?? 0, isrc: song.isrc, isExplicit: song.contentRating.map { $0 == .explicit })
    }
}
