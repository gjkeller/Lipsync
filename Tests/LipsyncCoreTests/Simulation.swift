import Foundation
@testable import LipsyncCore

/// Virtual-time stand-ins for the Spotify client, the Apple Music player and the catalog, with
/// the latencies and notification behavior of the real ones. Time advances in 10ms steps.

@MainActor final class SimClock: EngineClock {
    var now: Double = 0
}

@MainActor final class Simulation {
    let clock = SimClock()
    let spotify: SimSpotify
    let apple: SimApple
    let muter = SimMuter()
    let resolver: SimResolver
    let delegate = SimDelegate()
    let engine: SyncEngine
    let step = 0.01

    /// Whether the simulated Web API answers queue requests.
    var webAPIEnabled = true
    var queueLatency = 0.3

    private var events: [(at: Double, seq: Int, action: () -> Void)] = []
    private var seq = 0
    private(set) var timeline: [(time: Double, sound: Sound)] = []

    enum Sound: Equatable {
        case silence
        case apple(String)
        case spotify(String)
    }

    init(tracks: [SpotifyTrack], appleVersions: [String: Resolution], config: SyncEngine.Config = .init()) {
        spotify = SimSpotify(tracks: tracks)
        apple = SimApple()
        resolver = SimResolver(answers: appleVersions)
        engine = SyncEngine(spotify: spotify, apple: apple, muter: muter, resolver: resolver, clock: clock, config: config)
        engine.delegate = delegate
        spotify.sim = self
        apple.sim = self
        resolver.sim = self
        delegate.sim = self
    }

    func schedule(after delay: Double, _ action: @escaping () -> Void) {
        seq += 1
        events.append((clock.now + delay, seq, action))
    }

    func run(until end: Double) {
        while clock.now < end - step / 2 {
            clock.now = (clock.now + step).rounded(toPlaces: 4)
            spotify.advance(step)
            apple.advance(step)
            let due = events.filter { $0.at <= clock.now + 1e-9 }.sorted { ($0.at, $0.seq) < ($1.at, $1.seq) }
            events.removeAll { $0.at <= clock.now + 1e-9 }
            for event in due { event.action() }
            let ticks = Int((clock.now * 100).rounded())
            if ticks % 50 == 0 { spotify.poll() }
            if ticks % 25 == 0 {
                apple.poll()
                engine.tick()
            }
            if ticks % 1000 == 0 { refreshQueue() }
            timeline.append((clock.now, currentSound))
        }
    }

    var currentSound: Sound {
        if apple.status == .playing, let song = apple.currentSong { return .apple(song.id) }
        if !muter.muted, spotify.isPlaying, let track = spotify.current { return .spotify(track.uri) }
        return .silence
    }

    func refreshQueue() {
        guard webAPIEnabled, let current = spotify.current else { return }
        // The API answers with the state at request time, which may be stale on arrival.
        let upcoming = Array(spotify.tracks.dropFirst(spotify.index + 1).prefix(10))
        schedule(after: queueLatency) { [self] in
            engine.upcomingUpdated(after: current.uri, upcoming: upcoming, repeatOne: false)
        }
    }

    // MARK: Timeline queries

    /// Longest stretch of silence between `from` and `to`.
    func longestSilence(from: Double, to: Double) -> Double {
        var longest = 0.0, start: Double?
        for (t, sound) in timeline where t >= from && t <= to {
            if sound == .silence {
                if start == nil { start = t }
                longest = max(longest, t - start! + step)
            } else {
                start = nil
            }
        }
        return longest
    }

    func sound(at time: Double) -> Sound {
        timeline.last { $0.time <= time + 1e-9 }?.sound ?? .silence
    }

    /// The distinct sounds in order, ignoring silence.
    func soundSequence(from: Double = 0, to: Double = .infinity) -> [Sound] {
        var out: [Sound] = []
        for (t, sound) in timeline where t >= from && t <= to && sound != .silence && out.last != sound {
            out.append(sound)
        }
        return out
    }

    func firstTime(of sound: Sound, after: Double = 0) -> Double? {
        timeline.first { $0.time >= after && $0.sound == sound }?.time
    }

    func seconds(of sound: Sound) -> Double {
        Double(timeline.filter { $0.sound == sound }.count) * step
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

// MARK: - Spotify

@MainActor final class SimSpotify: SpotifyCommanding {
    weak var sim: Simulation!
    var tracks: [SpotifyTrack]
    var index = 0
    var position = 0.0
    var isPlaying = false
    var hasTrack = false
    var commandLatency = 0.03
    /// Seconds of upcoming playback during which Spotify stalls (buffering).
    var stallRemaining = 0.0
    /// Spotify's playback speed relative to Apple's, to model two audio clocks drifting.
    var rate = 1.0
    /// Drop distributed notifications, leaving only polls.
    var notificationsEnabled = true

    private(set) var engineNexts = 0
    private(set) var engineSeeks: [Double] = []
    private(set) var engineCommands: [String] = []

    init(tracks: [SpotifyTrack]) { self.tracks = tracks }

    var current: SpotifyTrack? { hasTrack && index < tracks.count ? tracks[index] : nil }

    func advance(_ dt: Double) {
        guard isPlaying, let track = current else { return }
        if stallRemaining > 0 {
            stallRemaining -= dt
            return
        }
        position += dt * rate
        if position >= track.duration {
            let overflow = position - track.duration
            index += 1
            if index < tracks.count {
                position = overflow
            } else {
                isPlaying = false
                hasTrack = false
                position = 0
            }
            notify()
        }
    }

    func observation(authoritative: Bool) -> SpotifyObservation {
        SpotifyObservation(track: current, isPlaying: isPlaying && current != nil, position: position, time: sim.clock.now, isAuthoritative: authoritative)
    }

    func notify() {
        guard notificationsEnabled else { return }
        sim.engine.spotifyObserved(observation(authoritative: true))
    }
    func poll() {
        guard hasTrack || isPlaying else { return }
        sim.engine.spotifyObserved(observation(authoritative: false))
    }

    // Engine commands, applied after AppleScript latency.
    func play() {
        engineCommands.append("play")
        sim.schedule(after: commandLatency) { [self] in isPlaying = true; notify() }
    }
    func pause() {
        engineCommands.append("pause")
        sim.schedule(after: commandLatency) { [self] in isPlaying = false; notify() }
    }
    func next() {
        engineNexts += 1
        engineCommands.append("next")
        sim.schedule(after: commandLatency) { [self] in userNext() }
    }
    func seek(to seconds: Double) {
        engineSeeks.append(seconds)
        engineCommands.append("seek")
        sim.schedule(after: commandLatency) { [self] in
            // Like the real client: a seek posts no notification. Seeking to the very end
            // ends the track.
            if let track = current, seconds >= track.duration {
                position = track.duration - 0.001
            } else {
                position = seconds
            }
        }
    }

    // User actions in the Spotify window.
    func userPlay(index: Int, at position: Double = 0) {
        self.index = index
        self.position = position
        hasTrack = true
        isPlaying = true
        notify()
    }
    func userPause() { isPlaying = false; notify() }
    func userResume() { isPlaying = true; notify() }
    func userSeek(to seconds: Double) { position = seconds }
    func userNext() {
        index += 1
        position = 0
        if index >= tracks.count { hasTrack = false; isPlaying = false }
        notify()
    }
}

// MARK: - Apple Music

@MainActor final class SimApple: AppleCommanding {
    weak var sim: Simulation!
    var entries: [(id: String, song: AppleTrack)] = []
    var current: Int?
    var position = 0.0
    var status: AppleStatus = .stopped
    var repeatOne = false
    var startLatency = 0.4
    var seekLatency = 0.15
    /// Songs that fail to start.
    var failing: Set<String> = []
    /// Queue edits that silently do nothing, like a MusicKit insert that throws.
    var setUpcomingFails = false
    /// Skips that silently do nothing.
    var skipFailsSilently = false
    /// Music's AutoPlay: when the queue runs out, Music carries on with a song of its own.
    var autoplay = false

    private var busyUntil = 0.0
    private var nextEntry = 0
    private var autoplayed = 0
    private(set) var starts: [(songID: String, position: Double)] = []
    private(set) var setUpcomingCalls: [[String]] = []
    private(set) var skips = 0

    var currentSong: AppleTrack? { current.map { entries[$0].song } }

    private func enqueue(_ latency: Double, _ action: @escaping () -> Void) {
        let at = max(sim.clock.now, busyUntil) + latency
        busyUntil = at
        sim.schedule(after: at - sim.clock.now, action)
    }

    private func makeEntry(_ song: AppleTrack) -> (id: String, song: AppleTrack) {
        nextEntry += 1
        return ("e\(nextEntry)", song)
    }

    func advance(_ dt: Double) {
        guard status == .playing, let index = current else { return }
        position += dt
        let duration = entries[index].song.duration
        guard position >= duration else { return }
        if repeatOne {
            position -= duration
        } else if index + 1 < entries.count {
            current = index + 1
            position -= duration
        } else {
            queueRanOut()
        }
        observe()
    }

    private func queueRanOut() {
        position = 0
        guard autoplay else {
            current = nil
            status = .stopped
            return
        }
        autoplayed += 1
        entries.append(makeEntry(AppleTrack(id: "autoplay-\(autoplayed)", title: "AutoPlay \(autoplayed)", artist: "Someone Else", duration: 200)))
        current = entries.count - 1
    }

    func observe() {
        let entry = current.map { entries[$0] }
        sim.engine.appleObserved(AppleObservation(entryID: entry?.id, songID: entry?.song.id, status: status, position: position, time: sim.clock.now))
    }
    func poll() { observe() }

    func start(_ tracks: [AppleTrack], at position: Double, play: Bool) {
        starts.append((tracks[0].id, position))
        // Like MusicKit: the old queue goes away, the new entry appears paused, and only later
        // does playback actually begin.
        enqueue(0.02) { [self] in
            current = nil
            status = .stopped
            observe()
        }
        enqueue(0.03) { [self] in
            entries = tracks.map(makeEntry)
            current = 0
            self.position = 0
            status = .paused
            observe()
        }
        enqueue(max(0.01, startLatency - 0.05)) { [self] in
            if failing.contains(tracks[0].id) {
                sim.engine.appleFailed(songID: tracks[0].id)
                return
            }
            self.position = position
            status = play ? .playing : .paused
            observe()
        }
    }
    func setUpcoming(_ tracks: [AppleTrack]) {
        setUpcomingCalls.append(tracks.map(\.id))
        if setUpcomingFails { return }
        enqueue(0.01) { [self] in
            guard let index = current else { return }
            entries = Array(entries[...index]) + tracks.map(makeEntry)
        }
    }
    func play() { enqueue(0.05) { [self] in if current != nil { status = .playing }; observe() } }
    func pause() { enqueue(0.01) { [self] in if current != nil { status = .paused }; observe() } }
    func stop() { enqueue(0.01) { [self] in status = .stopped; current = nil; entries = []; observe() } }
    func seek(to seconds: Double) { enqueue(seekLatency) { [self] in position = seconds; observe() } }
    func skipToNext() {
        skips += 1
        if skipFailsSilently { return }
        // The next entry becomes current a moment before it is heard.
        enqueue(0.01) { [self] in
            let wasPlaying = status == .playing
            status = .paused
            userNext()
            status = current == nil ? .stopped : .paused
            observe()
            if wasPlaying, current != nil {
                enqueue(0.01) { [self] in status = .playing; observe() }
            }
        }
    }
    func setRepeatOne(_ on: Bool) { repeatOne = on }

    // Media keys and Control Center acting on the Apple player directly.
    func userPause() { status = .paused; observe() }
    func userPlay() { status = .playing; observe() }
    func userSeek(to seconds: Double) { position = seconds; observe() }
    func userNext() {
        guard let index = current else { return }
        if index + 1 < entries.count {
            current = index + 1
            position = 0
        } else {
            queueRanOut()
        }
        observe()
    }
}

// MARK: - Catalog and muting

@MainActor final class SimResolver: TrackResolving {
    weak var sim: Simulation!
    var answers: [String: Resolution]
    var latency = 0.25
    private var known: [String: Resolution] = [:]
    private var inFlight: Set<String> = []
    private(set) var unplayable: Set<String> = []

    init(answers: [String: Resolution]) { self.answers = answers }

    func resolution(for track: SpotifyTrack) -> Resolution? { known[track.uri] }

    func resolve(_ tracks: [SpotifyTrack], urgent: Bool) {
        for track in tracks where known[track.uri] == nil && !inFlight.contains(track.uri) {
            inFlight.insert(track.uri)
            sim.schedule(after: latency) { [self] in
                inFlight.remove(track.uri)
                known[track.uri] = answers[track.uri] ?? .unavailable
                sim.engine.resolutionChanged(for: track.uri)
            }
        }
    }

    func preload(_ uris: [String]) {
        for uri in uris { known[uri] = answers[uri] ?? .unavailable }
    }

    func markUnplayable(_ track: SpotifyTrack) {
        unplayable.insert(track.uri)
        known[track.uri] = .unavailable
    }
}

@MainActor final class SimMuter: SpotifyMuting {
    var muted = false
    func setSpotifyMuted(_ muted: Bool) { self.muted = muted }
}

@MainActor final class SimDelegate: SyncEngineDelegate {
    weak var sim: Simulation!
    var fallbacks: [(uri: String, reason: FallbackReason)] = []
    func syncEngine(_ engine: SyncEngine, fellBackToSpotifyFor track: SpotifyTrack, reason: FallbackReason) {
        fallbacks.append((track.uri, reason))
    }
    func syncEngine(_ engine: SyncEngine, startedAppleTrack track: AppleTrack, for spotifyTrack: SpotifyTrack) {}
    func syncEngineWantsQueueRefresh(_ engine: SyncEngine) { sim.refreshQueue() }
}

// MARK: - Fixtures

func makeTrack(_ n: Int, duration: Double = 30, kind: String = "track") -> SpotifyTrack {
    SpotifyTrack(uri: "spotify:\(kind):t\(n)", name: "Song \(n)", artists: ["Artist"], album: "Album", durationMs: Int(duration * 1000), isrc: "ISRC\(n)")
}

func appleVersion(of track: SpotifyTrack, durationDelta: Double = 0) -> AppleTrack {
    AppleTrack(id: "a-\(track.uri.split(separator: ":").last!)", title: track.name, artist: track.primaryArtist, duration: track.duration + durationDelta)
}
