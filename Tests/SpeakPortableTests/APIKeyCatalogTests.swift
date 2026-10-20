import Foundation
import XCTest
@testable import SpeakCore

final class APIKeyCatalogTests: XCTestCase {
    func testMaskedSuffix_ShowsOnlyLastFourOfLongPlainKeysAndNothingOfShortOrCompositeSecrets() {
        XCTAssertEqual(
            APIKeyCatalog.maskedSuffix(" sk-abcdefghijklmnop1234 \n", identifier: "openai.apiKey"), "••••1234"
        )
        XCTAssertNil(APIKeyCatalog.maskedSuffix("short-key", identifier: "openai.apiKey"))
        XCTAssertNil(APIKeyCatalog.maskedSuffix("   ", identifier: "openai.apiKey"))
        XCTAssertNil(APIKeyCatalog.maskedSuffix("anything-at-all-long-enough", identifier: "alibaba.apiKey"))
        XCTAssertEqual(
            APIKeyCatalog.maskedSuffix("0123456789abcdefWXYZ:westeurope", identifier: "azure.speech.apiKey"),
            "••••WXYZ, region westeurope"
        )
        XCTAssertEqual(
            APIKeyCatalog.maskedSuffix("local-proxy/secret-token-value", identifier: "azure.speech.apiKey"),
            "local proxy token"
        )
    }

    func testSanitizedKey_TrimsAndRejectsEmptyControlAndOversizedValues() throws {
        XCTAssertEqual(try APIKeyCatalog.sanitizedKey("  key-value \n"), "key-value")
        XCTAssertThrowsError(try APIKeyCatalog.sanitizedKey(" \n ")) { XCTAssertEqual($0 as? APIKeyEntryError, .empty) }
        XCTAssertThrowsError(try APIKeyCatalog.sanitizedKey("a\u{0}b")) {
            XCTAssertEqual($0 as? APIKeyEntryError, .invalid)
        }
        XCTAssertThrowsError(try APIKeyCatalog.sanitizedKey(String(repeating: "k", count: 8_193))) {
            XCTAssertEqual($0 as? APIKeyEntryError, .invalid)
        }
    }

    func testTrackedIdentifiers_MirrorMacRegisterRemoveAndReconcileSemantics() throws {
        var tracked = TrackedAPIKeyIdentifiers(["groq.apiKey", "deepgram.apiKey", "groq.apiKey", ""])
        XCTAssertEqual(tracked.identifiers, ["deepgram.apiKey", "groq.apiKey"])
        XCTAssertFalse(tracked.register("groq.apiKey"))
        XCTAssertTrue(tracked.record("openai.apiKey", storedValue: "sk-value"))
        XCTAssertTrue(tracked.record("groq.apiKey", storedValue: "  "))
        XCTAssertEqual(tracked.identifiers, ["deepgram.apiKey", "openai.apiKey"])
        XCTAssertFalse(tracked.remove("missing.apiKey"))
        XCTAssertTrue(tracked.reconcile(["xai.apiKey"]))
        XCTAssertFalse(tracked.reconcile(["xai.apiKey", "xai.apiKey"]))
        XCTAssertEqual(tracked.identifiers, ["xai.apiKey"])

        let data = try JSONEncoder().encode(tracked)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        XCTAssertEqual(object, [ApplicationPreferenceKey.trackedKeyIdentifiers.rawValue: ["xai.apiKey"]])
        let decoded = try JSONDecoder().decode(
            TrackedAPIKeyIdentifiers.self, from: Data(#"{"trackedKeyIdentifiers":["b","a","b"]}"#.utf8)
        )
        XCTAssertEqual(decoded.identifiers, ["a", "b"])
        XCTAssertEqual(try JSONDecoder().decode(TrackedAPIKeyIdentifiers.self, from: Data("{}".utf8)).identifiers, [])
    }

    func testEntries_MergeUsesPerIdentifierLeadWithOpenRouterAndStayWithinKnownIdentifiers() throws {
        let sources = [
            APIKeyCatalogSource.model("deepgram/nova-3", purpose: .batchTranscription),
            APIKeyCatalogSource.model("deepgram/aura-2-thalia-en", purpose: .voiceOutput),
            APIKeyCatalogSource(identifier: "openrouter.apiKey", providerName: "OpenRouter", use: .postProcessing),
            APIKeyCatalogSource(identifier: "openai.tts.apiKey", providerName: "OpenAI", use: .voiceOutput),
            APIKeyCatalogSource(identifier: "azure.speech.apiKey", providerName: "Azure", use: .voiceOutput)
        ].compactMap { $0 }
        let entries = APIKeyCatalog.entries(sources)

        XCTAssertEqual(entries.first?.identifier, "openrouter.apiKey")
        XCTAssertEqual(Set(entries.map(\.identifier)).count, entries.count)
        let deepgram = try XCTUnwrap(entries.first { $0.identifier == "deepgram.apiKey" })
        XCTAssertEqual(deepgram.uses, [.transcription, .voiceOutput])
        XCTAssertEqual(deepgram.uses.summary, "Transcription, Voice Output")
        XCTAssertEqual(entries.first { $0.identifier == "openai.tts.apiKey" }?.label, "OpenAI Voice Output")
        XCTAssertEqual(entries.first { $0.identifier == "azure.speech.apiKey" }?.label, "Azure Speech")
        XCTAssertEqual(entries.first { $0.identifier == "azure.speech.apiKey" }?.format, .azureKeyAndRegion)
        XCTAssertTrue(Set(entries.map(\.identifier)).isSubset(of: ModelCredentialResolver.allKnownAPIKeyIdentifiers))
        XCTAssertEqual(entries.first?.keyPageURL, OpenRouterService.apiKeysURL)
    }

    func testKeyPageURL_IsHTTPSForEveryKnownIdentifierThatHasOne() {
        for identifier in ModelCredentialResolver.allKnownAPIKeyIdentifiers {
            if let url = APIKeyCatalog.keyPageURL(for: identifier) {
                XCTAssertEqual(url.scheme, "https", identifier)
            }
        }
        XCTAssertNotNil(APIKeyCatalog.keyPageURL(for: "openai.tts.apiKey"))
        XCTAssertNil(APIKeyCatalog.keyPageURL(for: "unknown.apiKey"))
    }

    func testValidation_RejectsEmptyAndUnsupportedIdentifiersWithoutNetwork() async throws {
        let staging = SharedMultipartUploadStaging(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            securityPolicy: .init(
                prepareDirectory: { url, manager in
                    try manager.createDirectory(at: url, withIntermediateDirectories: true)
                },
                createFile: { url, manager in manager.createFile(atPath: url.path, contents: nil) }
            )
        )
        let empty = await APIKeyValidation.validate(identifier: "openai.apiKey", key: "  ", staging: staging)
        XCTAssertEqual(empty.outcome, .failure(message: "API key is empty"))
        let unknown = await APIKeyValidation.validate(identifier: "unknown.apiKey", key: "value", staging: staging)
        XCTAssertEqual(unknown.outcome, .failure(message: "Checking this key is not supported."))
    }
}
