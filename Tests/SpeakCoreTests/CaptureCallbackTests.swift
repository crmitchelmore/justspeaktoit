import XCTest
@testable import SpeakCore

/// The risky half of the x-callback-url vocabulary: percent-encoding a
/// transcript into a caller's URL, capping its length, refusing a callback the
/// app must not open, and validating the link parameters.
///
/// All of it is pure, so it runs on the host — the iOS-only pieces
/// (`CaptureDeepLink`, `CaptureCommandRunner`) compile but cannot run here.
final class CaptureCallbackTests: XCTestCase {

    private func callback(success: String) -> CaptureCallback {
        CaptureCallback(success: URL(string: success))
    }

    /// Reads the `text` parameter back out of a built callback the way the
    /// receiving app would.
    private func decodedText(_ url: URL?) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first { $0.name == "text" }?.value
    }

    // MARK: - Round-tripping the transcript

    func testEncodesReservedCharactersSoTheyRoundTrip() {
        let transcript = "one & two = three # four % five + six?seven/eight"
        let url = callback(success: "drafts://create").successURL(transcript: transcript)
        XCTAssertEqual(decodedText(url), transcript)
    }

    func testEncodesNewlinesAndEmoji() {
        let transcript = "line one\nline two\r\n🎙️ done — café"
        let url = callback(success: "drafts://create").successURL(transcript: transcript)
        XCTAssertEqual(decodedText(url), transcript)
    }

    func testAmpersandDoesNotBecomeASecondParameter() throws {
        let url = try XCTUnwrap(callback(success: "drafts://create").successURL(transcript: "a&truncated=true&b"))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.count, 1)
        XCTAssertEqual(decodedText(url), "a&truncated=true&b")
    }

    func testAppendsToAnExistingQuery() {
        let url = callback(success: "drafts://create?tag=voice").successURL(transcript: "hello")
        XCTAssertEqual(decodedText(url), "hello")
        XCTAssertTrue(url?.absoluteString.hasPrefix("drafts://create?tag=voice&text=") == true)
    }

    /// `drafts://create?text=` is the prefix idiom URL-only tools are written
    /// against: the value belongs where the caller left the gap.
    func testConcatenatesOntoATrailingValuePrefix() {
        let url = callback(success: "drafts://create?text=").successURL(transcript: "hello there")
        XCTAssertEqual(url?.absoluteString, "drafts://create?text=hello%20there")
        XCTAssertEqual(decodedText(url), "hello there")
    }

    // MARK: - Cap

    func testShortTranscriptIsNotTruncated() {
        let capped = CaptureCallback.capped("short")
        XCTAssertEqual(capped.text, "short")
        XCTAssertFalse(capped.truncated)
    }

    func testLongTranscriptIsTruncatedWithAMarkerAndFlag() throws {
        let transcript = String(repeating: "a", count: CaptureCallback.maxTranscriptCharacters + 500)
        let capped = CaptureCallback.capped(transcript)

        XCTAssertTrue(capped.truncated)
        XCTAssertEqual(capped.text.count, CaptureCallback.maxTranscriptCharacters)
        XCTAssertTrue(capped.text.hasSuffix(CaptureCallback.truncationMarker))

        let url = try XCTUnwrap(callback(success: "drafts://create").successURL(transcript: transcript))
        XCTAssertEqual(decodedText(url), capped.text)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "truncated" }?.value, "true")
    }

    func testTruncationCountsCharactersNotBytes() {
        // Each of these is one character and many bytes; the cap counts
        // characters, so exactly the cap survives whatever the encoded size.
        let transcript = String(repeating: "🎙️", count: CaptureCallback.maxTranscriptCharacters + 10)
        let capped = CaptureCallback.capped(transcript)
        XCTAssertTrue(capped.truncated)
        XCTAssertEqual(capped.text.count, CaptureCallback.maxTranscriptCharacters)
    }

    // MARK: - Refusing what the app must not open

    func testAcceptsCustomAppSchemes() {
        XCTAssertNotNil(CaptureCallback.validated("drafts://create?text="))
        XCTAssertNotNil(CaptureCallback.validated("shortcuts://x-callback-url/run-shortcut?name=Log"))
        XCTAssertNotNil(CaptureCallback.validated("things:///add?title="))
    }

    func testRefusesWebSchemesSoATranscriptCannotLeaveTheDevice() {
        XCTAssertNil(CaptureCallback.validated("https://example.com/collect"))
        XCTAssertNil(CaptureCallback.validated("http://example.com/collect"))
    }

    func testRefusesContentAndMessagingSchemes() {
        for raw in [
            "javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "file:///etc/passwd",
            "about:blank",
            "tel:+15550100",
            "sms:+15550100",
            "mailto:someone@example.com"
        ] {
            XCTAssertNil(CaptureCallback.validated(raw), "should refuse \(raw)")
        }
    }

    func testRefusesItsOwnSchemeSoACallbackCannotLoop() {
        XCTAssertNil(CaptureCallback.validated("justspeaktoit://dictate"))
        XCTAssertNil(CaptureCallback.validated("JustSpeakToIt://x-callback-url/dictate"))
    }

    func testRefusesMalformedCallbacks() {
        XCTAssertNil(CaptureCallback.validated(""))
        XCTAssertNil(CaptureCallback.validated("   "))
        XCTAssertNil(CaptureCallback.validated("not a url"))
        XCTAssertNil(CaptureCallback.validated("drafts"))
        XCTAssertNil(CaptureCallback.validated("drafts:"))
        XCTAssertNil(CaptureCallback.validated("://create"))
        XCTAssertNil(CaptureCallback.validated("1drafts://create"))
        XCTAssertNil(CaptureCallback.validated("drafts://create#fragment"))
        XCTAssertNil(CaptureCallback.validated("drafts://create\nx"))
        XCTAssertNil(CaptureCallback.validated(String(repeating: "d", count: 3_000)))
    }

    // MARK: - Parsing the triple

    func testParsesTheCallbackTriple() throws {
        let items = [
            URLQueryItem(name: "x-success", value: "drafts://create?text="),
            URLQueryItem(name: "X-Error", value: "drafts://error"),
            URLQueryItem(name: "x-cancel", value: "drafts://cancel")
        ]
        let parsed = try XCTUnwrap(CaptureCallback.parse(queryItems: items))
        XCTAssertEqual(parsed.success?.absoluteString, "drafts://create?text=")
        XCTAssertEqual(parsed.error?.absoluteString, "drafts://error")
        XCTAssertEqual(parsed.cancel?.absoluteString, "drafts://cancel")
    }

    func testNoCallbackParametersMeansNoCallback() throws {
        XCTAssertNil(try CaptureCallback.parse(queryItems: [URLQueryItem(name: "lang", value: "en_US")]))
    }

    /// A refused callback is never dropped quietly: a caller that thinks it
    /// passed `x-success` would wait forever for a return that cannot come.
    func testARefusedCallbackThrowsRatherThanBeingIgnored() {
        let items = [URLQueryItem(name: "x-success", value: "https://example.com/collect")]
        XCTAssertThrowsError(try CaptureCallback.parse(queryItems: items)) { error in
            XCTAssertEqual(error as? CaptureLinkFailure, .invalidCallback)
        }
        let empty = [URLQueryItem(name: "x-success", value: nil)]
        XCTAssertThrowsError(try CaptureCallback.parse(queryItems: empty))
    }

    func testErrorCallbackCarriesTheCodeAndMessage() throws {
        let callback = CaptureCallback(error: URL(string: "drafts://error"))
        let url = try XCTUnwrap(callback.errorURL(.deviceLocked))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first { $0.name == "errorCode" }?.value, "deviceLocked")
        XCTAssertEqual(
            components.queryItems?.first { $0.name == "errorMessage" }?.value,
            CaptureLinkFailure.deviceLocked.errorDescription
        )
    }

    func testEveryFailureHasAMessageForTheCallerAndTheUser() {
        for failure in CaptureLinkFailure.allCases {
            XCTAssertFalse(failure.errorDescription?.isEmpty ?? true, "\(failure) has no message")
        }
    }

    // MARK: - Refusal policy

    func testRefusesWhenTheDeviceIsLocked() {
        XCTAssertEqual(
            CaptureLinkPolicy.refusal(
                isProtectedDataAvailable: false,
                isAppActive: true,
                isCaptureBusy: false
            ),
            .deviceLocked
        )
    }

    func testRefusesWhenTheAppIsNotForeground() {
        XCTAssertEqual(
            CaptureLinkPolicy.refusal(
                isProtectedDataAvailable: true,
                isAppActive: false,
                isCaptureBusy: false
            ),
            .notForeground
        )
    }

    func testRefusesASecondConcurrentCapture() {
        XCTAssertEqual(
            CaptureLinkPolicy.refusal(
                isProtectedDataAvailable: true,
                isAppActive: true,
                isCaptureBusy: true
            ),
            .alreadyRecording
        )
    }

    func testProceedsWhenUnlockedForegroundAndIdle() {
        XCTAssertNil(
            CaptureLinkPolicy.refusal(
                isProtectedDataAvailable: true,
                isAppActive: true,
                isCaptureBusy: false
            )
        )
    }

    // MARK: - Parameters

    func testLanguageAcceptsCatalogueIdentifiers() {
        XCTAssertEqual(CaptureLinkParameters.language(from: "en_GB"), "en_GB")
        XCTAssertEqual(CaptureLinkParameters.language(from: "en-GB"), "en_GB")
        XCTAssertEqual(CaptureLinkParameters.language(from: "EN_gb"), "en_GB")
        XCTAssertEqual(CaptureLinkParameters.language(from: "auto"), "automatic")
        XCTAssertEqual(CaptureLinkParameters.language(from: "automatic"), "automatic")
    }

    /// A bare `en` matches four catalogue locales, so honouring it would mean
    /// silently choosing one the caller did not ask for.
    func testLanguageRejectsAmbiguousAndUnknownValues() {
        XCTAssertNil(CaptureLinkParameters.language(from: "en"))
        XCTAssertNil(CaptureLinkParameters.language(from: "klingon"))
        XCTAssertNil(CaptureLinkParameters.language(from: ""))
    }

    func testModelAcceptsCatalogueIdentifiersOnly() {
        let known = ModelCatalog.liveTranscription[0].id
        XCTAssertEqual(CaptureLinkParameters.model(from: known), known)
        XCTAssertEqual(CaptureLinkParameters.model(from: known.uppercased()), known)
        XCTAssertNil(CaptureLinkParameters.model(from: "openai/not-a-model"))
        XCTAssertNil(CaptureLinkParameters.model(from: ModelCatalog.customOptionID))
        XCTAssertNil(CaptureLinkParameters.model(from: ""))
    }

    func testBatchOnlyModelsForceBatchMode() throws {
        let live = ModelCatalog.liveTranscription[0].id
        XCTAssertFalse(CaptureLinkParameters.requiresBatchMode(live))
        let batchOnly = ModelCatalog.batchTranscription
            .map(\.id)
            .first { id in !ModelCatalog.liveTranscription.contains { $0.id == id } }
        XCTAssertTrue(CaptureLinkParameters.requiresBatchMode(try XCTUnwrap(batchOnly)))
    }

    func testDurationAcceptsSecondsInsideTheAllowedRange() {
        XCTAssertEqual(CaptureLinkParameters.duration(from: "30"), 30)
        XCTAssertEqual(CaptureLinkParameters.duration(from: "1.5"), 1.5)
        XCTAssertEqual(
            CaptureLinkParameters.duration(from: "600"),
            CaptureLinkParameters.durationRange.upperBound
        )
    }

    func testDurationRejectsNonsenseAndOutOfRangeValues() {
        XCTAssertNil(CaptureLinkParameters.duration(from: "0"))
        XCTAssertNil(CaptureLinkParameters.duration(from: "-5"))
        XCTAssertNil(CaptureLinkParameters.duration(from: "9999"))
        XCTAssertNil(CaptureLinkParameters.duration(from: "soon"))
        XCTAssertNil(CaptureLinkParameters.duration(from: ""))
        XCTAssertNil(CaptureLinkParameters.duration(from: "inf"))
    }
}
