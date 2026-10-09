import AppKit
import Foundation

/// Runs AppleScript against one app, off the main thread, so a busy or hung app never blocks
/// it. Every app's scripts share one serial queue: NSAppleScripts running at the same time on
/// different threads can swap results (a Spotify read came back with Music's track).
final class ScriptRunner: @unchecked Sendable {
    private static let sharedQueue = DispatchQueue(label: "lipsync.applescript", qos: .userInitiated)

    let bundleID: String
    private let queue = ScriptRunner.sharedQueue
    /// Compiled scripts, keyed by source. Only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]
    private var lastDenialReport = 0.0

    /// Called on the main actor, at most every 30 seconds, when macOS refuses Lipsync control
    /// of the app.
    @MainActor var onNotAuthorized: (() -> Void)?

    init(bundleID: String) {
        self.bundleID = bundleID
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Wraps a script body so it only runs while the app is running: addressing a closed app
    /// would launch it.
    func guarded(_ body: String, otherwise fallback: String = "") -> String {
        """
        if application id "\(bundleID)" is running then
            with timeout of 3 seconds
                tell application id "\(bundleID)"
                    \(body)
                end tell
            end timeout
        end if
        \(fallback)
        """
    }

    struct Reading {
        var descriptor: NSAppleEventDescriptor
        var started: Double
        var finished: Double
    }

    func read(_ source: String) async -> Reading? {
        await withCheckedContinuation { continuation in
            queue.async {
                let started = Uptime.now()
                let result = self.execute(source, cache: true)
                let finished = Uptime.now()
                guard case .success(let descriptor) = result else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Reading(descriptor: descriptor, started: started, finished: finished))
            }
        }
    }

    /// Runs a command without waiting. Static commands are compiled once and kept.
    func perform(_ source: String, cache: Bool) {
        queue.async {
            if case .failure(let error) = self.execute(source, cache: cache) {
                Log.warn("AppleScript to \(self.bundleID) failed: \(error)")
            }
        }
    }

    /// Runs a command and waits for it.
    @discardableResult
    func performAndWait(_ source: String, cache: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                if case .failure(let error) = self.execute(source, cache: cache) {
                    Log.warn("AppleScript to \(self.bundleID) failed: \(error)")
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }
    }

    /// Runs a command before returning. Only for quitting, when an async command would be lost.
    func performNow(_ source: String) {
        queue.sync {
            _ = self.execute(source, cache: false)
        }
    }

    /// Asks macOS for permission to control the app, showing the prompt if needed. Blocks while
    /// the prompt is up, so it runs on the script queue.
    func requestPermission() async -> OSStatus {
        await determinePermission(ask: true)
    }

    /// The permission state without prompting. noErr when allowed.
    func permissionStatus() async -> OSStatus {
        await determinePermission(ask: false)
    }

    private func determinePermission(ask: Bool) async -> OSStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: self.bundleID)
                continuation.resume(returning: AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask))
            }
        }
    }

    enum ScriptError: Error, CustomStringConvertible {
        case compile(String)
        case run(Int, String)

        var description: String {
            switch self {
            case .compile(let message): return "compile error: \(message)"
            case .run(let code, let message): return "error \(code): \(message)"
            }
        }
    }

    private func execute(_ source: String, cache: Bool) -> Result<NSAppleEventDescriptor, ScriptError> {
        dispatchPrecondition(condition: .onQueue(queue))
        let script: NSAppleScript
        if let existing = compiled[source] {
            script = existing
        } else {
            guard let fresh = NSAppleScript(source: source) else { return .failure(.compile("could not create script")) }
            var compileError: NSDictionary?
            guard fresh.compileAndReturnError(&compileError) else {
                return .failure(.compile(compileError?[NSAppleScript.errorMessage] as? String ?? "unknown"))
            }
            if cache { compiled[source] = fresh }
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? -1
            let message = error[NSAppleScript.errorMessage] as? String ?? ""
            if code == -1743, Uptime.now() - lastDenialReport > 30 {
                lastDenialReport = Uptime.now()
                Task { @MainActor in self.onNotAuthorized?() }
            }
            return .failure(.run(code, message))
        }
        return .success(result)
    }
}
