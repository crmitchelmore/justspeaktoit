import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopActivationLinkTests: XCTestCase {
    private func parse(_ text: String) throws -> DesktopActivationRequest {
        try DesktopActivationLink.parse(text, scheme: "justspeaktoit")
    }

    private func refusal(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            let request = try parse(text)
            XCTFail("\(text) parsed as \(request)", file: file, line: line)
            return nil
        } catch let error as DesktopActivationLinkError {
            return error.message
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
            return nil
        }
    }

    func testRecorderVerbsMatchTheIPhoneVocabulary() throws {
        XCTAssertEqual(try parse("justspeaktoit://start"), .capture(.start))
        XCTAssertEqual(try parse("justspeaktoit://stop"), .capture(.stop))
        XCTAssertEqual(try parse("justspeaktoit://toggle/"), .capture(.toggle))
        XCTAssertEqual(try parse("JUSTSPEAKTOIT://Start"), .capture(.start))
        XCTAssertEqual(try parse("justspeaktoit://transcribe?action=stop"), .capture(.stop))
        XCTAssertEqual(try parse("justspeaktoit://transcribe?action=TOGGLE"), .capture(.toggle))
    }

    func testShowLinksBringTheWindowForward() throws {
        XCTAssertEqual(try parse("justspeaktoit://"), .show)
        XCTAssertEqual(try parse("justspeaktoit://open"), .show)
        XCTAssertEqual(try parse("justspeaktoit://transcribe"), .show)
    }

    func testTheSignInCallbackCarriesItsToken() throws {
        XCTAssertEqual(
            try parse("justspeaktoit://cloudkit-sign-in?ckWebAuthToken=abc%2Bdef%3D"),
            .cloudKitSignIn(webAuthToken: "abc+def=")
        )
        XCTAssertEqual(
            try parse("justspeaktoit://cloudkit-sign-in/?ckWebAuthToken=t&other=1"),
            .cloudKitSignIn(webAuthToken: "t")
        )
        XCTAssertNotNil(refusal("justspeaktoit://cloudkit-sign-in"))
        XCTAssertNotNil(refusal("justspeaktoit://cloudkit-sign-in?ckWebAuthToken="))
        XCTAssertNotNil(refusal("justspeaktoit://cloudkit-sign-in?ckWebAuthToken=a&ckWebAuthToken=b"))
        XCTAssertNotNil(refusal("justspeaktoit://cloudkit-sign-in/elsewhere?ckWebAuthToken=a"))
        XCTAssertEqual(
            DesktopActivationLink.cloudKitSignInURL(scheme: "justspeaktoit"), "justspeaktoit://cloudkit-sign-in"
        )
    }

    func testWhatWindowsCannotHonourIsRefusedWithAReason() throws {
        XCTAssertEqual(
            refusal("justspeaktoit://start?lang=fr"),
            "The lang link option is not available on Windows yet; the recording uses the app's settings."
        )
        XCTAssertNotNil(refusal("justspeaktoit://start?destination=clipboard"))
        XCTAssertNotNil(refusal("justspeaktoit://toggle?model=openai/whisper-1"))
        XCTAssertNotNil(refusal("justspeaktoit://transcribe?action=start&lang=fr"))
        XCTAssertNotNil(refusal("justspeaktoit://start?surprise=1"))
        XCTAssertNotNil(refusal("justspeaktoit://transcribe?action=record"))
        XCTAssertNotNil(refusal("justspeaktoit://transcribe?action=start&action=stop"))
        XCTAssertNotNil(refusal("justspeaktoit://dictate"))
        XCTAssertNotNil(refusal("justspeaktoit://x-callback-url/dictate?x-success=drafts://create"))
        XCTAssertEqual(
            refusal("justspeaktoit://openclaw"), "OpenClaw is an iPhone feature and is not available on Windows."
        )
        XCTAssertNotNil(refusal("justspeaktoit://open?x=1"))
        XCTAssertNotNil(refusal("justspeaktoit://start/extra"))
        XCTAssertNotNil(refusal("justspeaktoit://settings"))
    }

    func testOtherSchemesAndMalformedLinksAreRefused() {
        XCTAssertNotNil(refusal("justspeaktoit-alpha://start"))
        XCTAssertNotNil(refusal("https://example.com/start"))
        XCTAssertNotNil(refusal("justspeaktoit://user@start"))
        XCTAssertNotNil(refusal("justspeaktoit://start:80"))
        XCTAssertNotNil(refusal("justspeaktoit://start#fragment"))
        XCTAssertNotNil(refusal("justspeaktoit://start\n"))
        let oversized = String(repeating: "a", count: DesktopActivationLink.maximumLength)
        XCTAssertNotNil(refusal("justspeaktoit://open?" + oversized))
        XCTAssertNotNil(refusal("not a link"))
    }

    func testTheSchemeComesFromTheReleaseTrain() throws {
        XCTAssertEqual(
            try DesktopActivationLink.parse("justspeaktoit-alpha://start", scheme: ReleaseTrain.alpha.urlScheme),
            .capture(.start)
        )
        XCTAssertEqual(ReleaseTrain.stable.urlScheme, "justspeaktoit")
    }

    func testFramesRoundTripAndRejectForgeries() throws {
        let link = "justspeaktoit://cloudkit-sign-in?ckWebAuthToken=é"
        let frame = try DesktopActivationFrame.encode(link)
        let header = frame.prefix(DesktopActivationFrame.headerLength)
        let length = try XCTUnwrap(DesktopActivationFrame.bodyLength(ofHeader: Data(header)))
        XCTAssertEqual(length, frame.count - DesktopActivationFrame.headerLength)
        let body = frame.dropFirst(DesktopActivationFrame.headerLength)
        XCTAssertEqual(DesktopActivationFrame.link(fromBody: body), link)

        var wrongMagic = Data(header)
        wrongMagic[0] = UInt8(ascii: "X")
        XCTAssertNil(DesktopActivationFrame.bodyLength(ofHeader: wrongMagic))
        var wrongVersion = Data(header)
        wrongVersion[4] = 2
        XCTAssertNil(DesktopActivationFrame.bodyLength(ofHeader: wrongVersion))
        var oversized = Data(header)
        oversized.replaceSubrange(5..<9, with: [0x00, 0x01, 0x00, 0x00])
        XCTAssertNil(DesktopActivationFrame.bodyLength(ofHeader: oversized))
        XCTAssertNil(DesktopActivationFrame.bodyLength(ofHeader: Data(header.prefix(8))))
        XCTAssertNil(DesktopActivationFrame.link(fromBody: Data([0xFF, 0xFE])))
        XCTAssertThrowsError(
            try DesktopActivationFrame.encode(String(repeating: "a", count: DesktopActivationLink.maximumLength + 1))
        )
    }

    func testTheActivationPipeIsPerUserAndTrain() throws {
        let sid = "S-1-5-21-1-2-3-1001"
        XCTAssertEqual(
            try DesktopActivationEndpoint.pipeName(userSID: sid, environment: [:], train: .stable),
            #"\\.\pipe\JustSpeakToIt-SpeakApp-activation-S-1-5-21-1-2-3-1001"#
        )
        XCTAssertNotEqual(
            try DesktopActivationEndpoint.pipeName(userSID: sid, environment: [:], train: .alpha),
            try DesktopActivationEndpoint.pipeName(userSID: sid, environment: [:], train: .stable)
        )
        XCTAssertNotEqual(
            try DesktopActivationEndpoint.pipeName(userSID: sid, environment: [:], train: .stable),
            try AutomationPipeEndpoint.pipeName(userSID: sid, environment: [:], train: .stable)
        )
        XCTAssertEqual(
            try DesktopActivationEndpoint.pipeName(
                userSID: sid, environment: [DesktopActivationEndpoint.environmentKey: "jsti-test"], train: .stable
            ),
            #"\\.\pipe\jsti-test"#
        )
        XCTAssertThrowsError(try DesktopActivationEndpoint.pipeName(userSID: "not-a-sid", environment: [:]))
        XCTAssertThrowsError(try DesktopActivationEndpoint.pipeName(
            userSID: sid, environment: [DesktopActivationEndpoint.environmentKey: #"\\server\pipe\x"#]
        ))
    }
}
