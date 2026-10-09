import Testing
@testable import LipsyncCore

private func catalog(_ tracks: [SpotifyTrack], deltas: [Double] = [], missing: Set<Int> = []) -> [String: Resolution] {
    var out: [String: Resolution] = [:]
    for (i, track) in tracks.enumerated() where !missing.contains(i) {
        out[track.uri] = .matched(appleVersion(of: track, durationDelta: i < deltas.count ? deltas[i] : 0))
    }
    return out
}

private func apple(_ n: Int) -> Simulation.Sound { .apple("a-t\(n)") }

@MainActor
struct SyncEngineTests {
    @Test func playingThroughAPlaylistIsGaplessAndNeverSkipsSpotify() {
        let tracks = (0..<4).map { makeTrack($0) }
        let deltas = [0.3, -0.4, 1.2, -2.0]
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, deltas: deltas))
        sim.schedule(after: 1) { sim.spotify.userPlay(index: 0) }
        sim.run(until: 130)

        let first = try! #require(sim.firstTime(of: apple(0)))
        #expect(first < 1 + 0.25 + 0.4 + 0.05, "first song starts after one lookup and one start")
        let appleTotal = tracks.enumerated().reduce(0.0) { $0 + $1.element.duration + deltas[$1.offset] }
        #expect(sim.longestSilence(from: first, to: first + appleTotal - 0.1) < 0.02)
        #expect(sim.soundSequence() == [apple(0), apple(1), apple(2), apple(3)])
        #expect(sim.spotify.engineNexts == 0, "Spotify only ever finishes tracks on its own")
        #expect(sim.apple.starts.count == 1, "later songs come from the Apple queue, not fresh starts")
        for n in 0..<4 {
            #expect(abs(sim.seconds(of: apple(n)) - (tracks[n].duration + deltas[n])) < 0.7, "song \(n) plays in full")
        }
    }

    @Test func clickingAFarAwaySongSilencesTheOldOneAndStartsTheNewOneFromTheTop() {
        let tracks = (0..<12).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 30)
        sim.spotify.userPlay(index: 11)
        sim.run(until: 40)

        #expect(sim.sound(at: 30.05) == .silence, "the old song stops at once")
        let start = try! #require(sim.firstTime(of: apple(11), after: 30))
        #expect(start - 30 < 0.25 + 0.4 + 0.05)
        #expect(sim.apple.starts.last?.position == 0)
        #expect(sim.spotify.engineNexts == 0)
    }

    @Test func clickingAQueuedSongNeedsNoLookup() {
        let tracks = (0..<12).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 30)
        sim.spotify.userPlay(index: 5)
        sim.run(until: 35)
        let start = try! #require(sim.firstTime(of: apple(5), after: 30))
        #expect(start - 30 < 0.4 + 0.05)
    }

    @Test func nextInSpotifySkipsToTheBufferedSong() {
        let tracks = (0..<4).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.spotify.userNext()
        sim.run(until: 25)
        #expect(sim.apple.skips == 1)
        #expect(sim.apple.starts.count == 1)
        #expect(sim.sound(at: 20.05) == apple(1))
    }

    @Test func pauseAndResumeInSpotifyPauseAndResumeAppleMusic() {
        let tracks = (0..<2).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.spotify.userPause()
        sim.run(until: 20.05)
        #expect(sim.sound(at: 20.05) == .silence)
        sim.run(until: 30)
        #expect(sim.apple.status == .paused)
        sim.spotify.userResume()
        sim.run(until: 30.1)
        #expect(sim.sound(at: 30.1) == apple(0))
        sim.run(until: 40)
        #expect(sim.spotify.engineCommands.filter { $0 == "pause" || $0 == "play" }.isEmpty, "nothing echoes back to Spotify")
    }

    @Test func mediaKeysOnAppleMusicAreMirroredToSpotify() {
        let tracks = (0..<3).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)

        sim.apple.userPause()
        sim.run(until: 21)
        #expect(!sim.spotify.isPlaying)
        #expect(sim.apple.status == .paused)

        sim.apple.userPlay()
        sim.run(until: 22)
        #expect(sim.spotify.isPlaying)
        #expect(sim.apple.status == .playing)

        sim.apple.userNext()
        sim.run(until: 24)
        #expect(sim.sound(at: 22.05) == apple(1), "Apple skips to its buffered next song at once")
        #expect(sim.spotify.engineNexts == 1)
        #expect(sim.spotify.index == 1)
        #expect(sim.apple.starts.count == 1)
    }

    @Test func scrubbingInSpotifySeeksAppleMusic() {
        let tracks = (0..<2).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.spotify.userSeek(to: 100)
        sim.run(until: 22)
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.3)
        #expect(sim.apple.position > 100)
    }

    @Test func scrubbingOnAppleMusicSeeksSpotify() {
        let tracks = (0..<2).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.apple.userSeek(to: 120)
        sim.run(until: 22)
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.3)
        #expect(sim.apple.position > 120 && sim.apple.position < 123)
    }

    @Test func songsMissingFromAppleMusicPlayThroughSpotifyWithoutGaps() {
        let tracks = (0..<3).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, missing: [1]))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 95)
        #expect(sim.soundSequence() == [apple(0), .spotify(tracks[1].uri), apple(2)])
        let first = try! #require(sim.firstTime(of: apple(0)))
        #expect(sim.longestSilence(from: first, to: 89) < 0.1)
        #expect(sim.delegate.fallbacks.map(\.reason) == [.notOnAppleMusic])
    }

    @Test func podcastsPlayThroughSpotify() {
        let tracks = [makeTrack(0), makeTrack(1, kind: "episode"), makeTrack(2)]
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, missing: [1]))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 95)
        #expect(sim.soundSequence() == [apple(0), .spotify(tracks[1].uri), apple(2)])
    }

    @Test func aLongerAppleVersionPlaysToTheEnd() {
        let tracks = (0..<3).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, deltas: [5, 0, 0]))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 100)
        #expect(sim.soundSequence() == [apple(0), apple(1), apple(2)])
        #expect(abs(sim.seconds(of: apple(0)) - 35) < 0.7)
        let first = try! #require(sim.firstTime(of: apple(0)))
        #expect(sim.longestSilence(from: first, to: first + 94) < 0.02)
        #expect(sim.spotify.engineNexts == 0)
    }

    @Test func aShorterAppleVersionHurriesSpotifyToItsEndInsteadOfSkipping() {
        let tracks = (0..<3).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, deltas: [-5, 0, 0]))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 90)
        #expect(sim.soundSequence() == [apple(0), apple(1), apple(2)])
        #expect(sim.spotify.engineNexts == 0)
        #expect(sim.spotify.engineSeeks.contains { abs($0 - 29.6) < 0.01 })
        let first = try! #require(sim.firstTime(of: apple(0)))
        #expect(sim.longestSilence(from: first, to: first + 84) < 0.02)
    }

    @Test func spotifyBufferingDoesNotDisturbAppleMusic() {
        let tracks = (0..<2).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        let seeksBefore = sim.spotify.engineSeeks.count
        sim.spotify.stallRemaining = 2
        sim.run(until: 30)
        #expect(sim.longestSilence(from: 1, to: 30) < 0.02, "Apple keeps playing")
        #expect(sim.spotify.engineSeeks.count > seeksBefore, "Spotify is pulled back into line")
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.3)
    }

    @Test func slowLookupsFallBackToSpotify() {
        let tracks = (0..<2).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.resolver.latency = 5
        sim.spotify.userPlay(index: 0)
        sim.run(until: 10)
        #expect(sim.sound(at: 4) == .spotify(tracks[0].uri))
        #expect(sim.sound(at: 9) == .spotify(tracks[0].uri), "no switch in the middle of the song")
        #expect(sim.delegate.fallbacks.map(\.reason) == [.appleTimedOut])
    }

    @Test func applePlaybackFailuresFallBackToSpotify() {
        let tracks = (0..<2).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.apple.failing = ["a-t0"]
        sim.spotify.userPlay(index: 0)
        sim.run(until: 5)
        #expect(sim.sound(at: 5) == .spotify(tracks[0].uri))
        #expect(sim.resolver.unplayable.contains(tracks[0].uri))
    }

    @Test func editsToSpotifysQueueReachAppleMusicBeforeTheTransition() {
        let tracks = (0..<6).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 10)
        // "Play next" on track 4.
        sim.spotify.tracks.insert(tracks[4], at: 1)
        sim.run(until: 70)
        #expect(sim.soundSequence() == [apple(0), apple(4), apple(1)])
        let first = try! #require(sim.firstTime(of: apple(0)))
        #expect(sim.longestSilence(from: first, to: 69) < 0.02)
    }

    @Test func withoutTheWebAPITransitionsStillWork() {
        let tracks = (0..<3).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.webAPIEnabled = false
        sim.spotify.userPlay(index: 0)
        sim.run(until: 95)
        #expect(sim.soundSequence() == [apple(0), apple(1), apple(2)])
        let first = try! #require(sim.firstTime(of: apple(0)))
        #expect(sim.longestSilence(from: first, to: 88) < 0.8)
    }

    @Test func joiningASongInProgressStartsAtSpotifysPosition() {
        let tracks = (0..<2).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0, at: 60)
        sim.run(until: 5)
        #expect(abs((sim.apple.starts.first?.position ?? 0) - 60) < 0.1)
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.7)
    }

    @Test func playbackOnAnotherDeviceSilencesThisMac() {
        let tracks = (0..<2).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 10)
        sim.engine.setSpotifyRemote(true)
        sim.run(until: 12)
        #expect(sim.apple.status != .playing)
        #expect(!sim.muter.muted)
        sim.engine.setSpotifyRemote(false)
        sim.run(until: 15)
        #expect(sim.apple.status == .playing)
        #expect(sim.muter.muted)
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.7)
    }

    @Test func turningLipsyncOffHandsAudioBackToSpotify() {
        let tracks = (0..<2).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 10)
        sim.engine.setEnabled(false)
        sim.run(until: 11)
        #expect(sim.sound(at: 11) == .spotify(tracks[0].uri))
        sim.engine.setEnabled(true)
        sim.run(until: 14)
        #expect(sim.sound(at: 14) == apple(0))
    }
}

@MainActor
struct SyncEngineEdgeCaseTests {
    @Test func rapidSkippingEndsOnTheRightSong() {
        let tracks = (0..<12).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 10)
        for i in 1...5 {
            sim.spotify.userNext()
            sim.run(until: 10 + Double(i) * 0.3)
        }
        sim.run(until: 16)
        #expect(sim.sound(at: 16) == apple(5))
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.7)
        #expect(sim.spotify.engineNexts == 0)
    }

    @Test func aSecondClickWhileTheFirstIsLoadingWins() {
        let tracks = (0..<12).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 10)
        sim.spotify.userPlay(index: 10)
        sim.run(until: 10.1)
        sim.spotify.userPlay(index: 11)
        sim.run(until: 15)
        #expect(sim.soundSequence(from: 10.02) == [apple(11)], "the first click is never heard")
        #expect(sim.sound(at: 15) == apple(11))
    }

    @Test func pausingWhileLoadingStartsPausedAndResumesInStep() {
        let tracks = (0..<12).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 10)
        sim.spotify.userPlay(index: 11)
        sim.run(until: 10.1)
        sim.spotify.userPause()
        sim.run(until: 14)
        #expect(sim.soundSequence(from: 10.01) == [])
        sim.spotify.userResume()
        sim.run(until: 16)
        #expect(sim.sound(at: 16) == apple(11))
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.7)
    }

    @Test func aMuchLongerAppleVersionGivesWayToSpotify() {
        let tracks = (0..<3).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, deltas: [14, 0, 0]))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 100)
        #expect(sim.soundSequence() == [apple(0), apple(1), apple(2)])
        #expect(sim.spotify.engineNexts == 0)
    }

    @Test func pollsAloneAreEnoughWhenNotificationsGoMissing() {
        let tracks = (0..<3).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.notificationsEnabled = false
        sim.spotify.userPlay(index: 0)
        sim.run(until: 95)
        // Before the first reading Lipsync can't know to mute Spotify; that only happens at launch.
        #expect(sim.soundSequence(from: 1) == [apple(0), apple(1), apple(2)])
        #expect(sim.spotify.engineNexts == 0)
    }

    @Test func aWrongQueuePredictionIsCorrectedQuickly() {
        let tracks = (0..<6).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 25)
        // Spotify changes its mind about what's next after the last queue read.
        sim.webAPIEnabled = false
        sim.spotify.tracks.swapAt(1, 3)
        sim.run(until: 40)
        #expect(sim.sound(at: 40) == apple(3))
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.7)
    }

    @Test func appleSideNextWithNothingQueuedSkipsSpotify() {
        let tracks = (0..<3).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.webAPIEnabled = false
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.apple.userNext()
        sim.run(until: 24)
        #expect(sim.spotify.index == 1)
        #expect(sim.sound(at: 24) == apple(1))
    }

    @Test func appleSideNextIntoAutoPlaySkipsSpotify() {
        let tracks = (0..<3).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.webAPIEnabled = false
        sim.apple.autoplay = true
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.apple.userNext()
        sim.run(until: 24)
        #expect(sim.spotify.index == 1)
        #expect(sim.sound(at: 24) == apple(1))
        #expect(sim.seconds(of: .apple("autoplay-1")) < 0.1, "Music's own song is silenced at once")
    }

    @Test func aShorterAppleVersionEndingInAutoPlayIsSilenced() {
        let tracks = (0..<2).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, deltas: [-5, 0]))
        sim.webAPIEnabled = false
        sim.apple.autoplay = true
        sim.spotify.userPlay(index: 0)
        sim.run(until: 40)
        #expect(sim.soundSequence().filter { $0 != .apple("autoplay-1") } == [apple(0), apple(1)])
        #expect(sim.seconds(of: .apple("autoplay-1")) < 0.1, "Music's own song is silenced at once")
        #expect(sim.spotify.engineNexts == 0)
    }

    @Test func appleSideRestartMovesSpotifyBackToo() {
        let tracks = (0..<3).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 40)
        sim.apple.userSeek(to: 0)
        sim.run(until: 42)
        #expect(sim.spotify.position < 3)
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.5)
    }

    @Test func driftingClocksAreCorrectedOnSpotifyOnly() {
        let tracks = (0..<2).map { makeTrack($0, duration: 600) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.rate = 1.004
        sim.spotify.userPlay(index: 0)
        sim.run(until: 590)
        let first = try! #require(sim.firstTime(of: apple(0)))
        #expect(sim.longestSilence(from: first, to: 590) < 0.02, "Apple is never interrupted")
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.8)
        #expect(sim.spotify.engineSeeks.count >= 2)
    }

    @Test func adsPlayThroughSpotify() {
        let tracks = [makeTrack(0), makeTrack(1, duration: 15, kind: "ad"), makeTrack(2)]
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, missing: [1]))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 80)
        #expect(sim.soundSequence() == [apple(0), .spotify(tracks[1].uri), apple(2)])
    }

    @Test func pausingAtATrackBoundaryLeavesBothPaused() {
        let tracks = (0..<3).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 30.02)
        sim.spotify.userPause()
        sim.run(until: 35)
        #expect(sim.apple.status != .playing)
        #expect(!sim.spotify.isPlaying)
        sim.spotify.userResume()
        sim.run(until: 40)
        #expect(sim.sound(at: 40) == apple(1))
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.7)
    }
}

@MainActor
struct SlowAppleStartTests {
    @Test func aSlowAppleStartNeverPausesOrSkipsSpotify() {
        let tracks = (0..<12).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.apple.startLatency = 2.5
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.spotify.userPlay(index: 11)
        sim.run(until: 30)
        #expect(!sim.spotify.engineCommands.contains("pause"))
        #expect(sim.spotify.engineNexts == 0)
        #expect(sim.spotify.isPlaying)
        #expect(sim.sound(at: 30) == apple(11))
        #expect(abs(sim.apple.position - sim.spotify.position) < 0.7)
    }
}

/// Scenarios from the code review: each once played the wrong song, left silence, or fought
/// the user.
@MainActor
struct ReviewRegressionTests {
    @Test func aStaleNextPredictionNeverSkipsSpotifysSong() {
        for delta in [0.5, -0.5] {
            let tracks = (0..<5).map { makeTrack($0) }
            let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, deltas: [delta, 0, 0, 0, 0]))
            sim.spotify.userPlay(index: 0)
            sim.run(until: 26)
            // Spotify changes its mind about what's next after the last queue read.
            sim.webAPIEnabled = false
            sim.spotify.tracks.swapAt(1, 2)
            sim.run(until: 40)
            #expect(sim.spotify.index == 1 && sim.spotify.current?.uri == tracks[2].uri)
            #expect(sim.sound(at: 40) == apple(2), "Apple plays what Spotify plays (delta \(delta))")
            #expect(sim.spotify.engineNexts == 0)
            #expect(abs(sim.apple.position - sim.spotify.position) < 0.7)
        }
    }

    @Test func clickingASongInTheLastSecondsPlaysIt() {
        let tracks = (0..<8).map { makeTrack($0) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 28.9)
        sim.spotify.userPlay(index: 5)
        sim.run(until: 35)
        #expect(sim.spotify.current?.uri == tracks[5].uri)
        #expect(sim.sound(at: 35) == apple(5))
        #expect(sim.spotify.engineNexts == 0)
    }

    @Test func aFailedQueueEditDoesNotLeaveSilence() {
        let tracks = (0..<4).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.apple.setUpcomingFails = true
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.spotify.userNext()
        sim.run(until: 26)
        #expect(sim.sound(at: 26) == apple(1))
        #expect(sim.longestSilence(from: 20, to: 26) < 1.5)
    }

    @Test func aSkipThatSilentlyFailsIsCorrected() {
        let tracks = (0..<4).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        sim.apple.skipFailsSilently = true
        sim.spotify.userNext()
        sim.run(until: 26)
        #expect(sim.sound(at: 26) == apple(1))
        #expect(sim.spotify.current?.uri == tracks[1].uri, "Spotify's song is not skipped")
        #expect(sim.seconds(of: apple(0)) < 23, "the old song stops within a few seconds")
    }

    @Test func aPollThatBeganBeforeAPauseDoesNotUndoIt() {
        let tracks = (0..<2).map { makeTrack($0, duration: 200) }
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks))
        sim.spotify.userPlay(index: 0)
        sim.run(until: 20)
        let pollStart = sim.clock.now
        sim.run(until: 20.1)
        sim.spotify.userPause()
        sim.run(until: 20.2)
        // The poll started before the pause but its answer lands after.
        sim.engine.spotifyObserved(SpotifyObservation(track: tracks[0], isPlaying: true, position: 20.05, time: 20.15,
                                                      isAuthoritative: false, issuedAt: pollStart))
        sim.engine.spotifyObserved(SpotifyObservation(track: tracks[0], isPlaying: true, position: 20.05, time: 20.16,
                                                      isAuthoritative: false, issuedAt: pollStart))
        sim.run(until: 21)
        #expect(sim.apple.status == .paused)
        #expect(sim.longestSilence(from: 20.2, to: 21) > 0.7, "Apple never resumes")
    }

    @Test func appleStartedByAMediaKeyDuringASpotifyOnlySongIsPaused() {
        let tracks = [makeTrack(0), makeTrack(1, kind: "episode"), makeTrack(2)]
        let sim = Simulation(tracks: tracks, appleVersions: catalog(tracks, missing: [1]))
        sim.spotify.userPlay(index: 1)
        sim.run(until: 15)
        // The prepared next song sits paused in Apple Music; a media key resumes it.
        if sim.apple.currentSong != nil {
            sim.apple.userPlay()
        }
        sim.run(until: 16)
        #expect(sim.apple.status != .playing)
        #expect(sim.sound(at: 16) == .spotify(tracks[1].uri))
    }
}
