import Foundation
import LipsyncCore

/// What the app needs from a catalog beyond what the engine asks.
@MainActor protocol LipsyncCatalog: TrackResolving {
    var engine: SyncEngine? { get set }
    var webAPI: SpotifyWebAPI? { get set }
    var onError: ((Error) -> Void)? { get set }
    /// Low-priority lookups: the playlist being played, the library.
    func prefetch(_ tracks: [SpotifyTrack])
}

/// Finds the Apple Music version of Spotify tracks with Apple's public iTunes Search API,
/// which needs no account or key.
///
/// The API has no ISRCs, so `Matcher` decides by title, artist, length and album, and refuses
/// anything that looks like a different version (live, remix, edit). Apple allows about 20
/// searches a minute, so lookups are rationed: the song just clicked goes first, then
/// Spotify's next songs, then the playlist being played, then the library. Answers are kept on
/// disk, so each song is looked up once.
@MainActor final class ITunesCatalog: LipsyncCatalog {
    weak var engine: SyncEngine?
    var webAPI: SpotifyWebAPI?
    var onError: ((Error) -> Void)?

    private let store = MatchStore()
    private let limiter = RateLimiter(perMinute: 19)
    private let storefront: String
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        return URLSession(configuration: configuration)
    }()

    private var urgentInFlight: Set<String> = []
    private var upcomingQueue: [SpotifyTrack] = []
    private var prefetchQueue: [SpotifyTrack] = []
    private var queued: Set<String> = []
    private var worker: Task<Void, Never>?
    /// Lookups that failed for a transient reason, kept out of retries for a little while.
    private var recentFailures: [String: Date] = [:]
    /// The catalog fallback's answers (artists, their albums, track lists), which many songs
    /// share, kept for the session.
    private var sessionCache: [String: Any] = [:]

    enum Lookup {
        case found(AppleTrack)
        case notFound
        case failed
    }

    enum CatalogError: LocalizedError {
        case rateLimited
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .rateLimited: return "Apple's search asked Lipsync to slow down."
            case .http(let status): return "Apple's search returned HTTP \(status)."
            }
        }
    }

    init() {
        let configured = UserDefaults.standard.string(forKey: "storefront")
        storefront = (configured ?? Locale.current.region?.identifier ?? "us").lowercased()
    }

    // MARK: TrackResolving

    func resolution(for track: SpotifyTrack) -> Resolution? {
        store.resolution(for: track.uri)
    }

    func resolve(_ tracks: [SpotifyTrack], urgent: Bool) {
        pruneFailures()
        for track in tracks where needsLookup(track) {
            if urgent {
                guard urgentInFlight.insert(track.uri).inserted else { continue }
                Task { @MainActor in
                    await self.lookUp(track, priority: .urgent)
                    self.urgentInFlight.remove(track.uri)
                }
            } else if queued.insert(track.uri).inserted {
                upcomingQueue.append(track)
            }
        }
        startWorker()
    }

    func prefetch(_ tracks: [SpotifyTrack]) {
        pruneFailures()
        for track in tracks where needsLookup(track) && queued.insert(track.uri).inserted {
            prefetchQueue.append(track)
        }
        startWorker()
    }

    func markUnplayable(_ track: SpotifyTrack) {
        store.setUnavailable(for: track.uri, for: 24 * 3600)
    }

    // MARK: Lookups

    private func needsLookup(_ track: SpotifyTrack) -> Bool {
        track.kind.isMusic && store.resolution(for: track.uri) == nil && recentFailures[track.uri] == nil
    }

    private func pruneFailures() {
        let now = Date()
        recentFailures = recentFailures.filter { $0.value > now }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { @MainActor in
            while let (track, priority) = self.nextQueued() {
                guard self.store.resolution(for: track.uri) == nil, !self.urgentInFlight.contains(track.uri) else { continue }
                await self.lookUp(track, priority: priority)
            }
            self.worker = nil
        }
    }

    private func nextQueued() -> (SpotifyTrack, RateLimiter.Priority)? {
        if !upcomingQueue.isEmpty {
            let track = upcomingQueue.removeFirst()
            queued.remove(track.uri)
            return (track, .upcoming)
        }
        if !prefetchQueue.isEmpty {
            let track = prefetchQueue.removeFirst()
            queued.remove(track.uri)
            return (track, .background)
        }
        return nil
    }

    private func lookUp(_ track: SpotifyTrack, priority: RateLimiter.Priority) async {
        var terms = [Matcher.searchTerm(for: track)]
        // A song just clicked gets a second try by title and album, which rescues credits
        // the artist search couldn't find.
        let core = Matcher.splitAnnotations(track.name).core.trimmingCharacters(in: .whitespaces)
        if priority == .urgent, !track.album.isEmpty, Matcher.normalizeTitle(track.album) != Matcher.normalizeTitle(core) {
            terms.append("\(core) \(track.album)")
        }
        var failed = false
        for term in terms {
            guard await limiter.acquire(priority) else {
                failed = true
                break
            }
            switch await Self.search(term, storefront: storefront, session: session) {
            case .success(let candidates):
                if let match = Matcher.best(for: track, among: candidates, sameISRC: false) {
                    record(track, .found(match))
                    return
                }
            case .failure(let error):
                failed = true
                reportFailure(error)
            }
            if failed { break }
        }
        // Apple's search index misses some songs outright, new releases especially: 100 gecs'
        // "Dumbest Girl Alive" never comes back, by any term. The catalog still has them.
        if !failed {
            switch await catalogMatch(for: track, priority: priority) {
            case .found(let match):
                record(track, .found(match))
                return
            case .notFound:
                break
            case .failed:
                failed = true
            }
        }
        record(track, failed ? .failed : .notFound)
    }

    /// Looks for the song on its album, then among the artist's songs. The album goes first
    /// because Apple lists at most 200 of an artist's songs, while an album has every track.
    func catalogMatch(for track: SpotifyTrack, priority: RateLimiter.Priority) async -> Lookup {
        guard !track.primaryArtist.isEmpty else { return .notFound }
        let artistKey = "artist:" + Matcher.normalizeArtist(track.primaryArtist)
        guard let artist = await remembered(artistKey, priority, {
            await Self.artistID(named: track.primaryArtist, storefront: self.storefront, session: self.session)
        }) else { return .failed }
        guard let artistID = artist else { return .notFound }

        if !track.album.isEmpty {
            guard let albums = await remembered("albums:\(artistID)", priority, {
                await Self.albums(ofArtist: artistID, storefront: self.storefront, session: self.session)
            }) else { return .failed }
            let wanted = Matcher.normalizeTitle(track.album)
            if let album = albums.first(where: { Matcher.normalizeTitle($0.name) == wanted }) {
                guard let songs = await remembered("songs:\(album.id)", priority, {
                    await Self.songs(of: album.id, storefront: self.storefront, session: self.session)
                }) else { return .failed }
                if let match = Matcher.best(for: track, among: songs, sameISRC: false) { return .found(match) }
            }
        }

        guard let songs = await remembered("songs:\(artistID)", priority, {
            await Self.songs(of: artistID, storefront: self.storefront, session: self.session)
        }) else { return .failed }
        return Matcher.best(for: track, among: songs, sameISRC: false).map(Lookup.found) ?? .notFound
    }

    /// One rationed request whose answer is kept for the session. nil if it failed.
    private func remembered<Value>(_ key: String, _ priority: RateLimiter.Priority,
                                   _ fetch: () async -> Result<Value, Error>) async -> Value? {
        if let hit = sessionCache[key] as? Remembered<Value> { return hit.value }
        guard await limiter.acquire(priority) else { return nil }
        switch await fetch() {
        case .success(let value):
            sessionCache[key] = Remembered(value: value)
            return value
        case .failure(let error):
            reportFailure(error)
            return nil
        }
    }

    private struct Remembered<Value> {
        let value: Value
    }

    private func reportFailure(_ error: Error) {
        if case CatalogError.rateLimited = error {
            limiter.backOff(seconds: 60)
        }
        Log.warn("Apple Music search failed: \(error)")
        onError?(error)
    }

    /// One iTunes Search API request: streamable songs only.
    nonisolated static func search(_ term: String, storefront: String, session: URLSession = .shared) async -> Result<[AppleTrack], Error> {
        await request("search", [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
        ], storefront: storefront, session: session).map { $0.compactMap(\.appleTrack) }
    }

    /// The Apple Music artist with exactly this name, if there is one.
    nonisolated static func artistID(named name: String, storefront: String, session: URLSession = .shared) async -> Result<Int?, Error> {
        let wanted = Matcher.normalizeArtist(name)
        return await request("search", [
            URLQueryItem(name: "term", value: name),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "5"),
        ], storefront: storefront, session: session).map { results in
            results.first { $0.artistName.map(Matcher.normalizeArtist) == wanted }?.artistId
        }
    }

    struct Album: Sendable {
        let id: Int
        let name: String
    }

    /// The artist's albums and singles.
    nonisolated static func albums(ofArtist id: Int, storefront: String, session: URLSession = .shared) async -> Result<[Album], Error> {
        await request("lookup", [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "200"),
        ], storefront: storefront, session: session).map { results in
            results.compactMap { result in
                guard result.wrapperType == "collection", let id = result.collectionId, let name = result.collectionName else { return nil }
                return Album(id: id, name: name)
            }
        }
    }

    /// The streamable songs of an album, or up to 200 of an artist's.
    nonisolated static func songs(of id: Int, storefront: String, session: URLSession = .shared) async -> Result<[AppleTrack], Error> {
        await request("lookup", [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "200"),
        ], storefront: storefront, session: session).map { $0.compactMap(\.appleTrack) }
    }

    private nonisolated static func request(_ path: String, _ items: [URLQueryItem], storefront: String,
                                            session: URLSession) async -> Result<[SearchJSON.Result], Error> {
        var components = URLComponents(string: "https://itunes.apple.com/\(path)")!
        components.queryItems = items + [URLQueryItem(name: "country", value: storefront)]
        do {
            let (data, response) = try await session.data(from: components.url!)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 403 || status == 429 { return .failure(CatalogError.rateLimited) }
            guard status == 200 else { return .failure(CatalogError.http(status)) }
            return .success(try JSONDecoder().decode(SearchJSON.self, from: data).results)
        } catch {
            return .failure(error)
        }
    }

    var storefrontCode: String { storefront }

    private func record(_ track: SpotifyTrack, _ lookup: Lookup) {
        if case .matched? = store.resolution(for: track.uri) {
            engine?.resolutionChanged(for: track.uri)
            return
        }
        switch lookup {
        case .found(let match):
            store.setMatched(match, song: nil, for: track.uri)
            Log.info("Matched \(track.name) — \(track.primaryArtist) → Apple Music \(match.id) (\(match.title), \(String(format: "%.1f", match.duration))s vs \(String(format: "%.1f", track.duration))s)")
        case .notFound:
            store.setUnavailable(for: track.uri, for: 3 * 24 * 3600)
            Log.info("Not on Apple Music: \(track.name) — \(track.primaryArtist)")
        case .failed:
            recentFailures[track.uri] = Date().addingTimeInterval(30)
        }
        engine?.resolutionChanged(for: track.uri)
    }
}

/// A token bucket for Apple's search limit. The song just clicked may spend the last token;
/// prefetching keeps a reserve for it.
@MainActor final class RateLimiter {
    enum Priority {
        case urgent, upcoming, background
    }

    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill = Uptime.now()
    private var blockedUntil = 0.0

    init(perMinute: Double) {
        capacity = perMinute
        refillPerSecond = perMinute / 60
        tokens = perMinute
    }

    /// Waits for a token. A song just clicked waits at most 3 seconds, after which Spotify
    /// plays it rather than keep the user waiting.
    func acquire(_ priority: Priority) async -> Bool {
        let reserve: Double
        switch priority {
        case .urgent: reserve = 0
        case .upcoming: reserve = 3
        case .background: reserve = 8
        }
        let deadline = priority == .urgent ? Uptime.now() + 3 : .infinity
        while true {
            let now = Uptime.now()
            tokens = min(capacity, tokens + (now - lastRefill) * refillPerSecond)
            lastRefill = now
            if now >= blockedUntil, tokens >= 1 + reserve {
                tokens -= 1
                return true
            }
            if now > deadline { return false }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func backOff(seconds: Double) {
        blockedUntil = Uptime.now() + seconds
        tokens = 0
    }
}

private struct SearchJSON: Decodable {
    struct Result: Decodable {
        let wrapperType: String?
        let kind: String?
        let artistId: Int?
        let collectionId: Int?
        let trackId: Int?
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Double?
        let trackExplicitness: String?
        let isStreamable: Bool?

        var appleTrack: AppleTrack? {
            guard kind == nil || kind == "song", isStreamable != false, let trackId, let trackName, let artistName else { return nil }
            let explicit: Bool? = {
                switch trackExplicitness {
                case "explicit": return true
                case "notExplicit", "cleaned": return false
                default: return nil
                }
            }()
            return AppleTrack(id: String(trackId), title: trackName, artist: artistName, album: collectionName,
                              duration: (trackTimeMillis ?? 0) / 1000, isExplicit: explicit)
        }
    }
    let results: [Result]
}
