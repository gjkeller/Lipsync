import Foundation
import LipsyncCore

enum Settings {
    private static let defaults = UserDefaults.standard

    static var onboardingComplete: Bool {
        get { defaults.bool(forKey: "onboardingComplete") }
        set { defaults.set(newValue, forKey: "onboardingComplete") }
    }

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    /// Show a short notice when a song plays from Spotify because Apple Music doesn't have it.
    static var showFallbackNotices: Bool {
        get { defaults.object(forKey: "showFallbackNotices") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showFallbackNotices") }
    }

    /// Baked in at build time (Info.plist) or entered during setup.
    static var spotifyClientID: String? {
        get {
            if let stored = defaults.string(forKey: "spotifyClientID"), !stored.isEmpty { return stored }
            let baked = Bundle.main.object(forInfoDictionaryKey: "LipsyncSpotifyClientID") as? String
            return baked?.isEmpty == false ? baked : nil
        }
        set { defaults.set(newValue, forKey: "spotifyClientID") }
    }
}

/// Seconds since boot, readable from any thread. Every observation uses this clock.
enum Uptime {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
}

@MainActor final class SystemClock: EngineClock {
    var now: Double { Uptime.now() }
}
