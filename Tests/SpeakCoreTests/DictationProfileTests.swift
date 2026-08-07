import Foundation
import XCTest
@testable import SpeakCore

final class DictationProfileResolverTests: XCTestCase {
    private let slackProfile = DictationProfile(
        name: "Slack",
        matchers: [.bundleID("com.tinyspeck.slackmacgap")],
        polishEnabled: false
    )
    private let mailProfile = DictationProfile(
        name: "Email",
        matchers: [.bundleID("com.apple.mail"), .bundleID("com.microsoft.Outlook")],
        polishEnabled: true,
        polishOutputLanguage: "British English"
    )

    func testExplicitBundleIDMatchWins() {
        let resolver = ProfileResolver(profiles: [slackProfile, mailProfile])

        XCTAssertEqual(resolver.profile(forBundleID: "com.apple.mail")?.name, "Email")
        XCTAssertEqual(resolver.profile(forBundleID: "com.microsoft.Outlook")?.name, "Email")
        XCTAssertEqual(resolver.profile(forBundleID: "com.tinyspeck.slackmacgap")?.name, "Slack")
    }

    func testMatchingIsCaseInsensitiveAndTrimsWhitespace() {
        let resolver = ProfileResolver(profiles: [mailProfile])

        XCTAssertEqual(resolver.profile(forBundleID: "COM.APPLE.MAIL")?.name, "Email")
        XCTAssertEqual(resolver.profile(forBundleID: "  com.apple.mail  ")?.name, "Email")
    }

    func testUnmatchedBundleIDFallsBackToDefault() {
        let resolver = ProfileResolver(profiles: [slackProfile, mailProfile])

        XCTAssertNil(resolver.profile(forBundleID: "com.apple.Safari"))
    }

    func testNilAndEmptyBundleIDsFallBackToDefault() {
        let resolver = ProfileResolver(profiles: [slackProfile])

        XCTAssertNil(resolver.profile(forBundleID: nil))
        XCTAssertNil(resolver.profile(forBundleID: ""))
        XCTAssertNil(resolver.profile(forBundleID: "   "))
    }

    func testFirstProfileInUserOrderWinsWhenSeveralMatch() {
        let duplicate = DictationProfile(
            name: "Slack Override",
            matchers: [.bundleID("com.tinyspeck.slackmacgap")]
        )
        let resolver = ProfileResolver(profiles: [slackProfile, duplicate])

        XCTAssertEqual(resolver.profile(forBundleID: "com.tinyspeck.slackmacgap")?.name, "Slack")
    }

    func testEmptyMatcherValuesNeverMatch() {
        let blank = DictationProfile(name: "Blank", matchers: [.bundleID("   ")])
        let resolver = ProfileResolver(profiles: [blank])

        XCTAssertNil(resolver.profile(forBundleID: ""))
        XCTAssertNil(resolver.profile(forBundleID: "com.apple.mail"))
    }

    func testURLPatternMatchersAreIgnoredForBundleResolution() {
        let urlProfile = DictationProfile(
            name: "GitHub",
            matchers: [DictationProfileMatcher(kind: .urlPattern, value: "github.com")]
        )
        let resolver = ProfileResolver(profiles: [urlProfile])

        XCTAssertNil(resolver.profile(forBundleID: "github.com"))
    }
}

final class DictationProfileCodableTests: XCTestCase {
    func testProfileListRoundTripsThroughCanonicalEncoding() throws {
        let profiles = [
            DictationProfile(
                name: "Code",
                matchers: [.bundleID("com.microsoft.VSCode")],
                transcriptionModelID: "deepgram/nova-3-streaming",
                polishEnabled: true,
                polishModelID: "inception/mercury",
                polishPrompt: "Format as code comments.",
                polishOutputLanguage: "English",
                polishIncludeLexiconDirectives: false,
                polishIncludeContextTags: true,
                languageIdentifier: "en_GB"
            ),
            DictationProfile(name: "Defaults Only", matchers: [.bundleID("com.apple.Notes")])
        ]

        let data = try DictationProfile.encodeList(profiles)
        let decoded = try DictationProfile.decodeList(data)

        XCTAssertEqual(decoded, profiles)
    }

    func testUnknownMatcherKindsAreDroppedInsteadOfFailingDecode() throws {
        let json = """
        [
          {
            "id": "6F1E32F9-31A5-4C1E-9E32-9E4CB25B7A4C",
            "name": "Browser",
            "matchers": [
              {"kind": "bundleID", "value": "com.apple.Safari"},
              {"kind": "windowTitle", "value": "Inbox"}
            ]
          }
        ]
        """
        let decoded = try DictationProfile.decodeList(Data(json.utf8))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].matchers, [.bundleID("com.apple.Safari")])
        XCTAssertNil(decoded[0].transcriptionModelID)
        XCTAssertNil(decoded[0].polishEnabled)
    }
}

final class TranscriptCleanupPolicyCustomPromptTests: XCTestCase {
    func testCustomBasePromptReplacesBuiltInInstructionsButKeepsLayering() {
        let prompt = TranscriptCleanupPolicy.systemPrompt(
            customBasePrompt: "Rewrite as terse engineering notes.",
            outputLanguage: "British English",
            lexiconDirectives: ["Normalize JSTI to \"Just Speak to It\"."]
        )

        XCTAssertTrue(prompt.hasPrefix("Rewrite as terse engineering notes."))
        XCTAssertFalse(prompt.contains("You are a transcription formatter."))
        XCTAssertTrue(prompt.contains("British English"))
        XCTAssertTrue(prompt.contains("Just Speak to It"))
        XCTAssertTrue(prompt.hasSuffix("Return only the cleaned transcript text."))
    }

    func testBlankCustomBasePromptFallsBackToBuiltInPolicy() {
        let prompt = TranscriptCleanupPolicy.systemPrompt(customBasePrompt: "   ")

        XCTAssertTrue(prompt.hasPrefix(TranscriptCleanupPolicy.baseSystemPrompt))
    }
}
