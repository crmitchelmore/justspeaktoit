#if os(iOS)
import XCTest
import SpeakCore
@testable import SpeakiOSLib

/// Parsing tests for the capture URL vocabulary. The parser is pure, so the
/// whole verb/destination surface is covered here; performing a command is
/// `CaptureCommandRunner`'s job and needs a device.
final class CaptureDeepLinkTests: XCTestCase {
    private func parse(_ string: String) -> CaptureDeepLink? {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return nil
        }
        return CaptureDeepLink.parse(url)
    }

    // MARK: - Verbs

    func testParsesEachVerb() {
        XCTAssertEqual(parse("justspeaktoit://start")?.action, .start)
        XCTAssertEqual(parse("justspeaktoit://stop")?.action, .stop)
        XCTAssertEqual(parse("justspeaktoit://toggle")?.action, .toggle)
    }

    func testVerbIsCaseInsensitive() {
        XCTAssertEqual(parse("justspeaktoit://TOGGLE")?.action, .toggle)
        XCTAssertEqual(parse("JUSTSPEAKTOIT://start")?.action, .start)
    }

    func testTranscribeWithActionQueryIsACommand() {
        // The widget's iOS 17 fallback: one host, the verb in a query item.
        XCTAssertEqual(parse("justspeaktoit://transcribe?action=start")?.action, .start)
        XCTAssertEqual(parse("justspeaktoit://transcribe?action=toggle")?.action, .toggle)
    }

    func testPlainTabLinksAreNotCaptureCommands() {
        XCTAssertNil(parse("justspeaktoit://transcribe"))
        XCTAssertNil(parse("justspeaktoit://openclaw"))
        XCTAssertNil(parse("justspeaktoit://openclaw/conversation/abc"))
    }

    func testUnknownVerbsAndSchemesAreRejected() {
        XCTAssertNil(parse("justspeaktoit://record"))
        XCTAssertNil(parse("justspeaktoit://transcribe?action=explode"))
        XCTAssertNil(parse("otherapp://start"))
        XCTAssertNil(parse("https://start"))
    }

    // MARK: - Destination override

    func testDestinationRawValuesParse() {
        XCTAssertEqual(parse("justspeaktoit://stop?destination=clipboard")?.destination, .clipboard)
        XCTAssertEqual(
            parse("justspeaktoit://stop?destination=clipboardAndPostProcess")?.destination,
            .clipboardAndPostProcess
        )
        XCTAssertEqual(parse("justspeaktoit://stop?destination=historyOnly")?.destination, .historyOnly)
    }

    func testDestinationAliasesParse() {
        XCTAssertEqual(parse("justspeaktoit://stop?destination=polish")?.destination, .clipboardAndPostProcess)
        XCTAssertEqual(parse("justspeaktoit://stop?destination=history")?.destination, .historyOnly)
        XCTAssertEqual(parse("justspeaktoit://stop?destination=HISTORY")?.destination, .historyOnly)
    }

    func testMissingOrUnknownDestinationFallsBackToTheConfiguredOne() {
        XCTAssertNil(parse("justspeaktoit://toggle")?.destination)
        // A typo must not fail the whole link: still records, uses the setting.
        let typo = parse("justspeaktoit://toggle?destination=clipbaord")
        XCTAssertEqual(typo?.action, .toggle)
        XCTAssertNil(typo?.destination)
        XCTAssertNil(parse("justspeaktoit://toggle?destination=")?.destination)
    }

    func testDestinationSurvivesAlongsideOtherQueryItems() {
        let link = parse("justspeaktoit://transcribe?action=start&destination=history&source=nfc")
        XCTAssertEqual(link?.action, .start)
        XCTAssertEqual(link?.destination, .historyOnly)
    }

    // MARK: - dictate and x-callback-url

    func testDictateParsesAsAVerb() {
        XCTAssertEqual(parse("justspeaktoit://dictate")?.action, .dictate)
        XCTAssertEqual(parse("justspeaktoit://transcribe?action=dictate")?.action, .dictate)
    }

    func testXCallbackWrapperCarriesTheVerbInThePath() {
        XCTAssertEqual(parse("justspeaktoit://x-callback-url/dictate")?.action, .dictate)
        XCTAssertEqual(parse("justspeaktoit://x-callback-url/start")?.action, .start)
        XCTAssertNil(parse("justspeaktoit://x-callback-url"))
        XCTAssertNil(parse("justspeaktoit://x-callback-url/explode"))
    }

    func testCallbackTripleIsParsedOnDictate() {
        let link = parse(
            "justspeaktoit://x-callback-url/dictate"
                + "?x-success=drafts://create?text=&x-error=drafts://error&x-cancel=drafts://cancel"
        )
        XCTAssertEqual(link?.action, .dictate)
        XCTAssertEqual(link?.callback?.success?.absoluteString, "drafts://create?text=")
        XCTAssertEqual(link?.callback?.error?.absoluteString, "drafts://error")
        XCTAssertEqual(link?.callback?.cancel?.absoluteString, "drafts://cancel")
        XCTAssertNil(link?.failure)
    }

    func testAPercentEncodedCallbackIsAcceptedToo() {
        let link = parse("justspeaktoit://dictate?x-success=drafts%3A%2F%2Fcreate%3Ftext%3D")
        XCTAssertEqual(link?.callback?.success?.absoluteString, "drafts://create?text=")
    }

    func testACallbackTheAppWillNotOpenFailsTheLink() {
        let link = parse("justspeaktoit://dictate?x-success=https://example.com/collect")
        XCTAssertEqual(link?.failure, .invalidCallback)
        // Nowhere safe to send the error, so no callback is kept.
        XCTAssertNil(link?.callback)
    }

    /// A callback on `stop` would let any app redirect a dictation it did not
    /// start into its own text field.
    func testCallbacksAndMaxDurationAreRefusedOnOtherVerbs() {
        XCTAssertEqual(parse("justspeaktoit://stop?x-success=drafts://create")?.failure, .unsupportedParameter)
        XCTAssertEqual(parse("justspeaktoit://start?x-success=drafts://create")?.failure, .unsupportedParameter)
        XCTAssertEqual(parse("justspeaktoit://toggle?maxDuration=30")?.failure, .unsupportedParameter)
    }

    func testDictateWithoutMaxDurationStillHasADeadline() {
        let link = parse("justspeaktoit://dictate")
        XCTAssertNil(link?.maxDuration)
        XCTAssertEqual(link?.dictateDuration, CaptureLinkParameters.defaultDictateDuration)
    }

    func testMaxDurationParsesAndBoundsAreEnforced() {
        XCTAssertEqual(parse("justspeaktoit://dictate?maxDuration=45")?.maxDuration, 45)
        XCTAssertEqual(parse("justspeaktoit://dictate?maxDuration=0")?.failure, .invalidMaxDuration)
        XCTAssertEqual(parse("justspeaktoit://dictate?maxDuration=9999")?.failure, .invalidMaxDuration)
        XCTAssertEqual(parse("justspeaktoit://dictate?maxDuration=soon")?.failure, .invalidMaxDuration)
    }

    // MARK: - lang and model

    func testLanguageAndModelParse() {
        let known = ModelCatalog.liveTranscription[0].id
        let link = parse("justspeaktoit://start?lang=en-GB&model=\(known)")
        XCTAssertEqual(link?.languageIdentifier, "en_GB")
        XCTAssertEqual(link?.modelIdentifier, known)
        XCTAssertNil(link?.failure)
    }

    /// Recording with a different model or language than the caller named is a
    /// silent wrong answer, so an unknown value fails the link.
    func testUnknownLanguageOrModelFailsTheLinkVisibly() {
        XCTAssertEqual(parse("justspeaktoit://start?lang=klingon")?.failure, .unknownLanguage)
        XCTAssertEqual(parse("justspeaktoit://start?model=openai/not-a-model")?.failure, .unknownModel)
        // A bare language matches four catalogue locales — too ambiguous to pick.
        XCTAssertEqual(parse("justspeaktoit://dictate?lang=en")?.failure, .unknownLanguage)
    }

    func testLanguageAndModelAreRefusedOnStop() {
        XCTAssertEqual(parse("justspeaktoit://stop?lang=en_US")?.failure, .unsupportedParameter)
    }

    func testAFailedLinkStillCarriesItsErrorCallback() {
        let link = parse("justspeaktoit://dictate?lang=klingon&x-error=drafts://error")
        XCTAssertEqual(link?.failure, .unknownLanguage)
        XCTAssertEqual(link?.callback?.error?.absoluteString, "drafts://error")
    }

    // MARK: - Router integration

    @MainActor
    func testRouterQueuesTheCommandAndSelectsTheTranscribeTab() {
        let router = DeepLinkRouter()
        router.selectedTab = 1
        router.pendingConversationId = "abc"

        XCTAssertTrue(router.handle(URL(string: "justspeaktoit://start?destination=history")!))
        XCTAssertEqual(router.selectedTab, 0)
        XCTAssertNil(router.pendingConversationId)
        XCTAssertEqual(router.pendingCaptureAction?.action, .start)
        XCTAssertEqual(router.pendingCaptureAction?.destination, .historyOnly)
    }

    @MainActor
    func testRouterConsumesTheCommandExactlyOnce() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "justspeaktoit://toggle")!)

        XCTAssertEqual(router.consumePendingCaptureAction()?.action, .toggle)
        XCTAssertNil(router.consumePendingCaptureAction())
    }

    @MainActor
    func testRouterStillHandlesTabLinks() {
        let router = DeepLinkRouter()
        XCTAssertTrue(router.handle(URL(string: "justspeaktoit://openclaw/conversation/xyz")!))
        XCTAssertEqual(router.selectedTab, 1)
        XCTAssertEqual(router.pendingConversationId, "xyz")
        XCTAssertNil(router.pendingCaptureAction)
    }

    @MainActor
    func testRouterRejectsForeignSchemes() {
        let router = DeepLinkRouter()
        XCTAssertFalse(router.handle(URL(string: "otherapp://start")!))
        XCTAssertNil(router.pendingCaptureAction)
    }

    @MainActor
    func testRouterAcceptsTheSchemeCaseInsensitivelyLikeTheParser() {
        // The parser lowercases the scheme, so the router must too or an
        // uppercase link parses as a command and is then silently dropped.
        let router = DeepLinkRouter()
        XCTAssertTrue(router.handle(URL(string: "JUSTSPEAKTOIT://toggle")!))
        XCTAssertEqual(router.pendingCaptureAction?.action, .toggle)
    }

    @MainActor
    func testRouterKeepsTheLatestOfTwoQueuedCommands() {
        // Two capture links can only race inside the cold-launch window; the
        // newer one is what the user last asked for.
        let router = DeepLinkRouter()
        router.handle(URL(string: "justspeaktoit://start?destination=history")!)
        router.handle(URL(string: "justspeaktoit://stop")!)

        let pending = router.consumePendingCaptureAction()
        XCTAssertEqual(pending?.action, .stop)
        XCTAssertNil(pending?.destination)
    }

    @MainActor
    func testTabLinkHostIsCaseInsensitive() {
        let router = DeepLinkRouter()
        XCTAssertTrue(router.handle(URL(string: "justspeaktoit://OpenClaw")!))
        XCTAssertEqual(router.selectedTab, 1)
    }
}
#endif
