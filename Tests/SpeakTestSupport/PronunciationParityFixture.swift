import Foundation

/// One pronunciation corpus for every test graph. The Apple dictionary manager
/// and the portable renderer must produce exactly these outputs, so the same
/// table is asserted by the Apple suite and by the portable suite on macOS,
/// Linux and Windows.
///
/// The expected outputs were captured from the dictionary manager before its
/// replacement code moved into the shared renderer. They pin entry order,
/// case-sensitive literal matching, case-insensitive word boundaries, Unicode
/// (accented Latin, CJK, emoji), template replacement and skipped entries.
/// Plain data: this support target imports neither XCTest nor SpeakCore.
public enum PronunciationParityFixture {
    public struct Rule: Sendable {
        public let word: String
        public let pronunciation: String
        public let replacement: String?
        public let isRegex: Bool
        public let caseSensitive: Bool
    }

    public struct Sample: Sendable {
        public let input: String
        /// `applyReplacements` output.
        public let replaced: String
        /// `generateSSML` output for a provider with IPA phoneme support.
        public let ssml: String
    }

    public static let rules: [Rule] = [
        rule("API", "A P I", "A P I"),
        rule("HTTP", "H T T P", "H T T P"),
        rule("HTTPS", "H T T P S", "H T T P S"),
        rule("iOS", "eye OS", "eye OS", caseSensitive: true),
        rule("@", "at", " at "),
        rule("Zürich", "ˈtsyːʁɪç", "Tsoo-rick"),
        rule("東京", "toːkjoː", "Tokyo"),
        rule("cafe", "kæfeɪ", "caff"),
        rule("Straße", "ˈʃtʁaːsə", "Strasse", caseSensitive: true),
        rule("\\b(\\d+)\\s?ms\\b", "milliseconds", "$1 milliseconds", isRegex: true),
        rule("cat", "kat", "dog"),
        rule("dog", "dɒg", "wolf"),
        rule("skipme", "skip", ""),
        rule("nilrep", "nil", nil),
        rule("(", "paren", "bracket", isRegex: true),
        rule("🙂", "smile", " smile "),
        rule("Kubernetes", "koo-ber-net-ees", "koo ber nettees"),
        rule("Dr\\.", "doctor", "Doctor", isRegex: true, caseSensitive: true),
        rule("GIF", "\"jif\" <soft>", "jif")
    ]

    public static let samples: [Sample] = [
        Sample(
            input: "The API uses HTTP and HTTPS.",
            replaced: "The A P I uses H T T P and H T T P S.",
            ssml: "The \(tag("A P I", "API")) uses \(tag("H T T P", "HTTP")) and \(tag("H T T P S", "HTTPS"))."
        ),
        Sample(
            input: "Ship the iOS app; IOS stays.",
            replaced: "Ship the eye OS app; IOS stays.",
            ssml: "Ship the \(tag("eye OS", "iOS")) app; IOS stays."
        ),
        Sample(
            input: "email me@example.com or a @ b",
            replaced: "email me at example.com or a @ b",
            ssml: "email me\(tag("at", "@"))example.com or a @ b"
        ),
        Sample(
            input: "ZÜRICH and zürich",
            replaced: "Tsoo-rick and Tsoo-rick",
            ssml: "\(tag("ˈtsyːʁɪç", "Zürich")) and \(tag("ˈtsyːʁɪç", "Zürich"))"
        ),
        Sample(
            input: "visit 東京 now, 東京タワー stays",
            replaced: "visit Tokyo now, 東京タワー stays",
            ssml: "visit \(tag("toːkjoː", "東京")) now, 東京タワー stays"
        ),
        Sample(
            input: "café stays, cafe changes",
            replaced: "café stays, caff changes",
            ssml: "café stays, \(tag("kæfeɪ", "cafe")) changes"
        ),
        Sample(
            input: "Straße and STRASSE",
            replaced: "Strasse and STRASSE",
            ssml: "\(tag("ˈʃtʁaːsə", "Straße")) and STRASSE"
        ),
        Sample(
            input: "took 250ms and 12 ms, not 7msx",
            replaced: "took 250 milliseconds and 12 milliseconds, not 7msx",
            ssml: "took 250 milliseconds and 12 milliseconds, not 7msx"
        ),
        Sample(
            input: "cat → dog chain",
            replaced: "wolf → wolf chain",
            ssml: "\(tag("kat", "cat")) → \(tag("dɒg", "dog")) chain"
        ),
        Sample(
            input: "skipme nilrep ( stays",
            replaced: "skipme nilrep ( stays",
            ssml: "\(tag("skip", "skipme")) \(tag("nil", "nilrep")) ( stays"
        ),
        Sample(
            input: "ok🙂ok and 🙂 alone",
            replaced: "ok smile ok and 🙂 alone",
            ssml: "ok\(tag("smile", "🙂"))ok and 🙂 alone"
        ),
        Sample(
            input: "KUBERNETES on Kubernetes",
            replaced: "koo ber nettees on koo ber nettees",
            ssml: "\(tag("koo-ber-net-ees", "Kubernetes")) on \(tag("koo-ber-net-ees", "Kubernetes"))"
        ),
        Sample(
            input: "Dr. Who and dr. no",
            replaced: "Doctor Who and dr. no",
            ssml: "Doctor Who and dr. no"
        ),
        Sample(
            input: "A GIF, a gif",
            replaced: "A jif, a jif",
            ssml: "A \(tag("&quot;jif&quot; &lt;soft&gt;", "GIF")), a \(tag("&quot;jif&quot; &lt;soft&gt;", "GIF"))"
        ),
        Sample(
            input: "API\nAPI\tAPI",
            replaced: "A P I\nA P I\tA P I",
            ssml: "\(tag("A P I", "API"))\n\(tag("A P I", "API"))\t\(tag("A P I", "API"))"
        ),
        Sample(input: "  \n  ", replaced: "  \n  ", ssml: "  \n  "),
        Sample(input: "", replaced: "", ssml: "")
    ]

    private static func rule(
        _ word: String, _ pronunciation: String, _ replacement: String?,
        isRegex: Bool = false, caseSensitive: Bool = false
    ) -> Rule {
        Rule(
            word: word, pronunciation: pronunciation, replacement: replacement,
            isRegex: isRegex, caseSensitive: caseSensitive
        )
    }

    private static func tag(_ pronunciation: String, _ word: String) -> String {
        "<phoneme alphabet=\"ipa\" ph=\"\(pronunciation)\">\(word)</phoneme>"
    }
}
