import AppKit
import LipsyncCore
import MusicKit
import ServiceManagement

/// Wires Spotify, Apple Music and the sync engine together, and owns the little UI there is.
@MainActor final class AppController: NSObject, NSApplicationDelegate, SyncEngineDelegate {
    /// Where Apple Music plays. The Music app needs no developer account; MusicKit needs a
    /// MusicKit-enabled bundle ID and is chosen at build time (LIPSYNC_BACKEND=musickit).
    enum Backend {
        case musicApp, musicKit
    }

    static let backend: Backend = {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "LipsyncBackend") as? String)?.lowercased()
        return configured == "musickit" ? .musicKit : .musicApp
    }()

    private let clock = SystemClock()
    private let scripting = SpotifyScripting()
    private let auth = SpotifyAuth()
    private lazy var webAPI = SpotifyWebAPI(auth: auth)
    private lazy var musicApp = MusicAppPlayer()
    private lazy var musicKitCatalog = MusicKitCatalog()
    private lazy var musicKitPlayer = MusicKitPlayer(catalog: musicKitCatalog)
    private lazy var catalog: LipsyncCatalog = Self.backend == .musicKit ? musicKitCatalog : ITunesCatalog()
    private var player: AppleCommanding { Self.backend == .musicKit ? musicKitPlayer : musicApp }
    private lazy var transport = SpotifyTransport(scripting: scripting)
    private lazy var muter = SpotifyMuter(scripting: scripting)
    private lazy var monitor = SpotifyMonitor(scripting: scripting)
    private var engine: SyncEngine?

    private var setupModel: SetupModel?
    private var setupWindow: NSWindow?
    private var tickTimer: Timer?
    private var ticks = 0
    private var queueRefresh: Task<Void, Never>?
    private var lastQueueRefresh = Date.distantPast
    private var lastContextURI: String?
    private var remoteStrikes = 0
    /// Keeps App Nap from stretching Lipsync's timers while Spotify is open.
    private var activity: NSObjectProtocol?

    private static let showStatusNotification = Notification.Name("Lipsync.showStatus")

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0 != me }) {
            DistributedNotificationCenter.default().postNotificationName(Self.showStatusNotification, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showStatusRequested), name: Self.showStatusNotification,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        Log.info("Lipsync \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") starting")
        muter.restoreVolumeLeftByCrash()
        if Settings.onboardingComplete {
            startEngine()
        } else {
            showSetup()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatus()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Hand the audio back to Spotify on the way out.
        if engine != nil {
            player.stop()
            muter.releaseForQuit()
        }
        Log.info("Lipsync quit")
    }

    @objc private func showStatusRequested() {
        showStatus()
    }

    // MARK: Engine

    private func startEngine() {
        guard engine == nil else { return }
        var config = SyncEngine.Config()
        if Self.backend == .musicApp {
            // Apple's public search allows about 20 lookups a minute; look a few songs ahead.
            config.prefetchDepth = 3
        }
        let engine = SyncEngine(spotify: transport, apple: player, muter: muter, resolver: catalog, clock: clock, config: config)
        self.engine = engine
        engine.delegate = self
        engine.setEnabled(Settings.enabled)
        catalog.engine = engine
        catalog.webAPI = webAPI
        catalog.onError = { [weak self] error in self?.catalogFailed(error) }
        switch Self.backend {
        case .musicApp:
            musicApp.engine = engine
            musicApp.runner.onNotAuthorized = { [weak self] in self?.musicControlDenied() }
        case .musicKit:
            musicKitPlayer.engine = engine
        }
        muter.onProblem = { [weak self] problem in self?.muteProblem(problem) }
        scripting.onNotAuthorized = { [weak self] in self?.spotifyControlDenied() }
        auth.onSignedOut = { [weak self] in self?.spotifySignedOut() }

        monitor.onObservation = { [weak self] observation in self?.engine?.spotifyObserved(observation) }
        monitor.onQuit = { [weak self] in
            guard let self else { return }
            self.engine?.spotifyQuit()
            self.setActive(false)
            if Self.backend == .musicApp { self.musicApp.deactivate() }
        }
        monitor.onLaunch = { [weak self] in
            guard let self else { return }
            self.setActive(true)
            if Self.backend == .musicApp { self.musicApp.activate() }
            self.requestQueueRefresh(after: 1.5)
            self.warmLibrary()
        }
        monitor.start()

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task { await checkPlayback() }
        if !auth.isConnected {
            Toaster.shared.show(Toast(id: "connect-spotify", symbol: "waveform", title: "Connect Spotify for gapless playback",
                                      detail: "Without it, there can be a short pause between songs.",
                                      actions: [ToastAction(title: "Connect") { [weak self] in self?.connectSpotify() }],
                                      duration: 8, minimumInterval: 24 * 3600))
        }
    }

    private func tick() {
        guard let engine else { return }
        engine.tick()
        ticks += 1
        if ticks % 2 == 0 { checkRemotePlayback(engine) }
        if ticks % 4 == 0 {
            let playingMusic: Bool = {
                guard case .apple = engine.route else { return false }
                return engine.lastSpotify?.isPlaying == true
            }()
            muter.checkSignal(spotifyIsPlayingMusic: playingMusic)
        }
        // Catch queue edits made in Spotify between songs.
        if engine.lastSpotify?.isPlaying == true, Date().timeIntervalSince(lastQueueRefresh) > 8 {
            requestQueueRefresh(after: 0)
        }
    }

    private func setActive(_ active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "Keeping Apple Music in step with Spotify")
        } else if !active, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    /// Spotify says it's playing, but its audio engine isn't running on this Mac: it's playing
    /// on another device through Spotify Connect, so this Mac stays quiet.
    private func checkRemotePlayback(_ engine: SyncEngine) {
        guard monitor.isRunning, engine.lastSpotify?.isPlaying == true else {
            remoteStrikes = 0
            return
        }
        if SpotifyMuter.spotifyIsOutputtingAudio() {
            remoteStrikes = 0
            if engine.isSpotifyRemote {
                Log.info("Spotify is playing on this Mac again")
                engine.setSpotifyRemote(false)
            }
        } else {
            remoteStrikes += 1
            // Six half-second checks: long enough for Spotify to start its audio locally.
            if remoteStrikes == 6, !engine.isSpotifyRemote {
                Log.info("Spotify is playing on another device")
                engine.setSpotifyRemote(true)
            }
        }
    }

    // MARK: Spotify queue

    private func requestQueueRefresh(after delay: Double = 0.15) {
        guard auth.isConnected else { return }
        lastQueueRefresh = Date()
        queueRefresh?.cancel()
        queueRefresh = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            await self.refreshQueue()
        }
    }

    private func refreshQueue() async {
        guard let engine, webAPI.isAvailable else { return }
        lastQueueRefresh = Date()
        do {
            async let queue = webAPI.queue()
            async let player = webAPI.playerState()
            let (upcoming, state) = try await (queue, player)
            guard let upcoming, let current = upcoming.current else { return }
            engine.upcomingUpdated(after: current.uri, upcoming: upcoming.upcoming, repeatOne: state?.repeatState == "track")
            if let context = state?.contextURI, context != lastContextURI {
                lastContextURI = context
                prefetch(context: context)
            }
        } catch is CancellationError {
        } catch {
            Log.warn("Couldn't read Spotify's queue: \(error)")
        }
    }

    /// Matches Liked Songs and the user's playlists in the background, at most once a day and
    /// in small batches, so clicking a song from the library needs no lookup.
    private func warmLibrary() {
        let key = "libraryWarmedAt"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard auth.isConnected, Date().timeIntervalSince(last) > 20 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var tracks = (try? await self.webAPI.savedTracks(limit: 1000)) ?? []
            for uri in (try? await self.webAPI.playlistURIs(limit: 30)) ?? [] {
                tracks += (try? await self.webAPI.contextTracks(uri: uri, limit: 100)) ?? []
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            var seen = Set<String>()
            let unknown = tracks.filter { $0.kind.isMusic && seen.insert($0.uri).inserted && self.catalog.resolution(for: $0) == nil }
            Log.info("Matching \(unknown.count) library tracks in the background")
            for start in stride(from: 0, to: unknown.count, by: 40) {
                self.catalog.prefetch(Array(unknown[start..<min(start + 40, unknown.count)]))
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    /// Look up the playlist or album being played, so clicking any song in it starts at once.
    private func prefetch(context: String) {
        Task { @MainActor [weak self] in
            guard let self, let tracks = try? await self.webAPI.contextTracks(uri: context, limit: 100), !tracks.isEmpty else { return }
            Log.info("Looking up \(tracks.count) tracks from \(context)")
            self.catalog.prefetch(tracks)
        }
    }

    // MARK: SyncEngineDelegate

    func syncEngine(_ engine: SyncEngine, fellBackToSpotifyFor track: SpotifyTrack, reason: FallbackReason) {
        Log.info("Playing \(track.name) from Spotify (\(reason.rawValue), \(track.uri))")
        switch reason {
        case .notMusic:
            break
        case .notOnAppleMusic:
            guard Settings.showFallbackNotices else { return }
            Toaster.shared.show(Toast(id: "missing-\(track.uri)", symbol: "music.note", title: "Not on Apple Music",
                                      detail: "\(track.name) is playing from Spotify.", duration: 3.5))
        case .appleTimedOut:
            Toaster.shared.show(Toast(id: "slow", symbol: "hourglass", title: "Apple Music is slow to respond",
                                      detail: "This song is playing from Spotify.", style: .warning, minimumInterval: 600))
        case .applePlaybackFailed:
            Toaster.shared.show(Toast(id: "failed-\(track.uri)", symbol: "exclamationmark.triangle.fill", title: "Apple Music couldn't play this song",
                                      detail: "\(track.name) is playing from Spotify.", style: .warning))
        }
    }

    func syncEngine(_ engine: SyncEngine, startedAppleTrack track: AppleTrack, for spotifyTrack: SpotifyTrack) {
        Log.info("Apple Music: \(track.title) — \(track.artist) for \(spotifyTrack.uri)")
    }

    func syncEngineWantsQueueRefresh(_ engine: SyncEngine) {
        requestQueueRefresh()
    }

    // MARK: Problems

    private func checkPlayback() async {
        switch Self.backend {
        case .musicApp:
            guard MediaRemote.shared.isAvailable else {
                Toaster.shared.show(Toast(id: "mediaremote", symbol: "exclamationmark.triangle.fill", title: "This macOS can't start songs in Music for Lipsync",
                                          detail: "Songs will play from Spotify. Check the log for details.", style: .error, duration: 15))
                return
            }
            if await musicApp.runner.permissionStatus() == OSStatus(errAEEventNotPermitted) {
                musicControlDenied()
            }
        case .musicKit:
            await checkMusicKit()
        }
    }

    private func checkMusicKit() async {
        guard MusicAuthorization.currentStatus == .authorized else {
            Toaster.shared.show(Toast(id: "apple-access", symbol: "music.note", title: "Lipsync needs access to Apple Music",
                                      style: .error, actions: [ToastAction(title: "Allow") { Task { _ = await MusicAuthorization.request() } }],
                                      duration: 12))
            return
        }
        if let subscription = try? await MusicSubscription.current, !subscription.canPlayCatalogContent {
            Toaster.shared.show(Toast(id: "subscription", symbol: "music.note", title: "Apple Music subscription needed",
                                      detail: "Sign in to the Music app with an account that has Apple Music.", style: .error, duration: 12))
        }
        // A tiny catalog request surfaces developer-token and sign-in problems now rather than
        // at the first song.
        var probe = MusicCatalogSearchRequest(term: "hello", types: [Song.self])
        probe.limit = 1
        do {
            _ = try await probe.response()
        } catch {
            catalogFailed(error)
        }
    }

    private func catalogFailed(_ error: Error) {
        if let tokenError = error as? MusicTokenRequestError {
            switch tokenError {
            case .developerTokenRequestFailed:
                Toaster.shared.show(Toast(id: "developer-token", symbol: "key.fill", title: "Apple Music isn't enabled for this build",
                                          detail: "Turn on MusicKit for \(Bundle.main.bundleIdentifier ?? "this app")'s App ID in your Apple Developer account, then reopen Lipsync.",
                                          style: .error, duration: 15, minimumInterval: 600))
            case .userNotSignedIn:
                Toaster.shared.show(Toast(id: "apple-signin", symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in to Apple Music",
                                          detail: "Open the Music app and sign in with your Apple Account.", style: .error, duration: 10))
            case .privacyAcknowledgementRequired:
                Toaster.shared.show(Toast(id: "apple-privacy", symbol: "music.note", title: "Open the Music app once",
                                          detail: "Apple Music needs you to accept its terms there first.", style: .error, duration: 10,
                                          minimumInterval: 600))
            case .permissionDenied:
                Toaster.shared.show(Toast(id: "apple-access", symbol: "music.note", title: "Lipsync needs access to Apple Music",
                                          style: .error, actions: [ToastAction(title: "Open Settings") { Self.openPrivacySettings("Privacy_Media") }],
                                          duration: 12))
            default:
                Toaster.shared.show(Toast(id: "apple-token", symbol: "music.note", title: "Apple Music sign-in problem",
                                          detail: tokenError.localizedDescription, style: .error, minimumInterval: 600))
            }
        } else if error is URLError {
            Toaster.shared.show(Toast(id: "offline", symbol: "wifi.slash", title: "Can't reach Apple Music",
                                      detail: "Songs play from Spotify until the connection is back.", style: .warning, minimumInterval: 300))
        }
    }

    private func muteProblem(_ problem: SpotifyMuter.MuteProblem) {
        Toaster.shared.show(Toast(id: "mute-permission", symbol: "speaker.slash.fill", title: "Muting Spotify with its volume slider",
                                  detail: "Allow audio recording for Lipsync so Spotify's own volume stays untouched.",
                                  style: .warning,
                                  actions: [ToastAction(title: "Open Settings") { Self.openPrivacySettings("Privacy_ScreenCapture") }],
                                  duration: 10, minimumInterval: 3600))
    }

    private func musicControlDenied() {
        Toaster.shared.show(Toast(id: "automation-music", symbol: "hand.raised.fill", title: "Lipsync can't control Music",
                                  detail: "Allow it under Privacy & Security → Automation → Lipsync → Music.", style: .error,
                                  actions: [ToastAction(title: "Open Settings") { Self.openPrivacySettings("Privacy_Automation") }],
                                  duration: 12, minimumInterval: 600))
    }

    private func spotifyControlDenied() {
        Toaster.shared.show(Toast(id: "automation", symbol: "hand.raised.fill", title: "Lipsync can't control Spotify",
                                  detail: "Allow it under Privacy & Security → Automation.", style: .error,
                                  actions: [ToastAction(title: "Open Settings") { Self.openPrivacySettings("Privacy_Automation") }],
                                  duration: 12, minimumInterval: 600))
    }

    private func spotifySignedOut() {
        Toaster.shared.show(Toast(id: "spotify-signed-out", symbol: "waveform", title: "Reconnect Spotify",
                                  detail: "Spotify signed Lipsync out. Reconnect for gapless playback.", style: .warning,
                                  actions: [ToastAction(title: "Reconnect") { [weak self] in self?.connectSpotify() }],
                                  duration: 12, minimumInterval: 3600))
    }

    private static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Status

    private func showStatus() {
        guard let engine else {
            showSetup()
            return
        }
        let title: String
        var detail: String?
        if !Settings.enabled {
            title = "Lipsync is off"
            detail = "Spotify plays as usual."
        } else {
            switch engine.route {
            case .apple:
                title = "Playing from Apple Music"
                detail = Self.backend == .musicKit ? musicKitPlayer.audioVariant.map(Self.describe) : "In the Music app, with its quality and EQ settings."
            case .spotify:
                title = "Playing this song from Spotify"
                detail = "It isn't on Apple Music."
            case .loading:
                title = "Starting on Apple Music…"
            case .idle:
                title = "Lipsync is on"
                detail = engine.isSpotifyRemote ? "Spotify is playing on another device." : "Play something in Spotify."
            }
        }
        var actions = [ToastAction(title: Settings.enabled ? "Turn Off" : "Turn On") { [weak self] in self?.toggleEnabled() }]
        if !auth.isConnected {
            actions.append(ToastAction(title: "Connect Spotify") { [weak self] in self?.connectSpotify() })
        }
        actions.append(ToastAction(title: "Quit") { NSApp.terminate(nil) })
        Toaster.shared.show(Toast(id: "status", symbol: Settings.enabled ? "waveform" : "pause.circle", title: title, detail: detail,
                                  actions: actions, duration: 8, minimumInterval: 0))
    }

    private static func describe(_ variant: AudioVariant) -> String {
        switch variant {
        case .dolbyAtmos: return "Dolby Atmos"
        case .dolbyAudio: return "Dolby Audio"
        case .lossless: return "Lossless"
        case .highResolutionLossless: return "Hi-Res Lossless"
        case .spatialAudio: return "Spatial Audio"
        case .lossyStereo: return "Standard quality (AAC). Turn on Lossless in the Music app's settings for more."
        @unknown default: return ""
        }
    }

    private func toggleEnabled() {
        Settings.enabled.toggle()
        engine?.setEnabled(Settings.enabled)
        Log.info(Settings.enabled ? "Turned on" : "Turned off")
    }

    // MARK: Setup

    private func showSetup() {
        if let setupWindow {
            NSApp.activate(ignoringOtherApps: true)
            setupWindow.makeKeyAndOrderFront(nil)
            return
        }
        let model = SetupModel()
        setupModel = model
        refreshSetupState()
        model.allowAppleMusic = { [weak self] in self?.setupAppleMusic() }
        model.allowSpotifyControl = { [weak self] in self?.setupSpotifyControl() }
        model.allowMute = { [weak self] in self?.setupMute() }
        model.connectSpotify = { [weak self] in self?.connectSpotify() }
        model.finish = { [weak self] in self?.finishSetup() }
        let window = SetupWindow.make(model: model)
        setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func refreshSetupState() {
        guard let model = setupModel else { return }
        model.usesMusicApp = Self.backend == .musicApp
        if Self.backend == .musicKit, MusicAuthorization.currentStatus == .authorized { model.appleMusic = .done }
        if auth.isConnected { model.spotifyAccount = .done }
        Task { @MainActor in
            if await self.scripting.permissionStatus() == noErr { model.spotifyControl = .done }
            if Self.backend == .musicApp, await self.musicApp.runner.permissionStatus() == noErr { model.appleMusic = .done }
        }
    }

    private func setupAppleMusic() {
        guard let model = setupModel else { return }
        if Self.backend == .musicApp {
            setupMusicControl(model)
            return
        }
        model.appleMusic = .working
        Task { @MainActor in
            switch await MusicAuthorization.request() {
            case .authorized:
                if let subscription = try? await MusicSubscription.current, !subscription.canPlayCatalogContent {
                    model.appleMusic = .failed("This Apple Account doesn't have an Apple Music subscription. Sign in to one in the Music app.")
                } else {
                    model.appleMusic = .done
                }
            case .denied, .restricted:
                model.appleMusic = .failed("Allowed in System Settings → Privacy & Security → Media & Apple Music.")
                Self.openPrivacySettings("Privacy_Media")
            default:
                model.appleMusic = .todo
            }
        }
    }

    /// Asks for permission to control the Music app, opening it in the background first: macOS
    /// can only ask about an app that is running.
    private func setupMusicControl(_ model: SetupModel) {
        model.appleMusic = .working
        Task { @MainActor in
            if !self.musicApp.runner.isRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MusicScripting.bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            switch await self.musicApp.runner.requestPermission() {
            case noErr:
                model.appleMusic = .done
            case OSStatus(procNotFound):
                model.appleMusic = .failed("Open the Music app, then try again.")
            default:
                model.appleMusic = .failed("Allow it in System Settings → Privacy & Security → Automation → Lipsync.")
                Self.openPrivacySettings("Privacy_Automation")
            }
        }
    }

    private func setupSpotifyControl() {
        guard let model = setupModel else { return }
        model.spotifyControl = .working
        Task { @MainActor in
            if !SpotifyScripting.isRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyScripting.bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            switch await self.scripting.requestPermission() {
            case noErr:
                model.spotifyControl = .done
            case OSStatus(procNotFound):
                model.spotifyControl = .failed("Open Spotify, then try again.")
            default:
                model.spotifyControl = .failed("Allow it in System Settings → Privacy & Security → Automation → Lipsync.")
                Self.openPrivacySettings("Privacy_Automation")
            }
        }
    }

    private func setupMute() {
        guard let model = setupModel else { return }
        muter.requestPermission()
        model.mute = .done
    }

    private func connectSpotify() {
        if let model = setupModel {
            let typed = model.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { Settings.spotifyClientID = typed }
            guard Settings.spotifyClientID != nil else {
                model.spotifyAccount = .failed("Paste your Spotify app's client ID first.")
                return
            }
            model.spotifyAccount = .working
        }
        Task { @MainActor in
            do {
                try await self.auth.connect()
                self.setupModel?.spotifyAccount = .done
                self.requestQueueRefresh(after: 0)
                if self.engine != nil { self.warmLibrary() }
                if self.setupModel == nil {
                    Toaster.shared.show(Toast(id: "spotify-connected", symbol: "checkmark.circle.fill", title: "Spotify connected", duration: 3, minimumInterval: 0))
                }
            } catch {
                Log.warn("Spotify sign-in failed: \(error)")
                self.setupModel?.spotifyAccount = .failed(error.localizedDescription)
                if self.setupModel == nil {
                    Toaster.shared.show(Toast(id: "spotify-connect-failed", symbol: "exclamationmark.triangle.fill", title: "Couldn't connect Spotify",
                                              detail: error.localizedDescription, style: .error, minimumInterval: 0))
                }
            }
        }
    }

    private func finishSetup() {
        guard let model = setupModel else { return }
        Settings.onboardingComplete = true
        do {
            if model.openAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.warn("Couldn't change the login item: \(error)")
        }
        setupWindow?.close()
        setupWindow = nil
        setupModel = nil
        startEngine()
        Toaster.shared.show(Toast(id: "ready", symbol: "waveform", title: "Lipsync is on",
                                  detail: "Play anything in Spotify. You'll hear it from Apple Music.", duration: 5, minimumInterval: 0))
    }
}
