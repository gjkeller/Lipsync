import Combine
import Foundation
import LipsyncCore
import MusicKit

/// Plays Apple Music through MusicKit's ApplicationMusicPlayer, inside Lipsync, for builds with
/// a MusicKit-enabled bundle ID. The default backend is the Music app (MusicAppPlayer).
///
/// Commands run strictly in order on one chain. MusicKit's calls are asynchronous, and a queue
/// edit that overtook a skip would edit the wrong entry.
@MainActor final class MusicKitPlayer: AppleCommanding {
    weak var engine: SyncEngine?

    private let player = ApplicationMusicPlayer.shared
    private let catalog: MusicKitCatalog
    private var chain: Task<Void, Never>?
    /// Bumped by every start and stop, so a start still waiting in the chain can tell it was
    /// superseded.
    private var generation = 0
    /// The song id we queued for each entry, in case MusicKit reports an entry's item under a
    /// different id (a library copy, say).
    private var songIDForEntry: [String: String] = [:]
    private var stateSubscription: AnyCancellable?
    private var queueSubscription: AnyCancellable?
    private var timer: Timer?

    init(catalog: MusicKitCatalog) {
        self.catalog = catalog
        // objectWillChange fires before the change lands, so read on the next turn.
        stateSubscription = player.state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.publish() }
        }
        observeQueue()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    var audioVariant: AudioVariant? { player.state.audioVariant }

    // MARK: AppleCommanding

    func start(_ tracks: [AppleTrack], at position: Double, play: Bool) {
        generation += 1
        let mine = generation
        enqueue { [weak self] in
            guard let self, mine == self.generation else { return }
            var songs: [Song] = []
            for track in tracks {
                if let song = await self.catalog.song(for: track.id) { songs.append(song) }
            }
            guard mine == self.generation else { return }
            guard let first = songs.first, first.id.rawValue == tracks.first?.id else {
                self.engine?.appleFailed(songID: tracks.first?.id)
                return
            }
            self.player.state.shuffleMode = .off
            self.player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: first)
            self.observeQueue()
            self.songIDForEntry = [:]
            for (entry, song) in zip(self.player.queue.entries, songs) {
                self.songIDForEntry[entry.id] = song.id.rawValue
            }
            do {
                if position > 0.5 || !play {
                    try await self.player.prepareToPlay()
                    guard mine == self.generation else { return }
                    if position > 0.5 { self.player.playbackTime = position }
                }
                if play {
                    try await self.player.play()
                    // Stopped while starting: don't leave the old start playing.
                    if mine != self.generation { self.player.pause() }
                }
            } catch {
                Log.warn("Apple Music couldn't play \(first.title): \(error)")
                self.engine?.appleFailed(songID: first.id.rawValue)
            }
        }
    }

    func setUpcoming(_ tracks: [AppleTrack]) {
        enqueue { [weak self] in
            guard let self else { return }
            var songs: [Song] = []
            for track in tracks {
                if let song = await self.catalog.song(for: track.id) { songs.append(song) }
            }
            let queue = self.player.queue
            guard let current = queue.currentEntry,
                  let index = queue.entries.firstIndex(where: { $0.id == current.id }) else { return }
            if index + 1 < queue.entries.count {
                queue.entries.removeSubrange((index + 1)...)
            }
            guard !songs.isEmpty else { return }
            do {
                try await queue.insert(songs, position: .tail)
                for (entry, song) in zip(queue.entries.suffix(songs.count), songs) {
                    self.songIDForEntry[entry.id] = song.id.rawValue
                }
            } catch {
                Log.warn("Couldn't queue the next Apple Music song: \(error)")
            }
        }
    }

    func play() {
        enqueue { [weak self] in
            guard let self else { return }
            do {
                try await self.player.play()
            } catch {
                Log.warn("Apple Music couldn't resume: \(error)")
                self.engine?.appleFailed(songID: nil)
            }
        }
    }

    func pause() {
        // Silence can't wait for the chain; pause again once whatever is in flight lands.
        player.pause()
        enqueue { [weak self] in self?.player.pause() }
    }

    func stop() {
        generation += 1
        player.stop()
        enqueue { [weak self] in self?.player.stop() }
    }

    func seek(to seconds: Double) {
        enqueue { [weak self] in self?.player.playbackTime = max(0, seconds) }
    }

    func skipToNext() {
        enqueue { [weak self] in
            do {
                try await self?.player.skipToNextEntry()
            } catch {
                Log.warn("Apple Music couldn't skip: \(error)")
            }
        }
    }

    func setRepeatOne(_ on: Bool) {
        player.state.repeatMode = on ? .one : MusicPlayer.RepeatMode.none
    }

    // MARK: Observation

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor [weak self] in
            await previous?.value
            await Self.run(work, timeout: 10)
            self?.publish()
        }
    }

    /// Runs `work`, but stops waiting after `timeout`, so one MusicKit call that never returns
    /// can't hold up every command after it.
    private static func run(_ work: @escaping @MainActor () async -> Void, timeout: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = Gate(continuation)
            Task { @MainActor in
                await work()
                gate.open()
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if gate.open() { Log.warn("An Apple Music command took over \(Int(timeout))s; moving on") }
            }
        }
    }

    private func observeQueue() {
        queueSubscription = player.queue.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.publish() }
        }
    }

    func publish() {
        let entry = player.queue.currentEntry
        let songID: String? = entry.flatMap { entry in
            if let ours = songIDForEntry[entry.id] { return ours }
            switch entry.item {
            case .song(let song)?: return song.id.rawValue
            case .musicVideo(let video)?: return video.id.rawValue
            default: return nil
            }
        }
        let status: AppleStatus
        switch player.state.playbackStatus {
        case .playing, .seekingForward, .seekingBackward: status = .playing
        case .stopped: status = .stopped
        default: status = .paused
        }
        engine?.appleObserved(AppleObservation(entryID: entry?.id, songID: songID, status: status,
                                               position: player.playbackTime, time: Uptime.now()))
    }
}

/// Resumes a continuation once, whichever side gets there first.
private final class Gate: @unchecked Sendable {
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
