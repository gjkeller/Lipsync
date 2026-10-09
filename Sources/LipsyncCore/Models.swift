import Foundation

/// What kind of item Spotify is playing, read from its URI.
public enum SpotifyItemKind: String, Sendable, Codable {
    case track, episode, ad, local, other

    public init(uri: String) {
        if uri.hasPrefix("spotify:track:") {
            self = .track
        } else if uri.hasPrefix("spotify:episode:") {
            self = .episode
        } else if uri.hasPrefix("spotify:ad:") {
            self = .ad
        } else if uri.hasPrefix("spotify:local:") {
            self = .local
        } else {
            self = .other
        }
    }

    /// Whether Apple Music could have an equivalent. Podcasts, audiobooks and ads always play
    /// through Spotify.
    public var isMusic: Bool { self == .track || self == .local }
}

public struct SpotifyTrack: Hashable, Sendable, Codable {
    public var uri: String
    public var name: String
    /// Primary artist first. The desktop client's notifications only carry one artist string;
    /// the Web API fills in the rest.
    public var artists: [String]
    public var album: String
    public var durationMs: Int
    public var isrc: String?
    public var isExplicit: Bool?

    public init(uri: String, name: String, artists: [String], album: String, durationMs: Int, isrc: String? = nil, isExplicit: Bool? = nil) {
        self.uri = uri
        self.name = name
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
        self.isrc = isrc
        self.isExplicit = isExplicit
    }

    public var kind: SpotifyItemKind { SpotifyItemKind(uri: uri) }
    public var duration: Double { Double(durationMs) / 1000 }
    public var primaryArtist: String { artists.first ?? "" }

    /// The base-62 id for `spotify:track:` URIs, as the Web API expects it.
    public var trackID: String? {
        let prefix = "spotify:track:"
        guard uri.hasPrefix(prefix) else { return nil }
        return String(uri.dropFirst(prefix.count))
    }
}

/// An Apple Music catalog song, reduced to what matching and syncing need.
public struct AppleTrack: Hashable, Sendable, Codable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: Double
    public var isrc: String?
    public var isExplicit: Bool?

    public init(id: String, title: String, artist: String, album: String? = nil, duration: Double, isrc: String? = nil, isExplicit: Bool? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.isrc = isrc
        self.isExplicit = isExplicit
    }
}

/// One reading of the Spotify desktop client's state.
public struct SpotifyObservation: Sendable {
    /// nil when Spotify has nothing loaded.
    public var track: SpotifyTrack?
    public var isPlaying: Bool
    /// Seconds into the track.
    public var position: Double
    /// Engine clock time at which `position` was true.
    public var time: Double
    /// Distributed notifications are authoritative. Polled AppleScript readings can race with
    /// track changes, so a polled track change is only trusted once a second poll agrees.
    public var isAuthoritative: Bool
    /// When the reading began. A poll that began before the latest notification can carry
    /// state from before it, however late it arrives.
    public var issuedAt: Double

    public init(track: SpotifyTrack?, isPlaying: Bool, position: Double, time: Double, isAuthoritative: Bool, issuedAt: Double? = nil) {
        self.track = track
        self.isPlaying = isPlaying
        self.position = position
        self.time = time
        self.isAuthoritative = isAuthoritative
        self.issuedAt = issuedAt ?? time
    }
}

public enum AppleStatus: Sendable, Equatable {
    case playing, paused, stopped
}

/// One reading of the Apple Music player.
public struct AppleObservation: Sendable, Equatable {
    /// Identifies the queue entry, so two plays of the same song are still two entries.
    public var entryID: String?
    public var songID: String?
    public var status: AppleStatus
    public var position: Double
    public var time: Double

    public init(entryID: String?, songID: String?, status: AppleStatus, position: Double, time: Double) {
        self.entryID = entryID
        self.songID = songID
        self.status = status
        self.position = position
        self.time = time
    }
}

public enum Resolution: Sendable, Equatable {
    case matched(AppleTrack)
    case unavailable
}

/// Why a track is playing through Spotify instead of Apple Music.
public enum FallbackReason: String, Sendable {
    case notMusic
    case notOnAppleMusic
    case appleTimedOut
    case applePlaybackFailed
}
