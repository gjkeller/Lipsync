import Foundation

/// Decides which Apple Music song is the same recording as a Spotify track.
///
/// An ISRC match is the strong signal: the same ISRC is the same recording, and the only
/// question left is which release of it (album vs. single vs. compilation, clean vs. explicit).
/// Without an ISRC we fall back to title, artist and duration, and refuse anything that looks
/// like a different version (live, remix, acoustic...). Playing the wrong version is worse than
/// letting Spotify play the track.
public enum Matcher {
    /// Version markers that make two recordings different songs to a listener.
    static let majorVersionTags: [(tag: String, patterns: [String])] = [
        ("live", ["live"]),
        ("remix", ["remix", "rmx"]),
        ("acoustic", ["acoustic", "unplugged"]),
        ("instrumental", ["instrumental"]),
        ("acapella", ["acapella", "a cappella", "a capella"]),
        ("demo", ["demo"]),
        ("karaoke", ["karaoke"]),
        ("sped up", ["sped up", "speed up"]),
        ("slowed", ["slowed"]),
        ("cover", ["cover"]),
        ("orchestral", ["orchestral", "symphonic"]),
        ("extended", ["extended"]),
    ]

    /// Markers that change the cut but not the song. They count against a match, gently.
    static let minorVersionTags: [(tag: String, patterns: [String])] = [
        ("edit", ["radio edit", "single edit", "edit"]),
        ("mono", ["mono"]),
    ]

    // MARK: Normalization

    /// Lowercased, diacritics folded, annotations stripped, punctuation collapsed.
    public static func normalizeTitle(_ title: String) -> String {
        let (core, _) = splitAnnotations(title)
        return canonical(core)
    }

    /// Version tags found anywhere in the title, including its annotations.
    public static func versionTags(_ title: String) -> (major: Set<String>, minor: Set<String>) {
        // Pad with spaces so whole-word checks also work at the ends.
        let text = " " + canonical(title) + " "
        var major = Set<String>()
        var minor = Set<String>()
        for (tag, patterns) in majorVersionTags where patterns.contains(where: { text.contains(" \($0) ") }) {
            major.insert(tag)
        }
        for (tag, patterns) in minorVersionTags where patterns.contains(where: { text.contains(" \($0) ") }) {
            minor.insert(tag)
        }
        // "Live" in a title proper ("Live Forever", "Live and Let Die") is the song's name,
        // not a live recording. Only count it when it sits in an annotation.
        let (core, annotations) = splitAnnotations(title)
        if major.contains("live") {
            let coreText = " " + canonical(core) + " "
            let annotationText = " " + annotations.map(canonical).joined(separator: " ") + " "
            if coreText.contains(" live ") && !annotationText.contains(" live ") {
                major.remove("live")
            }
        }
        return (major, minor)
    }

    /// Words that only say which kind of version an annotation names.
    static let qualifierFiller: Set<String> = [
        "live", "remix", "rmx", "mix", "acoustic", "unplugged", "instrumental", "acapella", "a",
        "cappella", "capella", "demo", "karaoke", "sped", "speed", "up", "slowed", "cover",
        "orchestral", "symphonic", "extended", "version", "edit", "at", "from", "the", "in", "on",
    ]

    /// What distinguishes a version beyond its kind: the remixer, the venue. "Kygo Remix"
    /// gives "kygo", so two different remixes of one song don't match each other.
    static func versionQualifier(_ title: String) -> String {
        var words: [String] = []
        for annotation in splitAnnotations(title).annotations.map(canonical) where hasMajorTag(annotation) {
            words += annotation.split(separator: " ").map(String.init).filter { !qualifierFiller.contains($0) }
        }
        return words.joined(separator: " ")
    }

    private static func hasMajorTag(_ canonicalText: String) -> Bool {
        let padded = " " + canonicalText + " "
        for (_, patterns) in majorVersionTags {
            for pattern in patterns where padded.contains(" " + pattern + " ") {
                return true
            }
        }
        return false
    }

    public static func normalizeArtist(_ artist: String) -> String {
        canonical(artist)
    }

    /// Splits "Song (Remastered 2011) [feat. X]" and "Song - Live at Wembley" into the core
    /// title and its annotations.
    public static func splitAnnotations(_ title: String) -> (core: String, annotations: [String]) {
        var annotations: [String] = []
        var core = ""
        var depth = 0
        var current = ""
        for ch in title {
            if ch == "(" || ch == "[" {
                if depth == 0 { current = "" } else { current.append(ch) }
                depth += 1
            } else if (ch == ")" || ch == "]") && depth > 0 {
                depth -= 1
                if depth == 0 { annotations.append(current) } else { current.append(ch) }
            } else if depth > 0 {
                current.append(ch)
            } else {
                core.append(ch)
            }
        }
        if depth > 0 { annotations.append(current) }
        // Spotify writes "Song - Remastered 2011"; Apple writes "Song (Remastered 2011)".
        for separator in [" - ", " – ", " — "] {
            if let range = core.range(of: separator) {
                annotations.append(String(core[range.upperBound...]))
                core = String(core[..<range.lowerBound])
                break
            }
        }
        return (core, annotations)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "&", with: " and ")
    }

    static func canonical(_ s: String) -> String {
        let folded = fold(s)
        var out = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == "'" {
                continue
            } else {
                out.append(" ")
            }
        }
        let words = out.split(separator: " ").map { word -> String in
            switch word {
            case "pt": return "part"
            case "vol": return "volume"
            case "n": return "and"
            default: return String(word)
            }
        }
        return words.joined(separator: " ")
    }

    // MARK: Similarity

    /// 0...1. The better of token overlap and character-bigram overlap, so both reordered
    /// words and small spelling differences score well.
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return a.isEmpty ? 0 : 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let ta = Set(a.split(separator: " ")), tb = Set(b.split(separator: " "))
        let jaccard = Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        return max(jaccard, dice(a, b))
    }

    static func dice(_ a: String, _ b: String) -> Double {
        func bigrams(_ s: String) -> [String: Int] {
            let chars = Array(s.replacingOccurrences(of: " ", with: ""))
            guard chars.count > 1 else { return [s: 1] }
            var counts: [String: Int] = [:]
            for i in 0..<(chars.count - 1) { counts[String(chars[i...i + 1]), default: 0] += 1 }
            return counts
        }
        let ba = bigrams(a), bb = bigrams(b)
        let overlap = ba.reduce(0) { $0 + min($1.value, bb[$1.key] ?? 0) }
        let total = ba.values.reduce(0, +) + bb.values.reduce(0, +)
        return total == 0 ? 0 : 2 * Double(overlap) / Double(total)
    }

    /// How well an Apple artist credit ("A & B", "A, B & C") covers the Spotify artists.
    static func artistScore(spotifyArtists: [String], appleArtist: String) -> Double {
        let apple = normalizeArtist(appleArtist)
        guard let primary = spotifyArtists.first.map(normalizeArtist), !primary.isEmpty else { return 0 }
        if apple == primary { return 1 }
        if (" " + apple + " ").contains(" " + primary + " ") { return 0.95 }
        // Credits can be split differently, so compare against every Spotify artist.
        let joined = spotifyArtists.map(normalizeArtist).joined(separator: " ")
        return max(similarity(apple, primary), similarity(apple, joined) * 0.9)
    }

    static func durationScore(_ diff: Double) -> Double {
        switch abs(diff) {
        case ..<1.5: return 1
        case ..<3: return 0.9
        case ..<6: return 0.7
        case ..<10: return 0.4
        default: return 0
        }
    }

    // MARK: Scoring

    public struct Scored: Sendable {
        public var track: AppleTrack
        public var score: Double
    }

    /// Scores a candidate. Returns nil when it is clearly a different recording.
    public static func score(_ spotify: SpotifyTrack, _ candidate: AppleTrack, sameISRC: Bool) -> Double? {
        let durationDiff = candidate.duration - spotify.duration
        let explicitPenalty: Double = {
            guard let s = spotify.isExplicit, let a = candidate.isExplicit, s != a else { return 0 }
            return 0.08
        }()
        let albumBonus: Double = {
            guard let album = candidate.album else { return 0 }
            return similarity(normalizeTitle(album), normalizeTitle(spotify.album)) > 0.8 ? 0.06 : 0
        }()

        if sameISRC {
            // Same recording. Durations only differ by encoder padding, unless the release is
            // trimmed or extended, which we still refuse.
            guard abs(durationDiff) <= 15 else { return nil }
            return 0.9 + albumBonus + 0.04 * durationScore(durationDiff) - explicitPenalty
        }

        let spotifyTags = versionTags(spotify.name)
        let appleTags = versionTags(candidate.title)
        guard spotifyTags.major == appleTags.major else { return nil }
        let spotifyQualifier = versionQualifier(spotify.name)
        let appleQualifier = versionQualifier(candidate.title)
        var qualifierPenalty = 0.0
        if !spotifyQualifier.isEmpty && !appleQualifier.isEmpty {
            guard similarity(spotifyQualifier, appleQualifier) >= 0.75 else { return nil }
        } else if spotifyQualifier.isEmpty != appleQualifier.isEmpty {
            // "Live" against "Live at Wembley": often the same recording, credited differently.
            qualifierPenalty = 0.05
        }
        let title = similarity(normalizeTitle(spotify.name), normalizeTitle(candidate.title))
        let artist = artistScore(spotifyArtists: spotify.artists, appleArtist: candidate.artist)
        let duration = durationScore(durationDiff)
        guard title >= 0.8, artist >= 0.5, abs(durationDiff) <= 10 else { return nil }
        let minorPenalty = spotifyTags.minor == appleTags.minor ? 0 : 0.1
        let total = 0.45 * title + 0.3 * artist + 0.25 * duration + albumBonus - explicitPenalty - minorPenalty - qualifierPenalty
        return total >= 0.8 ? total : nil
    }

    /// The best acceptable candidate, if any.
    public static func best(for spotify: SpotifyTrack, among candidates: [AppleTrack], sameISRC: Bool) -> AppleTrack? {
        candidates
            .compactMap { c in score(spotify, c, sameISRC: sameISRC).map { Scored(track: c, score: $0) } }
            .max { $0.score < $1.score }?
            .track
    }

    /// The query to send to Apple Music search when there is no ISRC.
    public static func searchTerm(for spotify: SpotifyTrack) -> String {
        let title = splitAnnotations(spotify.name).core.trimmingCharacters(in: .whitespaces)
        return "\(title) \(spotify.primaryArtist)"
    }
}
