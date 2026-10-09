import Foundation

/// AppleScript bridge to the Music app: its transport, and what it is playing.
final class MusicScripting: @unchecked Sendable {
    static let bundleID = "com.apple.Music"

    struct Snapshot: Sendable {
        var state: String
        var position: Double
        var persistentID: String?
        var name: String
        var artist: String
        var album: String
        var duration: Double
        /// Uptime halfway through the round trip, when Music most likely read its position.
        var time: Double
    }

    enum Command: Sendable {
        case play, pause, stop, nextTrack, seek(Double), repeatOne(Bool), shuffleOff
    }

    let runner = ScriptRunner(bundleID: bundleID)

    private lazy var snapshotSource = runner.guarded("""
        set s to player state as text
        set p to 0
        try
            set p to player position
        end try
        try
            set t to current track
            return {s, p, persistent ID of t, name of t, artist of t, album of t, duration of t}
        on error
            return {s, p}
        end try
        """, otherwise: "return {\"notrunning\"}")

    private func source(_ command: Command) -> String {
        switch command {
        case .play: return runner.guarded("play")
        case .pause: return runner.guarded("pause")
        case .stop: return runner.guarded("stop")
        case .nextTrack: return runner.guarded("next track")
        case .seek(let seconds): return runner.guarded("set player position to \(String(format: "%.3f", max(0, seconds)))")
        case .repeatOne(let on): return runner.guarded("set song repeat to \(on ? "one" : "off")")
        case .shuffleOff: return runner.guarded("set shuffle enabled to false")
        }
    }

    private func isStatic(_ command: Command) -> Bool {
        if case .seek = command { return false }
        return true
    }

    /// nil when Music isn't running or doesn't answer.
    func snapshot() async -> Snapshot? {
        guard let reading = await runner.read(snapshotSource) else { return nil }
        let descriptor = reading.descriptor
        guard descriptor.numberOfItems >= 2, let state = descriptor.atIndex(1)?.stringValue, state != "notrunning" else { return nil }
        var snapshot = Snapshot(state: state, position: descriptor.atIndex(2)?.doubleValue ?? 0, persistentID: nil,
                                name: "", artist: "", album: "", duration: 0, time: (reading.started + reading.finished) / 2)
        if descriptor.numberOfItems >= 7 {
            snapshot.persistentID = descriptor.atIndex(3)?.stringValue
            snapshot.name = descriptor.atIndex(4)?.stringValue ?? ""
            snapshot.artist = descriptor.atIndex(5)?.stringValue ?? ""
            snapshot.album = descriptor.atIndex(6)?.stringValue ?? ""
            snapshot.duration = descriptor.atIndex(7)?.doubleValue ?? 0
        }
        return snapshot
    }

    func perform(_ command: Command) {
        runner.perform(source(command), cache: isStatic(command))
    }

    @discardableResult
    func performAndWait(_ command: Command) async -> Bool {
        await runner.performAndWait(source(command), cache: isStatic(command))
    }

    func requestPermission() async -> OSStatus {
        await runner.requestPermission()
    }

    func permissionStatus() async -> OSStatus {
        await runner.permissionStatus()
    }
}
