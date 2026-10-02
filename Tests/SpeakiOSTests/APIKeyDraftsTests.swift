#if os(iOS)
import SpeakCore
import XCTest
@testable import SpeakiOSLib

final class APIKeyDraftsTests: XCTestCase {
    func testAnyEnteredKeyEnablesSave() {
        for id in ["speechmatics", "revai", "mistral", "azure", "deepgram", "some-future-provider"] {
            var drafts = APIKeyDrafts()
            XCTAssertFalse(drafts.hasUnsavedKey)
            drafts[id] = "entered"
            XCTAssertTrue(drafts.hasUnsavedKey, "\(id) should enable Save")
            drafts[id] = ""
            XCTAssertFalse(drafts.hasUnsavedKey, "an emptied \(id) field should not enable Save")
        }
    }

    func testSubmissionHoldsOnlyTheKeysEnteredAtSave() {
        var drafts = APIKeyDrafts()
        drafts["deepgram"] = "dg-key"
        drafts["mistral"] = "mistral-key"
        drafts["openai"] = ""

        XCTAssertEqual(drafts.submission(), ["deepgram": "dg-key", "mistral": "mistral-key"])
    }

    func testAnEditMadeWhileValidatingSurvivesTheEarlierSave() {
        var drafts = APIKeyDrafts()
        drafts["deepgram"] = "submitted"
        let submitted = drafts.submission()["deepgram"] ?? ""

        drafts["deepgram"] = "edited while validating"
        drafts.clear("deepgram", ifStill: submitted)
        XCTAssertEqual(drafts["deepgram"], "edited while validating")

        drafts.clear("deepgram", ifStill: "edited while validating")
        XCTAssertEqual(drafts["deepgram"], "")
        XCTAssertFalse(drafts.hasUnsavedKey)
    }

    @MainActor
    func testBalancesResolveEachKeyByTheIdentifierItIsStoredUnder() {
        let stored: [String: String] = [
            "deepgram": AppSettings.deepgramKeyID,
            "elevenlabs": AppSettings.elevenLabsKeyID,
            "openrouter": AppSettings.openRouterKeyID,
            "openai": AppSettings.openAIKeyID,
            "cartesia": AppSettings.cartesiaKeyID,
            "soniox": AppSettings.sonioxKeyID,
            "modulate": AppSettings.modulateKeyID,
            "assemblyai": AppSettings.assemblyAIKeyID,
            "gladia": AppSettings.gladiaKeyID,
            "google": AppSettings.googleKeyID,
            "xai": AppSettings.xAIKeyID,
            "azure": AppSettings.azureKeyID,
            "meta": AppSettings.metaKeyID,
            "speechmatics": AppSettings.speechmaticsKeyID,
            "revai": AppSettings.revAIKeyID,
            "mistral": AppSettings.mistralKeyID
        ]
        for (id, identifier) in stored {
            XCTAssertEqual(APIKeysView.credentialIdentifier(for: id), identifier, id)
        }
        XCTAssertEqual(
            ProviderBalanceDirectory.account(
                forCredentialIdentifier: APIKeysView.credentialIdentifier(for: "azure")
            )?.id,
            "azure"
        )
    }
}
#endif
