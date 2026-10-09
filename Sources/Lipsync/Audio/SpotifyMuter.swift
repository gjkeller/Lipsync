import CoreAudio
import Foundation
import LipsyncCore

/// Silences Spotify with a Core Audio process tap.
///
/// The tap is created with `.muted`: while it exists, Spotify's audio goes nowhere, but
/// Spotify itself keeps playing normally with its volume untouched, so its listening history
/// and recommendations see an ordinary listen. Unmuting removes the tap.
///
/// While Spotify is actually producing sound, Lipsync also reads the tap. macOS 26 only mutes a
/// tap while it is being read, and the IO block notes whether any signal arrives, which reveals
/// a refused audio permission. Nothing read is kept. Reading stops a few seconds after Spotify
/// goes quiet, because IO on the output device keeps the Mac awake. If no tap can be made,
/// Spotify's own volume is set to 0 instead.
@MainActor final class SpotifyMuter: SpotifyMuting {
    /// Reports a problem worth telling the user about.
    var onProblem: ((MuteProblem) -> Void)?

    enum MuteProblem {
        /// Muting fell back to Spotify's volume slider.
        case usingVolumeFallback
        /// The tap runs but hears nothing while Spotify plays: audio recording isn't allowed.
        case permissionLikelyDenied
    }

    static let bundleIDs = [
        "com.spotify.client",
        "com.spotify.client.helper",
        "com.spotify.client.helper.Renderer",
        "com.spotify.client.helper.GPU",
        "com.spotify.client.helper.Plugin",
    ]

    private let scripting: SpotifyScripting
    private var wantMuted = false
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var tapUID: String?
    private var tappedProcesses: [AudioObjectID] = []
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var running = false
    private var runningSince = 0.0
    private var stopReading: DispatchWorkItem?
    private var spotifyOutputting = false
    private var listenersInstalled = false
    private var watchedProcesses: Set<AudioObjectID> = []
    private var outputPoll: Timer?
    private let ioQueue = DispatchQueue(label: "lipsync.mute.io", qos: .userInteractive)
    private let meter = SignalMeter()
    private var volumeMute: VolumeMute = .off
    private var tapFailed = false

    private enum VolumeMute: Equatable {
        case off
        case pending
        case on(restoreTo: Int)
    }

    private enum TapState {
        case ready
        case waitingForSpotify
        case failed
    }

    private static let savedVolumeKey = "spotifyVolumeBeforeMute"

    init(scripting: SpotifyScripting) {
        self.scripting = scripting
    }

    var isMuting: Bool { wantMuted }

    func setSpotifyMuted(_ muted: Bool) {
        guard muted != wantMuted else { return }
        wantMuted = muted
        apply()
    }

    /// Unmutes Spotify before Lipsync exits, waiting for the volume restore if one is needed.
    func releaseForQuit() {
        wantMuted = false
        pollOutput(false)
        teardown()
        if case .on(let restore) = volumeMute {
            scripting.performNow(.setVolume(restore))
            UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
        }
        volumeMute = .off
    }

    /// Spotify's volume, if a crash left it at 0 from the fallback.
    func restoreVolumeLeftByCrash() {
        guard let saved = UserDefaults.standard.object(forKey: Self.savedVolumeKey) as? Int, volumeMute == .off else { return }
        UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
        scripting.perform(.setVolume(saved))
    }

    /// Call periodically while Spotify plays music under the mute. A tap that has heard nothing
    /// at all for a while means macOS gave it silence: permission was refused.
    func checkSignal(spotifyIsPlayingMusic: Bool) {
        guard running, spotifyIsPlayingMusic, volumeMute == .off, !meter.hasEverHeardSound else { return }
        if Uptime.now() - runningSince > 8 {
            Log.warn("Spotify mute tap hears nothing; audio recording permission is probably off")
            onProblem?(.permissionLikelyDenied)
            tapFailed = true
            teardown()
            muteThroughVolume(true)
        }
    }

    private func apply() {
        installListeners()
        pollOutput(wantMuted && !tapFailed)
        if wantMuted {
            guard !tapFailed else {
                muteThroughVolume(true)
                return
            }
            switch ensureTap() {
            case .ready:
                // Built ahead, so reading starts the moment Spotify makes a sound.
                if aggregate == kAudioObjectUnknown { _ = buildAggregate() }
                updateReading()
            case .waitingForSpotify:
                // Spotify has no audio output to tap yet. It appears in the process list the
                // moment it opens one, and processesChanged() mutes it then.
                break
            case .failed:
                muteThroughVolume(true)
            }
        } else {
            teardown()
            muteThroughVolume(false)
        }
    }

    // MARK: Tap

    private func ensureTap() -> TapState {
        let processes = Self.spotifyProcesses()
        if tap != kAudioObjectUnknown {
            if #available(macOS 26.0, *) { return .ready }
            if Set(processes) == Set(tappedProcesses) { return .ready }
            teardown()
        }
        let description: CATapDescription
        if #available(macOS 26.0, *) {
            // Tapping by bundle id follows Spotify across relaunches and new helper processes.
            description = CATapDescription(stereoMixdownOfProcesses: processes)
            description.bundleIDs = Self.bundleIDs
            description.isProcessRestoreEnabled = true
        } else {
            // Spotify only appears once it has opened its audio output.
            guard !processes.isEmpty else { return .waitingForSpotify }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.name = "Lipsync mute for Spotify"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            Log.warn("Couldn't create the Spotify tap: \(status)")
            return .failed
        }
        tap = tapID
        tapUID = description.uuid.uuidString
        tappedProcesses = processes
        Log.info("Spotify muted (\(processes.count) processes tapped)")
        return .ready
    }

    /// Reads the tap while Spotify is producing sound; stops a few seconds after it goes quiet.
    private func updateReading() {
        guard tap != kAudioObjectUnknown else { return }
        if wantMuted && spotifyOutputting {
            stopReading?.cancel()
            stopReading = nil
            if aggregate == kAudioObjectUnknown || ioProc == nil, !buildAggregate() { return }
            startIO()
        } else if running, stopReading == nil {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stopReading = nil
                    if !(self.wantMuted && self.spotifyOutputting) { self.stopIO() }
                }
            }
            stopReading = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    /// An aggregate device reads the tap, clocked by the current output device.
    private func buildAggregate() -> Bool {
        guard let tapUID, let outputUID = Self.defaultOutputDeviceUID() else { return false }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lipsync",
            kAudioAggregateDeviceUIDKey: "lipsync-mute-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr else {
            Log.warn("Couldn't create the mute aggregate device: \(status)")
            return false
        }
        var procID: AudioDeviceIOProcID?
        let meter = self.meter
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
            meter.record(input)
        }
        guard status == noErr, let procID else {
            Log.warn("Couldn't create the mute IO proc: \(status)")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            return false
        }
        aggregate = aggregateID
        ioProc = procID
        return true
    }

    private func startIO() {
        guard !running, let ioProc else { return }
        let status = AudioDeviceStart(aggregate, ioProc)
        guard status == noErr else {
            Log.warn("Couldn't read the Spotify tap: \(status)")
            tapFailed = true
            teardown()
            muteThroughVolume(true)
            return
        }
        running = true
        runningSince = Uptime.now()
    }

    private func stopIO() {
        guard running, let ioProc else { return }
        AudioDeviceStop(aggregate, ioProc)
        running = false
    }

    private func destroyAggregate() {
        stopIO()
        if let ioProc { AudioDeviceDestroyIOProcID(aggregate, ioProc) }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        ioProc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
    }

    private func teardown() {
        stopReading?.cancel()
        stopReading = nil
        destroyAggregate()
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        tap = AudioObjectID(kAudioObjectUnknown)
        tapUID = nil
        tappedProcesses = []
    }

    // MARK: System changes

    private func installListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        var processList = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(system, &processList, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.processesChanged() }
        }
        var output = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(system, &output, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputDeviceChanged() }
        }
        watchSpotifyOutput()
    }

    /// Hears the moment Spotify starts or stops producing sound.
    private func watchSpotifyOutput() {
        for process in Self.spotifyProcesses() where !watchedProcesses.contains(process) {
            watchedProcesses.insert(process)
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(process, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.outputStateChanged() }
            }
        }
        outputStateChanged()
    }

    private func outputStateChanged() {
        spotifyOutputting = Self.spotifyIsOutputtingAudio()
        if wantMuted { updateReading() }
    }

    /// macOS 26 never calls the IsRunningOutput listeners, so Spotify starting and stopping is
    /// polled too. Until the tap is being read Spotify is audible, so the interval is how much
    /// of it can leak out when it starts playing.
    private func pollOutput(_ on: Bool) {
        if on, outputPoll == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Self.spotifyIsOutputtingAudio() != self.spotifyOutputting else { return }
                    self.outputStateChanged()
                }
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            outputPoll = timer
        } else if !on {
            outputPoll?.invalidate()
            outputPoll = nil
        }
    }

    private func processesChanged() {
        watchSpotifyOutput()
        guard wantMuted, !tapFailed else { return }
        if tap == kAudioObjectUnknown {
            // Spotify just opened its audio output; mute it now.
            if ensureTap() == .ready {
                muteThroughVolume(false)
                updateReading()
            }
            return
        }
        if #available(macOS 26.0, *) { return }
        if Set(Self.spotifyProcesses()) != Set(tappedProcesses) {
            teardown()
            apply()
        }
    }

    /// The tap mutes on its own; only the reader follows the output device.
    private func outputDeviceChanged() {
        guard tap != kAudioObjectUnknown else { return }
        destroyAggregate()
        guard wantMuted, spotifyOutputting else { return }
        if buildAggregate() {
            startIO()
        } else {
            Log.warn("Couldn't follow the new output device; muting Spotify with its volume as well")
            muteThroughVolume(true)
        }
    }

    // MARK: Volume fallback

    private func muteThroughVolume(_ mute: Bool) {
        if mute {
            guard volumeMute == .off, SpotifyScripting.isRunning else { return }
            volumeMute = .pending
            onProblem?(.usingVolumeFallback)
            Task { @MainActor in
                let current = await self.scripting.volume() ?? 70
                guard self.volumeMute == .pending, self.wantMuted else {
                    if self.volumeMute == .pending { self.volumeMute = .off }
                    return
                }
                let restore = current > 0 ? current : 70
                self.volumeMute = .on(restoreTo: restore)
                UserDefaults.standard.set(restore, forKey: Self.savedVolumeKey)
                self.scripting.perform(.setVolume(0))
            }
        } else {
            switch volumeMute {
            case .on(let restore):
                scripting.perform(.setVolume(restore))
                UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
            case .pending, .off:
                break
            }
            volumeMute = .off
        }
    }

    /// Brings up macOS's audio-recording prompt. Any tap does it; a global, unmuted one works
    /// even before Spotify has opened its audio, and changes nothing anyone hears.
    func requestPermission() {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Lipsync permission check"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var probeTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &probeTap) == noErr else {
            Log.warn("Couldn't create the permission-check tap")
            return
        }
        guard let outputUID = Self.defaultOutputDeviceUID() else {
            AudioHardwareDestroyProcessTap(probeTap)
            return
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lipsync check",
            kAudioAggregateDeviceUIDKey: "lipsync-check-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var probeAggregate = AudioObjectID(kAudioObjectUnknown)
        var probeProc: AudioDeviceIOProcID?
        if AudioHardwareCreateAggregateDevice(composition as CFDictionary, &probeAggregate) == noErr,
           AudioDeviceCreateIOProcIDWithBlock(&probeProc, probeAggregate, ioQueue, { _, _, _, _, _ in }) == noErr,
           let probeProc {
            AudioDeviceStart(probeAggregate, probeProc)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                AudioDeviceStop(probeAggregate, probeProc)
                AudioDeviceDestroyIOProcID(probeAggregate, probeProc)
                AudioHardwareDestroyAggregateDevice(probeAggregate)
                AudioHardwareDestroyProcessTap(probeTap)
            }
        } else {
            if probeAggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(probeAggregate) }
            AudioHardwareDestroyProcessTap(probeTap)
        }
    }

    // MARK: Core Audio helpers

    static func spotifyProcesses() -> [AudioObjectID] {
        processObjects().filter { process in
            guard let id = bundleID(of: process) else { return false }
            return id.hasPrefix("com.spotify.client")
        }
    }

    /// Whether Spotify's audio engine is running on this Mac. Spotify reporting "playing"
    /// without it means it's playing on another device through Spotify Connect.
    static func spotifyIsOutputtingAudio() -> Bool {
        spotifyProcesses().contains { readUInt32(kAudioProcessPropertyIsRunningOutput, of: $0) == 1 }
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        readString(kAudioProcessPropertyBundleID, of: process)
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return readString(kAudioDevicePropertyDeviceUID, of: device)
    }

    private static func readString(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func readUInt32(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// Notes, from the audio thread, whether the tap has ever carried sound.
final class SignalMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false

    var hasEverHeardSound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }

    func record(_ list: UnsafePointer<AudioBufferList>) {
        if hasEverHeardSound { return }
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list)) {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            for i in stride(from: 0, to: count, by: 4) where abs(samples[i]) > 0.0001 {
                lock.lock()
                heard = true
                lock.unlock()
                return
            }
        }
    }
}
