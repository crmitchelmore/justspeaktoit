import Foundation
import XCTest
@testable import SpeakCore

final class APIKeyGuidanceTests: XCTestCase {
    func testEveryKnownCredential_HasExactlyOneGuide() {
        for identifier in ModelCredentialResolver.allKnownAPIKeyIdentifiers {
            let matches = APIKeyGuidance.guides.filter { $0.identifiers.contains(identifier) }
            XCTAssertEqual(matches.count, 1, identifier)
        }
        let catalogued = APIKeyGuidance.guides.flatMap(\.identifiers)
        XCTAssertEqual(Set(catalogued).count, catalogued.count)
        XCTAssertTrue(Set(catalogued).isSubset(of: ModelCredentialResolver.allKnownAPIKeyIdentifiers))
    }

    func testLinks_AreHTTPSWithoutQueryPresetsOrSecrets() throws {
        for guide in APIKeyGuidance.guides {
            for url in [guide.creationURL] + guide.sources {
                XCTAssertEqual(url.scheme, "https", url.absoluteString)
                XCTAssertNotNil(url.host, url.absoluteString)
                XCTAssertNil(url.user, url.absoluteString)
                XCTAssertNil(url.password, url.absoluteString)
                XCTAssertNil(url.fragment, url.absoluteString)
            }
            XCTAssertFalse(guide.sources.isEmpty, guide.providerName)
            // No provider documents a scope-preselecting link. Deepgram's
            // documented console link only opens the keys page.
            let query = URLComponents(url: guide.creationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.allSatisfy { $0.name == "jump" && $0.value == "keys" }, guide.providerName)
        }
        let deepgram = try XCTUnwrap(APIKeyGuidance.guide(for: "deepgram.apiKey"))
        XCTAssertEqual(deepgram.creationURL.absoluteString, "https://console.deepgram.com/signup?jump=keys")
    }

    func testMinimumPermissions_FollowTheSelectedUsesAndUnionSharedKeys() throws {
        let elevenLabs = try XCTUnwrap(APIKeyGuidance.guide(for: "elevenlabs.apiKey"))
        XCTAssertEqual(elevenLabs.minimumPermissions(for: .transcription), ["Speech to Text", "User: Read"])
        XCTAssertEqual(
            elevenLabs.minimumPermissions(for: .voiceOutput), ["Text to Speech", "Voices: Read", "User: Read"]
        )
        XCTAssertEqual(
            elevenLabs.minimumPermissions(for: [.transcription, .voiceOutput]),
            ["Speech to Text", "Text to Speech", "Voices: Read", "User: Read"]
        )

        let openAI = try XCTUnwrap(APIKeyGuidance.guide(for: "openai.apiKey"))
        XCTAssertEqual(
            openAI.minimumPermissions(for: [.transcription, .voiceOutput]),
            ["Model capabilities: Request", "List models: Read"]
        )
        XCTAssertTrue(openAI.identifiers.contains(OpenAITTSCatalog.credentialIdentifier))
    }

    func testOptionalChecks_NeverWidenTheMinimum() throws {
        let deepgram = try XCTUnwrap(APIKeyGuidance.guide(for: "deepgram.apiKey"))
        let minimum = deepgram.minimumPermissions(for: [.transcription, .voiceOutput])
        XCTAssertEqual(minimum, ["Member role"])
        XCTAssertFalse(minimum.contains { $0.contains("billing") || $0.contains("Admin") || $0.contains("Owner") })
        XCTAssertEqual(deepgram.requirements(for: .transcription).last?.isOptional, true)

        for guide in APIKeyGuidance.guides {
            for uses in [APIKeyUses.transcription, .postProcessing, .voiceOutput, [.transcription, .postProcessing]] {
                let minimum = guide.minimumPermissions(for: uses).joined(separator: " ").lowercased()
                for broad in ["admin", "owner", "billing", "management", "full access"] {
                    XCTAssertFalse(minimum.contains(broad), "\(guide.providerName) asks for \(broad)")
                }
            }
        }
    }

    func testUnrelatedUses_AreLeftOut() throws {
        let deepgram = try XCTUnwrap(APIKeyGuidance.guide(for: "deepgram.apiKey"))
        let transcriptionOnly = deepgram.lines(for: .transcription).joined(separator: "\n")
        XCTAssertTrue(transcriptionOnly.contains("/v1/listen"))
        XCTAssertFalse(transcriptionOnly.contains("/v1/speak"))

        let openRouter = try XCTUnwrap(APIKeyGuidance.guide(for: "openrouter.apiKey"))
        let cleanupOnly = openRouter.lines(for: .postProcessing).joined(separator: "\n")
        XCTAssertTrue(cleanupOnly.contains("Post-processing: /api/v1/chat/completions."))
        XCTAssertFalse(cleanupOnly.contains("Voice Output"))
        let shared = openRouter.lines(for: [.transcription, .postProcessing]).joined(separator: "\n")
        XCTAssertTrue(shared.contains("Transcription: /api/v1/audio"))
        XCTAssertTrue(shared.contains("Post-processing: /api/v1/chat/completions."))
    }

    func testMissingCapabilities_AreStatedExplicitly() throws {
        for guide in APIKeyGuidance.guides {
            let text = guide.lines(for: [.transcription, .postProcessing, .voiceOutput]).joined(separator: "\n")
            XCTAssertTrue(text.contains("does not document a link that opens key creation"), guide.providerName)
            XCTAssertTrue(text.contains("Speak's advice, not the provider's"), guide.providerName)
            XCTAssertTrue(text.contains(APIKeyGuidance.lastVerified), guide.providerName)
            if case .none = guide.scopes {
                XCTAssertTrue(text.contains("no per-feature scopes"), guide.providerName)
            }
            if guide.expiry.providerRecommendation == nil {
                XCTAssertTrue(text.contains("publishes no recommended key lifetime"), guide.providerName)
            }
        }
        let alibaba = try XCTUnwrap(APIKeyGuidance.guide(for: AlibabaSpeechConfiguration.credentialIdentifier))
        XCTAssertEqual(alibaba.expiry.setting, .notOffered)
        XCTAssertTrue(alibaba.expiryLine.contains("do not expire"))
        let mistral = try XCTUnwrap(APIKeyGuidance.guide(for: "mistral.apiKey"))
        XCTAssertEqual(mistral.expiry.setting, .configurable("Expiration"))
    }

    func testPromptSummary_NamesMinimumOrLimitation() {
        XCTAssertEqual(
            APIKeyGuidance.promptSummary(for: "deepgram.apiKey", uses: .transcription),
            "Create the key with only: Member role."
        )
        XCTAssertEqual(
            APIKeyGuidance.promptSummary(for: "assemblyai.apiKey", uses: .transcription),
            "AssemblyAI keys have no per-feature scopes; create one used only for Speak."
        )
        XCTAssertNil(APIKeyGuidance.promptSummary(for: "unknown.apiKey", uses: .transcription))
    }

    func testCatalogEntries_UseGuideLinksAndShortHints() throws {
        let sources = ModelCredentialResolver.allKnownAPIKeyIdentifiers.map {
            APIKeyCatalogSource(
                identifier: $0, providerName: $0, use: [.transcription, .postProcessing, .voiceOutput],
                keyPageURL: URL(string: "https://example.com")
            )
        }
        for entry in APIKeyCatalog.entries(sources) {
            let guide = try XCTUnwrap(entry.guide, entry.identifier)
            XCTAssertEqual(entry.keyPageURL, guide.creationURL, entry.identifier)
            XCTAssertEqual(APIKeyCatalog.keyPageURL(for: entry.identifier), guide.creationURL)
            XCTAssertTrue(entry.setupHint.hasPrefix(entry.format.entryHint))
            // The Windows API Keys page rejects hints longer than 512 characters.
            XCTAssertLessThanOrEqual(entry.setupHint.utf16.count, 512, entry.identifier)
        }
    }
}
