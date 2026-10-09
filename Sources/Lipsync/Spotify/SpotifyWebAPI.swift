import Foundation
import LipsyncCore

/// The few Spotify Web API calls Lipsync needs: what's queued next (so the next Apple Music
/// song can be buffered before it's due), ISRCs (exact song matching) and the player's
/// repeat mode and context.
@MainActor final class SpotifyWebAPI {
    enum APIError: LocalizedError {
        case rateLimited(TimeInterval)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .rateLimited(let seconds): return "Spotify asked Lipsync to slow down for \(Int(seconds))s."
            case .http(let status, _): return "Spotify returned HTTP \(status)."
            }
        }
    }

    struct Queue {
        var current: SpotifyTrack?
        var upcoming: [SpotifyTrack]
    }

    struct PlayerState {
        var trackURI: String?
        var isPlaying: Bool
        var repeatState: String
        var contextURI: String?
        var deviceName: String?
        var deviceType: String?
    }

    private let auth: SpotifyAuth
    private var blockedUntil = Date.distantPast
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    var isAvailable: Bool { auth.isConnected && Date() >= blockedUntil }

    func queue() async throws -> Queue? {
        guard let body: QueueJSON = try await get("me/player/queue") else { return nil }
        return Queue(current: body.currently_playing?.track, upcoming: body.queue.compactMap(\.track))
    }

    func playerState() async throws -> PlayerState? {
        guard let body: PlayerJSON = try await get("me/player", query: [URLQueryItem(name: "additional_types", value: "track,episode")]) else { return nil }
        return PlayerState(trackURI: body.item?.uri, isPlaying: body.is_playing ?? false, repeatState: body.repeat_state ?? "off",
                           contextURI: body.context?.uri, deviceName: body.device?.name, deviceType: body.device?.type)
    }

    /// Full track objects, which carry ISRCs. Up to 50 ids per request.
    func tracks(ids: [String]) async throws -> [SpotifyTrack] {
        var out: [SpotifyTrack] = []
        for start in stride(from: 0, to: ids.count, by: 50) {
            let chunk = Array(ids[start..<min(start + 50, ids.count)])
            do {
                let body: TracksJSON? = try await get("tracks", query: [URLQueryItem(name: "ids", value: chunk.joined(separator: ","))])
                out += body?.tracks.compactMap { $0?.track } ?? []
            } catch APIError.http(let status, _) where status == 403 || status == 404 {
                // Some apps can only fetch tracks one at a time.
                for id in chunk {
                    if let single: ItemJSON = try await get("tracks/\(id)"), let track = single.track { out.append(track) }
                }
            }
        }
        return out
    }

    /// The tracks of the playlist or album being played, for looking them up ahead of time.
    func contextTracks(uri: String, limit: Int = 200) async throws -> [SpotifyTrack] {
        let parts = uri.split(separator: ":")
        guard parts.count == 3 else { return [] }
        let id = String(parts[2])
        switch parts[1] {
        case "playlist":
            var out: [SpotifyTrack] = []
            var offset = 0
            while out.count < limit {
                let page: PlaylistItemsJSON? = try await get("playlists/\(id)/tracks", query: [
                    URLQueryItem(name: "limit", value: "100"),
                    URLQueryItem(name: "offset", value: String(offset)),
                ])
                guard let page else { break }
                out += page.items.compactMap { ($0.track ?? $0.item)?.track }
                guard page.next != nil, !page.items.isEmpty else { break }
                offset += page.items.count
            }
            return out
        case "album":
            let page: AlbumTracksJSON? = try await get("albums/\(id)/tracks", query: [URLQueryItem(name: "limit", value: "50")])
            // Album listings omit ISRCs; fetch the full tracks for them.
            let ids = page?.items.compactMap { $0.uri?.split(separator: ":").last.map(String.init) } ?? []
            return try await tracks(ids: ids)
        default:
            return []
        }
    }

    /// The user's most recently liked songs.
    func savedTracks(limit: Int) async throws -> [SpotifyTrack] {
        var out: [SpotifyTrack] = []
        var offset = 0
        while out.count < limit {
            let page: SavedTracksJSON? = try await get("me/tracks", query: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(offset)),
            ])
            guard let page, !page.items.isEmpty else { break }
            out += page.items.compactMap { $0.track?.track }
            guard page.next != nil else { break }
            offset += page.items.count
        }
        return out
    }

    /// URIs of the user's own and followed playlists.
    func playlistURIs(limit: Int) async throws -> [String] {
        let page: PlaylistsJSON? = try await get("me/playlists", query: [URLQueryItem(name: "limit", value: String(min(limit, 50)))])
        return page?.items.compactMap(\.uri) ?? []
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], retried: Bool = false) async throws -> T? {
        if Date() < blockedUntil { throw APIError.rateLimited(blockedUntil.timeIntervalSinceNow) }
        var components = URLComponents(string: "https://api.spotify.com/v1/" + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200:
            return try JSONDecoder().decode(T.self, from: data)
        case 204:
            return nil
        case 401 where !retried:
            _ = try await auth.refresh()
            return try await get(path, query: query, retried: true)
        case 429:
            let wait = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30
            blockedUntil = Date().addingTimeInterval(wait)
            Log.warn("Spotify Web API rate limited for \(wait)s")
            throw APIError.rateLimited(wait)
        case let status:
            throw APIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - JSON

private struct NameJSON: Decodable {
    let name: String?
}

private struct ItemJSON: Decodable {
    let uri: String?
    let name: String?
    let duration_ms: Int?
    let explicit: Bool?
    let artists: [NameJSON]?
    let album: NameJSON?
    let show: NameJSON?
    let external_ids: ExternalIDs?

    struct ExternalIDs: Decodable {
        let isrc: String?
    }

    var track: SpotifyTrack? {
        guard let uri, !uri.isEmpty else { return nil }
        let artistNames = artists?.compactMap(\.name) ?? show?.name.map { [$0] } ?? []
        return SpotifyTrack(uri: uri, name: name ?? "", artists: artistNames, album: album?.name ?? "",
                            durationMs: duration_ms ?? 0, isrc: external_ids?.isrc, isExplicit: explicit)
    }
}

private struct QueueJSON: Decodable {
    let currently_playing: ItemJSON?
    let queue: [ItemJSON]
}

private struct PlayerJSON: Decodable {
    struct Device: Decodable {
        let name: String?
        let type: String?
    }
    struct Context: Decodable {
        let uri: String?
    }
    let device: Device?
    let repeat_state: String?
    let context: Context?
    let is_playing: Bool?
    let item: ItemJSON?
}

private struct TracksJSON: Decodable {
    let tracks: [ItemJSON?]
}

private struct PlaylistItemsJSON: Decodable {
    struct Entry: Decodable {
        let track: ItemJSON?
        let item: ItemJSON?
    }
    let items: [Entry]
    let next: String?
}

private struct AlbumTracksJSON: Decodable {
    let items: [ItemJSON]
}

private struct SavedTracksJSON: Decodable {
    struct Entry: Decodable {
        let track: ItemJSON?
    }
    let items: [Entry]
    let next: String?
}

private struct PlaylistsJSON: Decodable {
    struct Entry: Decodable {
        let uri: String?
    }
    let items: [Entry]
}
