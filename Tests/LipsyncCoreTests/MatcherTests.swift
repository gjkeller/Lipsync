import Testing
@testable import LipsyncCore

private func spotify(_ name: String, artists: [String] = ["Queen"], album: String = "A Night at the Opera", duration: Double = 354, explicit: Bool? = nil) -> SpotifyTrack {
    SpotifyTrack(uri: "spotify:track:x", name: name, artists: artists, album: album, durationMs: Int(duration * 1000), isExplicit: explicit)
}

private func apple(_ title: String, artist: String = "Queen", album: String? = "A Night at the Opera", duration: Double = 354, id: String = "1", explicit: Bool? = nil) -> AppleTrack {
    AppleTrack(id: id, title: title, artist: artist, album: album, duration: duration, isExplicit: explicit)
}

struct MatcherTests {
    @Test func spotifyAndAppleAnnotationStylesNormalizeTheSame() {
        #expect(Matcher.normalizeTitle("Bohemian Rhapsody - Remastered 2011") == "bohemian rhapsody")
        #expect(Matcher.normalizeTitle("Bohemian Rhapsody (Remastered 2011)") == "bohemian rhapsody")
        #expect(Matcher.normalizeTitle("Señorita [feat. Someone]") == "senorita")
        #expect(Matcher.normalizeTitle("Rock 'n' Roll Pt. 2") == "rock and roll part 2")
    }

    @Test func liveInTheSongNameIsNotALiveRecording() {
        #expect(Matcher.versionTags("Live Forever - Remastered").major.isEmpty)
        #expect(Matcher.versionTags("Live and Let Die").major.isEmpty)
        #expect(Matcher.versionTags("Bohemian Rhapsody - Live at Wembley '86").major == ["live"])
        #expect(Matcher.versionTags("Song (Acoustic)").major == ["acoustic"])
    }

    @Test func sameISRCPicksTheMatchingRelease() {
        let track = spotify("Bohemian Rhapsody - Remastered 2011")
        let candidates = [
            apple("Bohemian Rhapsody", album: "Greatest Hits", duration: 355, id: "hits"),
            apple("Bohemian Rhapsody", album: "A Night at the Opera (2011 Remaster)", duration: 354.5, id: "opera"),
        ]
        #expect(Matcher.best(for: track, among: candidates, sameISRC: true)?.id == "opera")
    }

    @Test func sameISRCStillRefusesAVeryDifferentLength() {
        let track = spotify("Bohemian Rhapsody")
        #expect(Matcher.best(for: track, among: [apple("Bohemian Rhapsody", duration: 300)], sameISRC: true) == nil)
    }

    @Test func searchMatchesAcrossAnnotationStyles() {
        let track = spotify("Bohemian Rhapsody - Remastered 2011")
        let candidates = [
            apple("Bohemian Rhapsody (Live Aid)", duration: 360, id: "live"),
            apple("Bohemian Rhapsody", duration: 354.2, id: "studio"),
        ]
        #expect(Matcher.best(for: track, among: candidates, sameISRC: false)?.id == "studio")
    }

    @Test func searchRefusesADifferentVersion() {
        let track = spotify("Bohemian Rhapsody")
        #expect(Matcher.best(for: track, among: [apple("Bohemian Rhapsody (Live at Wembley)", duration: 355)], sameISRC: false) == nil)
        let remix = spotify("Song - Kygo Remix", artists: ["Artist"], album: "Single", duration: 200)
        #expect(Matcher.best(for: remix, among: [apple("Song (Tiësto Remix)", artist: "Artist", album: "Single", duration: 200)], sameISRC: false) == nil)
        #expect(Matcher.best(for: remix, among: [apple("Song (Kygo Remix)", artist: "Artist", album: "Single", duration: 201)], sameISRC: false) != nil)
    }

    @Test func searchRefusesTheWrongArtistOrLength() {
        let track = spotify("Hello", artists: ["Adele"], album: "25", duration: 295)
        #expect(Matcher.best(for: track, among: [apple("Hello", artist: "Lionel Richie", album: "Can't Slow Down", duration: 247)], sameISRC: false) == nil)
        #expect(Matcher.best(for: track, among: [apple("Hello", artist: "Adele", album: "25", duration: 320)], sameISRC: false) == nil)
        #expect(Matcher.best(for: track, among: [apple("Hello", artist: "Adele", album: "25", duration: 295.4)], sameISRC: false) != nil)
    }

    @Test func featuredArtistsDontBlockAMatch() {
        let track = spotify("Rockstar (feat. 21 Savage)", artists: ["Post Malone", "21 Savage"], album: "beerbongs & bentleys", duration: 218)
        let candidate = apple("rockstar (feat. 21 Savage)", artist: "Post Malone", album: "beerbongs & bentleys", duration: 218.1)
        #expect(Matcher.best(for: track, among: [candidate], sameISRC: false) != nil)
    }

    @Test func explicitnessBreaksTies() {
        let track = spotify("Song", artists: ["Artist"], album: "Album", duration: 200, explicit: true)
        let candidates = [
            apple("Song", artist: "Artist", album: "Album", duration: 200, id: "clean", explicit: false),
            apple("Song", artist: "Artist", album: "Album", duration: 200, id: "explicit", explicit: true),
        ]
        #expect(Matcher.best(for: track, among: candidates, sameISRC: true)?.id == "explicit")
        #expect(Matcher.best(for: track, among: candidates, sameISRC: false)?.id == "explicit")
    }
}
