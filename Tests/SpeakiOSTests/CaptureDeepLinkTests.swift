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
