import Foundation

// MARK: - Collaborators

/// Monotonic seconds. Observations carry times from the same clock.
@MainActor public protocol EngineClock: AnyObject {
    var now: Double { get }
}

/// Commands to the Spotify desktop client. Fire-and-forget: the engine learns the outcome from
/// later observations, like any other change.
@MainActor public protocol SpotifyCommanding: AnyObject {
    func play()
    func pause()
    func next()
    func seek(to seconds: Double)
}

/// Commands to the Apple Music player. Implementations must run them in the order received.
@MainActor public protocol AppleCommanding: AnyObject {
    /// Replace the queue with `tracks` (the first is current) and start at `position`, playing
    /// or paused.
    func start(_ tracks: [AppleTrack], at position: Double, play: Bool)
    /// Replace everything after the current entry.
    func setUpcoming(_ tracks: [AppleTrack])
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double)
    func skipToNext()
    func setRepeatOne(_ on: Bool)
}

@MainActor public protocol SpotifyMuting: AnyObject {
    func setSpotifyMuted(_ muted: Bool)
}

@MainActor public protocol TrackResolving: AnyObject {
    /// nil while unknown. Calls `SyncEngine.resolutionChanged(for:)` when an answer arrives.
    func resolution(for track: SpotifyTrack) -> Resolution?
    func resolve(_ tracks: [SpotifyTrack], urgent: Bool)
    /// Apple Music listed the song but would not play it.
    func markUnplayable(_ track: SpotifyTrack)
}

@MainActor public protocol SyncEngineDelegate: AnyObject {
    func syncEngine(_ engine: SyncEngine, fellBackToSpotifyFor track: SpotifyTrack, reason: FallbackReason)
    func syncEngine(_ engine: SyncEngine, startedAppleTrack track: AppleTrack, for spotifyTrack: SpotifyTrack)
    /// Spotify's queue changed or is stale; fetch it again soon.
    func syncEngineWantsQueueRefresh(_ engine: SyncEngine)
}

// MARK: - Engine

/// Keeps Apple Music playing whatever the Spotify desktop client is playing.
///
/// Spotify decides *what* plays and *whether* it plays: the user drives it, and its queue,
/// radio and DJ pick the songs. Apple Music is what the user hears, and it is the clock: it
/// plays the current song with the next one already queued, so transitions are gapless, and
/// Spotify (muted) is nudged to follow Apple's position.
///
/// The engine is a pure state machine. Players report observations, the engine sends
/// commands, and every command is recorded as pending so the state change it causes is not
/// mistaken for the user. Anything that changes without a pending command is the user:
/// a click in Spotify is applied to Apple at once, and a media key or Control Center action
/// that reached Apple Music is mirrored back to Spotify.
@MainActor
public final class SyncEngine {
    public struct Config: Sendable {
        /// How long Apple may keep playing the end of a longer version after Spotify moved on.
        public var tailWait: Double = 8
        /// Within this many seconds of its end, a player is treated as having finished a track.
        public var endSlack: Double = 2.5
        /// A position change this much larger than the elapsed time is a seek.
        public var jumpThreshold: Double = 1.6
        /// Spotify is re-seeked to Apple's position when they drift further apart than this.
        public var driftThreshold: Double = 0.6
        public var commandTimeout: Double = 2.5
        public var startTimeout: Double = 8
        /// After this long without Apple audio for a new track, Spotify plays it instead.
        public var loadingTimeout: Double = 3.5
        /// Apple-side play, pause and seek must hold this long before they are mirrored to
        /// Spotify. This filters MusicKit's transient states, and Spotify is muted, so the
        /// delay is silent.
        public var appleDebounce: Double = 0.6
        /// A new track that Spotify reports this close to its start begins at 0 on Apple Music,
        /// so lookup latency never clips the intro.
        public var freshStartWindow: Double = 3
        /// How many upcoming tracks to look up ahead of time.
        public var prefetchDepth = 8

        public init() {}
    }

    public enum Route: Equatable, Sendable {
        /// Nothing to mirror: Spotify is stopped, quit, disabled or playing elsewhere.
        case idle
        /// Looking up or starting the Apple version; nothing is audible.
        case loading(uri: String, since: Double, startAt: Double)
        /// Apple Music is audible; Spotify is muted.
        case apple(uri: String, songID: String)
        /// Spotify is audible: podcasts, ads, and songs Apple Music doesn't have.
        case spotify(uri: String)

        public var uri: String? {
            switch self {
            case .idle: return nil
            case .loading(let uri, _, _), .apple(let uri, _), .spotify(let uri): return uri
            }
        }
    }

    public let config: Config
    public weak var delegate: SyncEngineDelegate?

    public private(set) var route: Route = .idle
    public private(set) var isEnabled = true
    public private(set) var isSpotifyRemote = false

    private let spotify: SpotifyCommanding
    private let apple: AppleCommanding
    private let muter: SpotifyMuting
    private let resolver: TrackResolving
    private let clock: EngineClock

    public private(set) var lastSpotify: SpotifyObservation?
    public private(set) var lastApple: AppleObservation?
    /// A polled track change waiting for a second poll to confirm it. "" means no track.
    private var pollCandidate: String?
    private var lastNotificationAt = -Double.infinity

    /// Spotify's upcoming queue and the track it follows.
    private var upcoming: [SpotifyTrack] = []
    private var upcomingAfterURI: String?
    private var repeatOne = false

    /// Apple songs queued after the current entry, in order.
    private var appleUpcomingIDs: [String] = []
    private var spotifyURIForSong: [String: String] = [:]
    private var durationForSong: [String: Double] = [:]

    private struct Awaiting {
        var uri: String
        var since: Double
    }
    /// Spotify finished its version and moved to `uri`; Apple is finishing a longer one.
    private var awaitingApple: Awaiting?
    /// Apple moved to `uri` first; Spotify has not followed yet.
    private var awaitingSpotify: Awaiting?

    private enum SpotifyCommand: Equatable {
        case play, pause, next, seek(Double)
        var isSeek: Bool { if case .seek = self { return true } else { return false } }
    }
    private enum AppleCommand: Equatable {
        /// Settles once the song is current and, when asked to play, actually playing. MusicKit
        /// swaps the entry well before playback starts, and the gap must not read as a pause.
        case start(String, play: Bool), play, pause, stop, seek(Double), skipNext
        var isSeek: Bool { if case .seek = self { return true } else { return false } }
        var isTransport: Bool {
            switch self {
            case .start, .skipNext, .stop: return true
            default: return false
            }
        }
    }
    private struct Pending<Command> {
        var command: Command
        var issued: Double
        var timeout: Double
    }
    private var spotifyPending: [Pending<SpotifyCommand>] = []
    private var applePending: [Pending<AppleCommand>] = []

    /// Apple-side changes waiting out the debounce before they are mirrored to Spotify.
    private var appleStatusCandidate: (status: AppleStatus, since: Double)?
    private var appleSeekCandidate: Double?
    /// An Apple song loaded paused while Spotify plays a track Apple doesn't have, so the
    /// switch back is as quick as pressing play.
    private var preparedSongID: String?
    private var driftStrikes = 0
    private var lastDriftFix = -Double.infinity
    private var pauseMismatchStrikes = 0
    /// When Apple first stopped matching the route with nothing in flight to explain it.
    private var appleMismatchSince: Double?
    private var watchdogResyncs: [Double] = []
    private var muted: Bool?

    public init(spotify: SpotifyCommanding, apple: AppleCommanding, muter: SpotifyMuting, resolver: TrackResolving, clock: EngineClock, config: Config = Config()) {
        self.spotify = spotify
        self.apple = apple
        self.muter = muter
        self.resolver = resolver
        self.clock = clock
        self.config = config
    }

    // MARK: Inputs

    public func spotifyObserved(_ obs: SpotifyObservation) {
        if obs.isAuthoritative {
            lastNotificationAt = max(lastNotificationAt, obs.issuedAt)
        } else if obs.issuedAt < lastNotificationAt {
            return
        }
        if let last = lastSpotify, obs.time < last.time { return }
        if !obs.isAuthoritative, lastSpotify != nil, obs.track?.uri != lastSpotify?.track?.uri {
            let candidate = obs.track?.uri ?? ""
            if pollCandidate != candidate {
                pollCandidate = candidate
                return
            }
        }
        pollCandidate = nil
        let prev = lastSpotify
        lastSpotify = obs
        prune(obs.time)
        guard isEnabled, !isSpotifyRemote else { return }

        guard let track = obs.track else {
            goIdle()
            return
        }
        if track.uri != prev?.track?.uri {
            spotifyTrackChanged(from: prev, to: obs, track: track)
        } else if let prev {
            if prev.isPlaying != obs.isPlaying {
                spotifyPlayStateChanged(obs, track: track)
            }
            spotifyCheckJump(prev: prev, obs: obs)
        }
        updateMute()
    }

    public func appleObserved(_ obs: AppleObservation) {
        let prev = lastApple
        lastApple = obs
        prune(obs.time)
        guard isEnabled, !isSpotifyRemote else { return }

        if obs.entryID != prev?.entryID {
            appleEntryChanged(from: prev, to: obs)
        } else if let prev {
            if prev.status != obs.status {
                appleStatusChanged(from: prev, to: obs)
            } else if prev.status == .playing {
                appleCheckJump(prev: prev, obs: obs)
            }
        }
        // A start or skip that just settled may have left the following song unqueued.
        syncAppleUpcoming()
        updateMute()
    }

    /// Spotify's queue as the Web API reports it: the tracks after `currentURI`.
    public func upcomingUpdated(after currentURI: String, upcoming: [SpotifyTrack], repeatOne: Bool) {
        self.upcoming = upcoming
        upcomingAfterURI = currentURI
        // The API can lag a track behind the client.
        if let playing = lastSpotify?.track?.uri, playing != currentURI {
            shiftUpcoming(to: playing, refresh: false)
        }
        if repeatOne != self.repeatOne {
            self.repeatOne = repeatOne
            apple.setRepeatOne(repeatOne)
        }
        let unknown = upcoming.prefix(config.prefetchDepth).filter { $0.kind.isMusic && resolver.resolution(for: $0) == nil }
        if !unknown.isEmpty {
            resolver.resolve(Array(unknown), urgent: false)
        }
        syncAppleUpcoming()
    }

    public func resolutionChanged(for uri: String) {
        if case .loading(let loadingURI, _, let startAt) = route, loadingURI == uri,
           let s = lastSpotify, let track = s.track, track.uri == uri {
            switch resolver.resolution(for: track) {
            case .matched(let song)?:
                playOnApple(track, song, at: startAt, play: s.isPlaying)
            case .unavailable?:
                fallBack(track, reason: .notOnAppleMusic)
            case nil:
                break
            }
            updateMute()
        }
        if upcoming.first?.uri == uri {
            syncAppleUpcoming()
        }
    }

    /// Apple Music failed to play `songID` (nil: whatever is current).
    public func appleFailed(songID: String?) {
        guard let s = lastSpotify, let track = s.track else { return }
        switch route {
        case .apple(let uri, let current) where uri == track.uri && (songID == nil || songID == current):
            // A failed resume says nothing about the song; a failed start does.
            if songID != nil { resolver.markUnplayable(track) }
            fallBack(track, reason: .applePlaybackFailed)
        case .loading(let uri, _, _) where uri == track.uri:
            fallBack(track, reason: .applePlaybackFailed)
        default:
            break
        }
        updateMute()
    }

    /// Queueing the next song on Apple failed; forget it so it is queued again rather than
    /// skipped to.
    public func appleUpcomingFailed() {
        appleUpcomingIDs = []
    }

    public func spotifyQuit() {
        lastSpotify = nil
        pollCandidate = nil
        goIdle()
    }

    /// Spotify is playing on another device through Spotify Connect, so this Mac should be quiet.
    public func setSpotifyRemote(_ remote: Bool) {
        guard remote != isSpotifyRemote else { return }
        isSpotifyRemote = remote
        if remote { goIdle() }
        updateMute()
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { goIdle() }
        updateMute()
    }

    /// Call every 250ms or so.
    public func tick() {
        let now = clock.now
        prune(now)
        guard isEnabled, !isSpotifyRemote else { return }
        mirrorAppleCandidates(now)
        checkTimeouts(now)
        correctDrift(now)
        reconcilePause(now)
        watchApple(now)
        prepareAfterSpotifyTrack(now)
        if route == .idle, let s = lastSpotify, s.isPlaying, s.track != nil {
            resyncToSpotify()
        }
        updateMute()
    }

    // MARK: Spotify changes

    private func spotifyTrackChanged(from prev: SpotifyObservation?, to obs: SpotifyObservation, track: SpotifyTrack) {
        let causedByUs = consumeSpotify { $0 == .next || $0.isSeek }
        shiftUpcoming(to: track.uri, refresh: true)

        // Apple got there first (it finished a shorter version, or the user skipped on the
        // Apple side). Spotify has caught up.
        if case .apple(let uri, _) = route, uri == track.uri {
            awaitingSpotify = nil
            return
        }

        // Spotify finished its version and moved on to the next track while Apple is still
        // playing the end of a slightly longer one. Let Apple finish; its queue moves on to
        // the same track.
        let appleNext = appleUpcomingIDs.first.flatMap { spotifyURIForSong[$0] }
        if !causedByUs,
           let prev, let prevTrack = prev.track,
           case .apple(let currentURI, _) = route, currentURI == prevTrack.uri,
           reachedEnd(spotify: prev, duration: prevTrack.duration, at: obs.time),
           appleNext == nil || appleNext == track.uri,
           lastApple?.status == .playing,
           let remaining = appleRemaining(at: obs.time), remaining <= config.tailWait {
            awaitingApple = Awaiting(uri: track.uri, since: obs.time)
            return
        }

        begin(track, spotifyPosition: obs.position, isPlaying: obs.isPlaying, at: obs.time)
    }

    private func spotifyPlayStateChanged(_ obs: SpotifyObservation, track: SpotifyTrack) {
        if consumeSpotify({ $0 == (obs.isPlaying ? .play : .pause) }) { return }
        appleStatusCandidate = nil
        switch route {
        case .apple:
            sendApple(obs.isPlaying ? .play : .pause)
        case .idle:
            if obs.isPlaying {
                begin(track, spotifyPosition: obs.position, isPlaying: true, at: obs.time)
            }
        case .loading, .spotify:
            // A pending start picks up the play state when it lands.
            break
        }
    }

    private func spotifyCheckJump(prev: SpotifyObservation, obs: SpotifyObservation) {
        let elapsed = obs.time - prev.time
        // Comparing consecutive readings separates a scrub (one big jump) from buffering
        // (the position falls behind a little at a time).
        guard elapsed < 2 else { return }
        let predicted = prev.position + (prev.isPlaying ? elapsed : 0)
        guard abs(obs.position - predicted) > config.jumpThreshold else { return }
        if consumeSpotify({ command in
            if case .seek(let target) = command { return abs(target - obs.position) < 2.5 }
            return false
        }) { return }
        // With repeat-one, Spotify loops to the start and Apple loops by itself.
        if repeatOne, obs.position < 3, let duration = prev.track?.duration, prev.position > duration - 4 { return }

        switch route {
        case .apple:
            if awaitingApple != nil, let track = obs.track {
                // The user scrubbed the new track while Apple was finishing the old one.
                begin(track, spotifyPosition: obs.position, isPlaying: obs.isPlaying, at: obs.time)
                return
            }
            appleSeekCandidate = nil
            sendApple(.seek(obs.position))
        case .loading(let uri, let since, _):
            route = .loading(uri: uri, since: since, startAt: obs.position)
        case .idle, .spotify:
            break
        }
    }

    // MARK: Apple changes

    private func appleEntryChanged(from prev: AppleObservation?, to obs: AppleObservation) {
        appleStatusCandidate = nil
        appleSeekCandidate = nil
        let finishedNaturally = prev.map { reachedEnd(apple: $0, at: obs.time) } ?? false

        if settleApple(obs) { return }
        // A skip that ran off the end of the queue found nothing queued after all.
        if obs.songID == nil, consumeApple({ $0 == .skipNext }) {
            resyncToSpotify()
            return
        }
        // While a start, skip or stop is in flight, whatever Apple reports is its doing.
        if hasPendingApple({ $0.isTransport }) { return }

        guard let songID = obs.songID, let uri = spotifyURIForSong[songID] else {
            if obs.songID == nil {
                appleQueueEnded(finishedNaturally: finishedNaturally, at: obs.time)
            } else if case .apple(_, let current) = route, prev?.songID == current {
                // Music left our song for one of its own: AutoPlay took over when its queue ran
                // out, after the song ended or next was pressed. Silence it and carry on as if
                // the queue had simply ended.
                sendApple(.pause)
                appleQueueEnded(finishedNaturally: finishedNaturally, at: obs.time)
            } else if case .apple = route {
                resyncToSpotify()
            }
            return
        }

        // Apple finished its longer version and caught up with Spotify.
        if let waiting = awaitingApple {
            awaitingApple = nil
            guard waiting.uri == uri else {
                // Apple moved to a different song than Spotify did: the queue we predicted
                // was stale. Spotify's choice wins.
                resyncToSpotify()
                return
            }
            if appleUpcomingIDs.first == songID { appleUpcomingIDs.removeFirst() }
            route = .apple(uri: uri, songID: songID)
            syncAppleUpcoming()
            return
        }

        // Apple moved on to the song queued after the current one, while Spotify is still on
        // the current one.
        if case .apple(let currentURI, _) = route, currentURI != uri, appleUpcomingIDs.first == songID,
           lastSpotify?.track?.uri == currentURI {
            appleUpcomingIDs.removeFirst()
            route = .apple(uri: uri, songID: songID)
            shiftUpcoming(to: uri, refresh: true)
            if lastSpotify?.track?.uri != uri {
                if finishedNaturally {
                    // Apple's version was shorter. Move Spotify to the last moment of its
                    // track so it finishes naturally, which reads as a full listen rather
                    // than a skip.
                    if let remaining = spotifyRemaining(at: obs.time), remaining > 1, let duration = lastSpotify?.track?.duration {
                        sendSpotify(.seek(max(0, duration - 0.4)))
                    }
                } else {
                    // Next was pressed on the Apple side (media key, Control Center).
                    sendSpotify(.next)
                }
                awaitingSpotify = Awaiting(uri: uri, since: obs.time)
            }
            syncAppleUpcoming()
            return
        }

        // Same song under a new entry id: an edit to the queue, not a change of song.
        if case .apple(_, let current) = route, current == songID { return }
        resyncToSpotify()
    }

    private func appleStatusChanged(from prev: AppleObservation, to obs: AppleObservation) {
        if settleApple(obs) {
            appleStatusCandidate = nil
            return
        }
        if consumeApple({ command in
            switch (command, obs.status) {
            case (.play, .playing), (.pause, .paused), (.pause, .stopped):
                return true
            default:
                return false
            }
        }) {
            appleStatusCandidate = nil
            return
        }
        // Status churn while a start, skip or seek is in flight is ours.
        if hasPendingApple({ $0.isTransport || $0.isSeek }) { return }
        if obs.status != .playing, reachedEnd(apple: prev, at: obs.time) {
            appleQueueEnded(finishedNaturally: true, at: obs.time)
            return
        }
        guard case .apple = route else {
            // A media key or Control Center started Apple Music while Spotify is the one that
            // should be heard (or nothing should).
            if obs.status == .playing, !hasPendingApple({ $0 == .play }) {
                sendApple(.pause)
            }
            return
        }
        appleStatusCandidate = (obs.status, obs.time)
    }

    private func appleCheckJump(prev: AppleObservation, obs: AppleObservation) {
        let elapsed = obs.time - prev.time
        guard elapsed < 2 else { return }
        guard abs(obs.position - (prev.position + elapsed)) > config.jumpThreshold else { return }
        if consumeApple({ command in
            if case .seek(let target) = command { return abs(target - obs.position) < 2.5 }
            return false
        }) { return }
        if hasPendingApple({ $0.isTransport }) { return }
        if repeatOne, obs.position < 3, reachedEnd(apple: prev, at: obs.time) { return }
        guard case .apple = route else { return }
        // Scrubbed or restarted from Control Center or a media key.
        appleSeekCandidate = obs.time
    }

    /// Apple has nothing left to play.
    private func appleQueueEnded(finishedNaturally: Bool, at time: Double) {
        if let waiting = awaitingApple {
            // Spotify had already moved on, but its new track wasn't queued on Apple.
            awaitingApple = nil
            guard let s = lastSpotify, let track = s.track, track.uri == waiting.uri else {
                resyncToSpotify()
                return
            }
            begin(track, spotifyPosition: 0, isPlaying: s.isPlaying, at: time)
            if case .spotify = route, s.position > 1 {
                // Spotify plays this one; replay the seconds it spent muted.
                sendSpotify(.seek(0))
            }
            return
        }
        guard case .apple(let uri, _) = route, let s = lastSpotify, s.track?.uri == uri else { return }
        if finishedNaturally {
            // Apple's version ended and nothing was queued after it. Hurry Spotify to its end so
            // the next track starts now; begin() takes it from there.
            if let remaining = spotifyRemaining(at: time), remaining > 1, let duration = s.track?.duration {
                sendSpotify(.seek(max(0, duration - 0.4)))
            }
            return
        }
        // The queue ran out mid-song: next was pressed on the Apple side with nothing queued.
        if s.isPlaying {
            sendSpotify(.next)
        }
    }

    // MARK: Starting tracks

    /// Make `track` the current track: play it on Apple Music, look it up first, or hand it to
    /// Spotify.
    private func begin(_ track: SpotifyTrack, spotifyPosition: Double, isPlaying: Bool, at time: Double) {
        awaitingApple = nil
        awaitingSpotify = nil
        appleStatusCandidate = nil
        appleSeekCandidate = nil
        driftStrikes = 0
        let startAt = spotifyPosition < config.freshStartWindow ? 0 : spotifyPosition
        guard track.kind.isMusic else {
            fallBack(track, reason: .notMusic)
            return
        }
        switch resolver.resolution(for: track) {
        case .matched(let song)? where startAt == 0 && isPlaying && isPrepared(song):
            preparedSongID = nil
            remember(song, for: track.uri)
            appleUpcomingIDs = []
            sendApple(.play)
            route = .apple(uri: track.uri, songID: song.id)
            delegate?.syncEngine(self, startedAppleTrack: song, for: track)
        case .matched(let song)?:
            playOnApple(track, song, at: startAt, play: isPlaying)
        case .unavailable?:
            fallBack(track, reason: .notOnAppleMusic)
        case nil:
            // Silence the previous song now rather than when the new one is ready.
            if lastApple?.status == .playing || hasPendingApple({ $0.isTransport }) {
                sendApple(.pause)
            }
            route = .loading(uri: track.uri, since: time, startAt: startAt)
            resolver.resolve([track], urgent: true)
        }
        updateMute()
    }

    private func playOnApple(_ track: SpotifyTrack, _ song: AppleTrack, at position: Double, play: Bool) {
        remember(song, for: track.uri)
        let canSkip: Bool = {
            guard case .apple = route, position == 0, play, appleUpcomingIDs.first == song.id else { return false }
            return lastApple?.entryID != nil && !hasPendingApple({ $0.isTransport })
        }()
        if canSkip {
            // Already queued and buffered: skipping to it is instant.
            sendApple(.skipNext)
            appleUpcomingIDs.removeFirst()
            route = .apple(uri: track.uri, songID: song.id)
            syncAppleUpcoming()
        } else {
            let next = appleTracksQueued(after: track.uri)
            preparedSongID = nil
            applePending.append(Pending(command: .start(song.id, play: play), issued: clock.now, timeout: config.startTimeout))
            apple.start([song] + next, at: position, play: play)
            appleUpcomingIDs = next.map(\.id)
            route = .apple(uri: track.uri, songID: song.id)
        }
        delegate?.syncEngine(self, startedAppleTrack: song, for: track)
    }

    private func fallBack(_ track: SpotifyTrack, reason: FallbackReason) {
        if lastApple?.status == .playing || hasPendingApple({ $0.isTransport }) {
            sendApple(.stop)
        }
        appleUpcomingIDs = []
        awaitingApple = nil
        awaitingSpotify = nil
        route = .spotify(uri: track.uri)
        updateMute()
        delegate?.syncEngine(self, fellBackToSpotifyFor: track, reason: reason)
    }

    private func goIdle() {
        if lastApple?.status == .playing || hasPendingApple({ $0.isTransport }) {
            sendApple(.pause)
        }
        route = .idle
        awaitingApple = nil
        awaitingSpotify = nil
        appleStatusCandidate = nil
        appleSeekCandidate = nil
        updateMute()
    }

    private func resyncToSpotify() {
        guard let s = lastSpotify, let track = s.track else {
            goIdle()
            return
        }
        let now = clock.now
        begin(track, spotifyPosition: spotifyPosition(at: now) ?? s.position, isPlaying: s.isPlaying, at: now)
    }

    private func isPrepared(_ song: AppleTrack) -> Bool {
        guard preparedSongID == song.id, let a = lastApple, a.songID == song.id, a.status != .playing, a.position < 1 else { return false }
        return !hasPendingApple({ $0.isTransport })
    }

    /// While Spotify plays a track Apple Music doesn't have, load the next Apple song paused.
    private func prepareAfterSpotifyTrack(_ now: Double) {
        guard case .spotify(let uri) = route, let s = lastSpotify, s.track?.uri == uri, s.isPlaying,
              let remaining = spotifyRemaining(at: now), remaining < 20,
              !hasPendingApple({ $0.isTransport }),
              let song = appleTracksQueued(after: uri).first, preparedSongID != song.id else { return }
        preparedSongID = song.id
        applePending.append(Pending(command: .start(song.id, play: false), issued: now, timeout: config.startTimeout))
        apple.start([song], at: 0, play: false)
    }

    // MARK: Upcoming queue

    private func remember(_ song: AppleTrack, for uri: String) {
        spotifyURIForSong[song.id] = uri
        durationForSong[song.id] = song.duration
    }

    /// The Apple song to queue after `uri`, if Spotify's next track is known and matched.
    private func appleTracksQueued(after uri: String) -> [AppleTrack] {
        guard !repeatOne, upcomingAfterURI == uri, let next = upcoming.first,
              case .matched(let song)? = resolver.resolution(for: next) else { return [] }
        remember(song, for: next.uri)
        return [song]
    }

    private func syncAppleUpcoming() {
        guard case .apple(let uri, let songID) = route, awaitingApple == nil,
              lastApple?.songID == songID, !hasPendingApple({ $0.isTransport }) else { return }
        // In the last seconds Apple is already buffering the next song; leave it alone.
        if let remaining = appleRemaining(at: clock.now), remaining < 2 { return }
        let desired = appleTracksQueued(after: uri)
        guard desired.map(\.id) != appleUpcomingIDs else { return }
        apple.setUpcoming(desired)
        appleUpcomingIDs = desired.map(\.id)
    }

    /// Advance our copy of Spotify's queue to `uri`.
    private func shiftUpcoming(to uri: String, refresh: Bool) {
        guard upcomingAfterURI != uri else { return }
        if let index = upcoming.prefix(4).firstIndex(where: { $0.uri == uri }) {
            upcoming.removeFirst(index + 1)
            upcomingAfterURI = uri
        } else {
            upcoming = []
            upcomingAfterURI = nil
        }
        if refresh {
            delegate?.syncEngineWantsQueueRefresh(self)
        }
    }

    // MARK: Periodic work

    private func mirrorAppleCandidates(_ now: Double) {
        if let candidate = appleStatusCandidate, now - candidate.since >= config.appleDebounce {
            appleStatusCandidate = nil
            if case .apple = route, lastApple?.status == candidate.status, let s = lastSpotify {
                if candidate.status == .playing, !s.isPlaying {
                    sendSpotify(.play)
                } else if candidate.status != .playing, s.isPlaying {
                    sendSpotify(.pause)
                }
            }
        }
        if let since = appleSeekCandidate, now - since >= config.appleDebounce {
            appleSeekCandidate = nil
            if case .apple(let uri, _) = route, lastSpotify?.track?.uri == uri, let position = applePosition(at: now) {
                sendSpotify(.seek(position))
            }
        }
    }

    private func checkTimeouts(_ now: Double) {
        if case .loading(let uri, let since, _) = route, now - since > config.loadingTimeout,
           let track = lastSpotify?.track, track.uri == uri {
            fallBack(track, reason: .appleTimedOut)
            return
        }
        if case .apple(let uri, let songID) = route,
           let s = lastSpotify, s.isPlaying, s.track?.uri == uri,
           !(lastApple?.songID == songID && lastApple?.status == .playing),
           let start = applePending.first(where: { if case .start(songID, _) = $0.command { return true } else { return false } }),
           now - start.issued > config.loadingTimeout, let track = s.track {
            fallBack(track, reason: .appleTimedOut)
            return
        }
        if let waiting = awaitingApple, now - waiting.since > config.tailWait + 2 {
            awaitingApple = nil
            resyncToSpotify()
        }
        if let waiting = awaitingSpotify, now - waiting.since > 6 {
            awaitingSpotify = nil
            if lastSpotify?.track?.uri != waiting.uri {
                sendSpotify(.next)
            }
        }
    }

    /// Spotify follows Apple's clock. Re-seek it when they drift apart, so its progress bar,
    /// lyrics and track changes line up with what is audible.
    private func correctDrift(_ now: Double) {
        guard case .apple(let uri, let songID) = route,
              awaitingApple == nil, awaitingSpotify == nil,
              let s = lastSpotify, s.track?.uri == uri, s.isPlaying,
              let a = lastApple, a.songID == songID, a.status == .playing,
              spotifyPending.isEmpty, applePending.isEmpty,
              appleSeekCandidate == nil, appleStatusCandidate == nil,
              now - lastDriftFix > 4,
              let spotifyPos = spotifyPosition(at: now), let applePos = applePosition(at: now),
              let spotifyDuration = s.track?.duration, let appleDuration = durationForSong[songID],
              applePos > 0.5, applePos < appleDuration - 5, applePos < spotifyDuration - 5, spotifyPos < spotifyDuration - 5
        else {
            driftStrikes = 0
            return
        }
        driftStrikes = abs(spotifyPos - applePos) > config.driftThreshold ? driftStrikes + 1 : 0
        if driftStrikes >= 2 {
            driftStrikes = 0
            lastDriftFix = now
            sendSpotify(.seek(applePos))
        }
    }

    /// Safety net: Spotify is the source of truth for pausing. If Spotify is paused and Apple
    /// still plays with nothing in flight, pause Apple. Never the reverse, so a pause the user
    /// made on the Apple side is never undone.
    private func reconcilePause(_ now: Double) {
        guard case .apple = route, let s = lastSpotify, !s.isPlaying, lastApple?.status == .playing,
              spotifyPending.isEmpty, applePending.isEmpty, appleStatusCandidate == nil else {
            pauseMismatchStrikes = 0
            return
        }
        pauseMismatchStrikes += 1
        if pauseMismatchStrikes >= 3 {
            pauseMismatchStrikes = 0
            sendApple(.pause)
        }
    }

    /// Safety net for anything the event handling missed, such as a queue edit or skip that
    /// silently failed: if Apple isn't playing the route's song while Spotify plays it, with
    /// nothing in flight to explain why, start it again. A player that keeps refusing hands the
    /// song to Spotify instead of being fought forever.
    private func watchApple(_ now: Double) {
        guard case .apple(let uri, let songID) = route, awaitingApple == nil, awaitingSpotify == nil,
              spotifyPending.isEmpty, applePending.isEmpty, appleStatusCandidate == nil, appleSeekCandidate == nil,
              let s = lastSpotify, s.isPlaying, let track = s.track, track.uri == uri else {
            appleMismatchSince = nil
            return
        }
        if lastApple?.songID == songID && lastApple?.status == .playing {
            appleMismatchSince = nil
            return
        }
        guard let since = appleMismatchSince else {
            appleMismatchSince = now
            return
        }
        guard now - since > 1.5 else { return }
        appleMismatchSince = nil
        watchdogResyncs = watchdogResyncs.filter { now - $0 < 30 } + [now]
        if watchdogResyncs.count > 3 {
            fallBack(track, reason: .applePlaybackFailed)
        } else {
            resyncToSpotify()
        }
    }

    private func updateMute() {
        let shouldMute: Bool = {
            guard isEnabled, !isSpotifyRemote else { return false }
            if case .spotify = route { return false }
            return true
        }()
        guard muted != shouldMute else { return }
        muted = shouldMute
        muter.setSpotifyMuted(shouldMute)
    }

    // MARK: Commands

    private func sendSpotify(_ command: SpotifyCommand) {
        spotifyPending.append(Pending(command: command, issued: clock.now, timeout: config.commandTimeout))
        switch command {
        case .play: spotify.play()
        case .pause: spotify.pause()
        case .next: spotify.next()
        case .seek(let seconds): spotify.seek(to: seconds)
        }
    }

    private func sendApple(_ command: AppleCommand) {
        let timeout = command == .skipNext ? 1.2 : config.commandTimeout
        applePending.append(Pending(command: command, issued: clock.now, timeout: timeout))
        switch command {
        case .play: apple.play()
        case .pause: apple.pause()
        case .stop: apple.stop()
        case .seek(let seconds): apple.seek(to: seconds)
        case .skipNext: apple.skipToNext()
        case .start:
            // Starts carry tracks; see playOnApple.
            break
        }
    }

    private func prune(_ now: Double) {
        spotifyPending.removeAll { now - $0.issued > $0.timeout }
        applePending.removeAll { now - $0.issued > $0.timeout }
    }

    private func consumeSpotify(_ matches: (SpotifyCommand) -> Bool) -> Bool {
        guard let index = spotifyPending.firstIndex(where: { matches($0.command) }) else { return false }
        spotifyPending.remove(at: index)
        return true
    }

    private func consumeApple(_ matches: (AppleCommand) -> Bool) -> Bool {
        guard let index = applePending.firstIndex(where: { matches($0.command) }) else { return false }
        applePending.remove(at: index)
        return true
    }

    /// Retires the start, skip or stop that `obs` shows has finished.
    private func settleApple(_ obs: AppleObservation) -> Bool {
        consumeApple { command in
            switch command {
            case .start(let id, let play): return obs.songID == id && (!play || obs.status == .playing)
            case .skipNext: return obs.songID != nil && obs.status == .playing
            case .stop: return obs.songID == nil || obs.status == .stopped
            default: return false
            }
        }
    }

    private func hasPendingApple(_ matches: (AppleCommand) -> Bool) -> Bool {
        applePending.contains { matches($0.command) }
    }

    // MARK: Positions

    private func spotifyPosition(at time: Double) -> Double? {
        guard let s = lastSpotify else { return nil }
        return s.position + (s.isPlaying ? max(0, time - s.time) : 0)
    }

    private func applePosition(at time: Double) -> Double? {
        guard let a = lastApple else { return nil }
        return a.position + (a.status == .playing ? max(0, time - a.time) : 0)
    }

    private func spotifyRemaining(at time: Double) -> Double? {
        guard let duration = lastSpotify?.track?.duration, let position = spotifyPosition(at: time) else { return nil }
        return duration - position
    }

    private func appleRemaining(at time: Double) -> Double? {
        guard let id = lastApple?.songID, let duration = durationForSong[id], let position = applePosition(at: time) else { return nil }
        return duration - position
    }

    private func reachedEnd(spotify obs: SpotifyObservation, duration: Double, at time: Double) -> Bool {
        let position = obs.position + (obs.isPlaying ? max(0, time - obs.time) : 0)
        return position >= duration - config.endSlack
    }

    private func reachedEnd(apple obs: AppleObservation, at time: Double) -> Bool {
        guard let id = obs.songID, let duration = durationForSong[id] else { return false }
        let position = obs.position + (obs.status == .playing ? max(0, time - obs.time) : 0)
        return position >= duration - config.endSlack
    }
}
