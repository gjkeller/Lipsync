import AppKit
import Foundation
import LipsyncCore

/// Plays Apple Music in the Music app itself, so you get everything it does: Lossless,
/// Hi-Res, Dolby Atmos, your EQ and Sound Check, its own Now Playing.
///
/// Songs are started and queued through MediaRemote (`MediaRemote`), the way Siri and Handoff
/// start them. Transport and position go through AppleScript, which is also how Lipsync reads
/// what Music is doing, four times a second and right away whenever Music announces a change.
///
/// Commands run strictly in order on one chain, with a timeout each, because Music's replies
/// arrive asynchronously and a queue edit that overtook a start would edit the wrong queue.
@MainActor final class MusicAppPlayer: AppleCommanding {
    weak var engine: SyncEngine?

    private let scripting = MusicScripting()
    private let remote = MediaRemote.shared
    private var chain: Task<Void, Never>?
    /// Bumped by every start and stop, so a start still waiting in the chain can tell it was
    /// superseded.
    private var generation = 0
    /// Songs Lipsync asked Music to play, so its reports can be matched back to them.
    private var known: [String: AppleTrack] = [:]
    private var recentIDs: [String] = []
    private var storeIDForPersistentID: [String: String] = [:]
    private var pollTask: Task<Void, Never>?
    private var pollRequested = false
    private(set) var lastObservation: AppleObservation?

    var runner: ScriptRunner { scripting.runner }
    var isAvailable: Bool { remote.isAvailable }

    init() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playerInfoChanged(_:)), name: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, suspensionBehavior: .deliverImmediately
        )
    }

    /// Watch Music while Spotify is open; launch Music hidden so the first song starts fast.
    func activate() {
        guard pollTask == nil else { return }
        Task { _ = await ensureMusicRunning() }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func deactivate() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: AppleCommanding

    func start(_ tracks: [AppleTrack], at position: Double, play: Bool) {
        guard let first = tracks.first else { return }
        remember(tracks)
        generation += 1
        let mine = generation
        enqueue { [weak self] in
            guard let self, mine == self.generation else { return }
            guard await self.ensureMusicRunning() else {
                Log.warn("The Music app didn't start")
                self.engine?.appleFailed(songID: first.id)
                return
            }
            guard mine == self.generation else { return }
            // Anything left in Up Next from before would play after this song.
            await self.remote.send(.clearUpNextQueue)
            guard mine == self.generation else { return }
            guard await self.remote.setQueue(storeIDs: [first.id], playNow: play) else {
                Log.warn("Music refused to play \(first.title) (\(first.id))")
                self.engine?.appleFailed(songID: first.id)
                return
            }
            guard mine == self.generation else { return }
            if tracks.count > 1, !(await self.remote.insert(storeIDs: tracks.dropFirst().map(\.id), at: .next)) {
                self.engine?.appleUpcomingFailed()
            }
            if position > 0.5, await self.waitUntilCurrent(first.id, timeout: 6), mine == self.generation {
                await self.scripting.performAndWait(.seek(position))
            }
        }
    }

    func setUpcoming(_ tracks: [AppleTrack]) {
        remember(tracks)
        enqueue { [weak self] in
            guard let self else { return }
            await self.remote.send(.clearUpNextQueue)
            guard !tracks.isEmpty else { return }
            if !(await self.remote.insert(storeIDs: tracks.map(\.id), at: .next)) {
                Log.warn("Couldn't queue the next song in Music")
                self.engine?.appleUpcomingFailed()
            }
        }
    }

    func play() {
        enqueue { [weak self] in await self?.scripting.performAndWait(.play) }
    }

    func pause() {
        // Silence can't wait for the chain; pause again once whatever is in flight lands.
        scripting.perform(.pause)
        enqueue { [weak self] in await self?.scripting.performAndWait(.pause) }
    }

    func stop() {
        generation += 1
        scripting.perform(.pause)
        enqueue { [weak self] in await self?.scripting.performAndWait(.stop) }
    }

    func seek(to seconds: Double) {
        enqueue { [weak self] in await self?.scripting.performAndWait(.seek(seconds)) }
    }

    func skipToNext() {
        enqueue { [weak self] in await self?.scripting.performAndWait(.nextTrack) }
    }

    func setRepeatOne(_ on: Bool) {
        scripting.perform(.repeatOne(on))
    }

    // MARK: Music app

    private func ensureMusicRunning() async -> Bool {
        if runner.isRunning, await scripting.snapshot() != nil { return true }
        if !runner.isRunning {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicScripting.bundleID) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            Log.info("Opening the Music app in the background")
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        for _ in 0..<40 {
            if await scripting.snapshot() != nil {
                // Give Music a moment to register for remote commands after launching.
                try? await Task.sleep(nanoseconds: 700_000_000)
                scripting.perform(.shuffleOff)
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func waitUntilCurrent(_ songID: String, timeout: Double) async -> Bool {
        let deadline = Uptime.now() + timeout
        while Uptime.now() < deadline {
            if lastObservation?.songID == songID { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func remember(_ tracks: [AppleTrack]) {
        for track in tracks {
            known[track.id] = track
            recentIDs.removeAll { $0 == track.id }
            recentIDs.insert(track.id, at: 0)
        }
        if recentIDs.count > 50 {
            for id in recentIDs.suffix(from: 50) { known[id] = nil }
            recentIDs.removeLast(recentIDs.count - 50)
        }
    }

    // MARK: Observation

    @objc private func playerInfoChanged(_ note: Notification) {
        let info = note.userInfo ?? [:]
        if let url = info["Store URL"] as? String, let storeID = Self.storeID(fromURL: url),
           let persistentID = Self.persistentID(info["PersistentID"]) {
            storeIDForPersistentID[persistentID] = storeID
        }
        pollNow()
    }

    private func pollNow() {
        guard !pollRequested else { return }
        pollRequested = true
        Task { @MainActor [weak self] in
            await self?.poll()
            self?.pollRequested = false
        }
    }

    private func poll() async {
        let now = Uptime.now()
        guard let snapshot = await scripting.snapshot() else {
            publish(AppleObservation(entryID: nil, songID: nil, status: .stopped, position: 0, time: now))
            return
        }
        let status: AppleStatus
        switch snapshot.state {
        case "playing", "fast forwarding", "rewinding": status = .playing
        case "paused": status = .paused
        default: status = .stopped
        }
        let songID = snapshot.persistentID.map { recognize($0, name: snapshot.name, artist: snapshot.artist, duration: snapshot.duration) }
        publish(AppleObservation(entryID: snapshot.persistentID, songID: songID, status: status, position: snapshot.position, time: snapshot.time))
    }

    private func publish(_ observation: AppleObservation) {
        if let last = lastObservation, observation.time < last.time { return }
        lastObservation = observation
        engine?.appleObserved(observation)
    }

    /// Which of the songs Lipsync queued Music is playing. Music's own report of the store ID
    /// wins; otherwise the newest queued song with the same title, artist and length.
    private func recognize(_ persistentID: String, name: String, artist: String, duration: Double) -> String {
        if let id = storeIDForPersistentID[persistentID], known[id] != nil { return id }
        for id in recentIDs {
            guard let song = known[id], Self.looksLike(song, name: name, artist: artist, duration: duration) else { continue }
            storeIDForPersistentID[persistentID] = id
            return id
        }
        return storeIDForPersistentID[persistentID] ?? "music:\(persistentID)"
    }

    static func looksLike(_ song: AppleTrack, name: String, artist: String, duration: Double) -> Bool {
        let title = Matcher.similarity(Matcher.normalizeTitle(song.title), Matcher.normalizeTitle(name))
        let a = Matcher.normalizeArtist(song.artist), b = Matcher.normalizeArtist(artist)
        let artistMatches = a == b || (" " + a + " ").contains(" " + b + " ") || (" " + b + " ").contains(" " + a + " ")
            || Matcher.similarity(a, b) >= 0.6
        let lengthMatches = duration <= 0 || song.duration <= 0 || abs(song.duration - duration) < 4
        return title >= 0.85 && artistMatches && lengthMatches
    }

    static func storeID(fromURL string: String) -> String? {
        guard let components = URLComponents(string: string) else { return nil }
        for name in ["i", "id"] {
            if let value = components.queryItems?.first(where: { $0.name == name })?.value, !value.isEmpty, value.allSatisfy(\.isNumber) {
                return value
            }
        }
        let last = components.path.split(separator: "/").last.map(String.init) ?? ""
        return !last.isEmpty && last.allSatisfy(\.isNumber) ? last : nil
    }

    /// Music reports persistent IDs as signed 64-bit numbers; AppleScript gives the same
    /// value as 16 hex digits.
    static func persistentID(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return String(format: "%016llX", UInt64(bitPattern: number.int64Value)) }
        if let string = value as? String, !string.isEmpty { return string.uppercased() }
        return nil
    }

    // MARK: Chain

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor [weak self] in
            await previous?.value
            await Self.run(work, timeout: 12)
            await self?.poll()
        }
    }

    /// Runs `work`, but stops waiting after `timeout`, so a call that never returns can't hold
    /// up every command after it.
    private static func run(_ work: @escaping @MainActor () async -> Void, timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ChainGate(continuation)
            Task { @MainActor in
                await work()
                gate.open()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if gate.open() { Log.warn("A Music command took over \(Int(timeout))s; moving on") }
            }
        }
    }
}

/// Resumes a continuation once, whichever side gets there first.
private final class ChainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func open() -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
        return pending != nil
    }
}
