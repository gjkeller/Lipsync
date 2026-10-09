import AppKit
import Foundation

/// AppleScript bridge to the Spotify desktop client.
final class SpotifyScripting: @unchecked Sendable {
    static let bundleID = "com.spotify.client"

    struct Snapshot: Sendable {
        var state: String
        var position: Double
        var trackID: String?
        var name: String
        var artist: String
        var album: String
        var durationMs: Int
        /// Uptime halfway through the round trip, when Spotify most likely read its position.
        var time: Double
        /// Uptime when the script was sent.
        var started: Double
    }

    enum Command: Sendable {
        case play, pause, nextTrack, seek(Double), setVolume(Int)
    }

    let runner = ScriptRunner(bundleID: bundleID)

    @MainActor var onNotAuthorized: (() -> Void)? {
        get { runner.onNotAuthorized }
        set { runner.onNotAuthorized = newValue }
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private lazy var snapshotSource = runner.guarded("""
        set s to player state as text
        set p to 0
        try
            set p to player position
        end try
        try
            set t to current track
            return {s, p, id of t, name of t, artist of t, album of t, duration of t}
        on error
            return {s, p}
        end try
        """, otherwise: "return {\"notrunning\"}")

    private lazy var volumeSource = runner.guarded("return sound volume", otherwise: "return -1")

    private func commandSource(_ command: Command) -> String {
        switch command {
        case .play: return runner.guarded("play")
        case .pause: return runner.guarded("pause")
        case .nextTrack: return runner.guarded("next track")
        case .seek(let seconds): return runner.guarded("set player position to \(String(format: "%.3f", max(0, seconds)))")
        case .setVolume(let volume): return runner.guarded("set sound volume to \(min(100, max(0, volume)))")
        }
    }

    func snapshot() async -> Snapshot? {
        guard let reading = await runner.read(snapshotSource) else { return nil }
        let descriptor = reading.descriptor
        guard descriptor.numberOfItems >= 2, let state = descriptor.atIndex(1)?.stringValue, state != "notrunning" else { return nil }
        var snapshot = Snapshot(state: state, position: descriptor.atIndex(2)?.doubleValue ?? 0, trackID: nil,
                                name: "", artist: "", album: "", durationMs: 0,
                                time: (reading.started + reading.finished) / 2, started: reading.started)
        if descriptor.numberOfItems >= 7 {
            snapshot.trackID = descriptor.atIndex(3)?.stringValue
            snapshot.name = descriptor.atIndex(4)?.stringValue ?? ""
            snapshot.artist = descriptor.atIndex(5)?.stringValue ?? ""
            snapshot.album = descriptor.atIndex(6)?.stringValue ?? ""
            snapshot.durationMs = Int(descriptor.atIndex(7)?.int32Value ?? 0)
        }
        return snapshot
    }

    func volume() async -> Int? {
        guard let reading = await runner.read(volumeSource) else { return nil }
        let value = Int(reading.descriptor.int32Value)
        return value >= 0 ? value : nil
    }

    func perform(_ command: Command) {
        let isStatic: Bool = {
            switch command {
            case .seek, .setVolume: return false
            default: return true
            }
        }()
        runner.perform(commandSource(command), cache: isStatic)
    }

    /// Runs a command before returning. Only for quitting, when an async command would be lost.
    func performNow(_ command: Command) {
        runner.performNow(commandSource(command))
    }

    func requestPermission() async -> OSStatus {
        await runner.requestPermission()
    }

    func permissionStatus() async -> OSStatus {
        await runner.permissionStatus()
    }
}
