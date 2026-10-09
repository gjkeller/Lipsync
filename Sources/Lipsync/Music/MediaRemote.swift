import Foundation

/// The parts of Apple's private MediaRemote framework that tell the Music app what to play.
///
/// These are the requests Siri and Handoff use to start Apple Music songs on a Mac: replace
/// Music's queue with these store IDs, insert these store IDs into Up Next, clear Up Next.
/// mediaremoted normally redirects commands from apps without Apple's
/// `com.apple.mediaremote.send-commands` entitlement to whichever app is now playing, but it
/// exempts commands addressed to the system music app. So they reach Music even while Spotify
/// is the now-playing app.
///
/// The signatures below were read off the framework's disassembly (macOS 26/27) and are loaded
/// with dlsym, so a missing symbol makes `isAvailable` false rather than crashing.
final class MediaRemote: @unchecked Sendable {
    static let shared = MediaRemote()

    enum Command: UInt32 {
        case play = 0
        case pause = 1
        case stop = 3
        case nextTrack = 4
        case seekToPlaybackPosition = 24
        case clearUpNextQueue = 144
    }

    /// MediaRemote calls these head and tail.
    enum InsertPosition: Int32 {
        case next = 0
        case last = 1
    }

    static let musicBundleID = "com.apple.Music"
    private static let storeTracklistQueueType: Int32 = 3

    private typealias QueueRef = UnsafeMutableRawPointer
    private typealias Done = @convention(block) (UInt32) -> Void
    private typealias CommandDone = @convention(block) (UInt32, CFArray?) -> Void
    private typealias CreateQueue = @convention(c) (CFAllocator?, Int32) -> QueueRef?
    private typealias SetStoreIDs = @convention(c) (QueueRef, CFArray) -> Void
    private typealias SetFlag = @convention(c) (QueueRef, Bool) -> Void
    private typealias DestroyQueue = @convention(c) (QueueRef) -> Void
    private typealias SetSystemQueue = @convention(c) (QueueRef, DispatchQueue?, Done?) -> Void
    private typealias InsertSystemQueue = @convention(c) (QueueRef, Int32, UnsafeRawPointer?, DispatchQueue?, Done?) -> Void
    private typealias SendCommandToApp = @convention(c) (UInt32, CFDictionary?, UnsafeRawPointer?, CFString?, UInt32, DispatchQueue?, CommandDone?) -> Bool

    private let createQueue: CreateQueue?
    private let setStoreIDs: SetStoreIDs?
    private let setImmediate: SetFlag?
    private let destroyQueue: DestroyQueue?
    private let setSystemQueue: SetSystemQueue?
    private let insertSystemQueue: InsertSystemQueue?
    private let sendCommandToApp: SendCommandToApp?
    private let playbackPositionKey: CFString?

    let isAvailable: Bool

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        createQueue = symbol("MRSystemAppPlaybackQueueCreate", as: CreateQueue.self)
        setStoreIDs = symbol("MRSystemAppPlaybackQueueSetTracklistStoreIDs", as: SetStoreIDs.self)
        setImmediate = symbol("MRSystemAppPlaybackQueueSetIsRequestingImmediatePlayback", as: SetFlag.self)
        destroyQueue = symbol("MRSystemAppPlaybackQueueDestroy", as: DestroyQueue.self)
        setSystemQueue = symbol("MRMediaRemoteSetSystemAppPlaybackQueue", as: SetSystemQueue.self)
        insertSystemQueue = symbol("MRMediaRemoteInsertSystemAppPlaybackQueue", as: InsertSystemQueue.self)
        sendCommandToApp = symbol("MRMediaRemoteSendCommandToApp", as: SendCommandToApp.self)
        if let handle, let key = dlsym(handle, "kMRMediaRemoteOptionPlaybackPosition") {
            playbackPositionKey = key.assumingMemoryBound(to: CFString.self).pointee
        } else {
            playbackPositionKey = nil
        }
        isAvailable = createQueue != nil && setStoreIDs != nil && setImmediate != nil && destroyQueue != nil
            && setSystemQueue != nil && insertSystemQueue != nil && sendCommandToApp != nil
        if !isAvailable { Log.warn("MediaRemote's playback queue functions are missing on this macOS") }
    }

    /// Replaces Music's queue with these Apple Music songs, playing the first now or holding it
    /// paused.
    func setQueue(storeIDs: [String], playNow: Bool) async -> Bool {
        guard isAvailable, let setSystemQueue, let queue = makeQueue(storeIDs: storeIDs, playNow: playNow) else { return false }
        return await completion { done in
            setSystemQueue(queue, .main) { [self] failed in
                destroyQueue?(queue)
                done(failed == 0)
            }
        }
    }

    /// Inserts songs into Music's Up Next.
    func insert(storeIDs: [String], at position: InsertPosition) async -> Bool {
        guard isAvailable, !storeIDs.isEmpty, let insertSystemQueue,
              let queue = makeQueue(storeIDs: storeIDs, playNow: false) else { return false }
        return await completion { done in
            insertSystemQueue(queue, position.rawValue, nil, .main) { [self] failed in
                destroyQueue?(queue)
                done(failed == 0)
            }
        }
    }

    /// Sends a transport command to Music, whether or not it is the now-playing app.
    @discardableResult
    func send(_ command: Command, position: Double? = nil) async -> Bool {
        guard isAvailable, let sendCommandToApp else { return false }
        var options: [String: Any] = [:]
        if let position, let key = playbackPositionKey { options[key as String] = position }
        let dictionary = options.isEmpty ? nil : options as CFDictionary
        return await completion { done in
            let sent = sendCommandToApp(command.rawValue, dictionary, nil, Self.musicBundleID as CFString, 0, .main) { error, _ in
                done(error == 0)
            }
            if !sent { done(false) }
        }
    }

    /// Waits for a MediaRemote reply, giving up after a few seconds: a reply that never comes
    /// must not stall Lipsync.
    private func completion(_ start: (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            start { once.resume($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if once.resume(false) { Log.warn("MediaRemote didn't answer within 5s") }
            }
        }
    }

    private func makeQueue(storeIDs: [String], playNow: Bool) -> QueueRef? {
        guard let queue = createQueue?(kCFAllocatorDefault, Self.storeTracklistQueueType) else { return nil }
        setStoreIDs?(queue, storeIDs as CFArray)
        setImmediate?(queue, playNow)
        return queue
    }
}

/// Resumes a continuation exactly once.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ value: Bool) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}
