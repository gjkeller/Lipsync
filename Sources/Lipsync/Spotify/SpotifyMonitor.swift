import AppKit
import Foundation
import LipsyncCore

/// Watches the Spotify desktop client.
///
/// Spotify posts a distributed notification the moment its track or play state changes; those
/// readings are authoritative and arrive within milliseconds. Seeks post nothing, so Spotify is
/// also polled over AppleScript, twice a second while it plays.
@MainActor final class SpotifyMonitor {
    var onObservation: ((SpotifyObservation) -> Void)?
    var onLaunch: (() -> Void)?
    var onQuit: (() -> Void)?

    private let scripting: SpotifyScripting
    private var pollTask: Task<Void, Never>?
    private var isPlaying = false
    private(set) var isRunning = false

    init(scripting: SpotifyScripting) {
        self.scripting = scripting
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(playbackStateChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, suspensionBehavior: .deliverImmediately
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(applicationLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(applicationTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if SpotifyScripting.isRunning { spotifyLaunched() }
    }

    /// Read Spotify now rather than at the next poll.
    func pollNow() {
        Task { await poll() }
    }

    // MARK: Events

    @objc private func playbackStateChanged(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let state = (info["Player State"] as? String ?? "stopped").lowercased()
        let trackID = info["Track ID"] as? String
        let duration = (info["Duration"] as? NSNumber)?.intValue ?? 0
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        let track = makeTrack(uri: trackID, name: info["Name"] as? String, artist: info["Artist"] as? String,
                              album: info["Album"] as? String, durationMs: duration)
        deliver(SpotifyObservation(track: track, isPlaying: state == "playing", position: position, time: Uptime.now(), isAuthoritative: true))
    }

    @objc private func applicationLaunched(_ note: Notification) {
        guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == SpotifyScripting.bundleID else { return }
        spotifyLaunched()
    }

    @objc private func applicationTerminated(_ note: Notification) {
        guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == SpotifyScripting.bundleID else { return }
        Log.info("Spotify quit")
        isRunning = false
        isPlaying = false
        pollTask?.cancel()
        pollTask = nil
        onQuit?()
    }

    private func spotifyLaunched() {
        guard !isRunning else { return }
        Log.info("Spotify is running")
        isRunning = true
        onLaunch?()
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let interval = self.isPlaying ? 0.5 : 1.5
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func poll() async {
        guard isRunning, let snapshot = await scripting.snapshot(), isRunning else { return }
        let track = makeTrack(uri: snapshot.trackID, name: snapshot.name, artist: snapshot.artist, album: snapshot.album, durationMs: snapshot.durationMs)
        deliver(SpotifyObservation(track: track, isPlaying: snapshot.state == "playing", position: snapshot.position, time: snapshot.time,
                                   isAuthoritative: false, issuedAt: snapshot.started))
    }

    private func deliver(_ observation: SpotifyObservation) {
        isPlaying = observation.isPlaying
        onObservation?(observation)
    }

    private func makeTrack(uri: String?, name: String?, artist: String?, album: String?, durationMs: Int) -> SpotifyTrack? {
        guard let uri, !uri.isEmpty else { return nil }
        let artists = (artist ?? "").isEmpty ? [] : [artist!]
        return SpotifyTrack(uri: uri, name: name ?? "", artists: artists, album: album ?? "", durationMs: durationMs)
    }
}

/// The engine's handle on Spotify's transport.
@MainActor final class SpotifyTransport: SpotifyCommanding {
    private let scripting: SpotifyScripting

    init(scripting: SpotifyScripting) {
        self.scripting = scripting
    }

    func play() { scripting.perform(.play) }
    func pause() { scripting.perform(.pause) }
    func next() { scripting.perform(.nextTrack) }
    func seek(to seconds: Double) { scripting.perform(.seek(seconds)) }
}
