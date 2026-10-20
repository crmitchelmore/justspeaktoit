import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopVoiceSourceMessageTests: XCTestCase {
    func testNativeMessage_PreservesImmutableSourceAndDistinctOpaqueResultOwnership() throws {
        let history = UUID().uuidString
        let source = try VoiceOutputSourceSnapshot(
            source: .history, text: "Synthetic source.", recordID: UUID(uuidString: history)
        )
        XCTAssertEqual(try DesktopVoiceSourceMessage(
            action: 115, source: 0, text: source.text, record: history, path: "2"
        ), .event(.voiceGenerate(source, options: .init(autoPlay: false, saveToRecordings: true))))
        XCTAssertEqual(try DesktopVoiceSourceMessage(
            action: 116, source: 0, text: "", record: "opaque-result", path: ""
        ), .event(.voiceGeneratedPlay("opaque-result")))
        XCTAssertEqual(try DesktopVoiceSourceMessage(
            action: 113, source: 4, text: "", record: "opaque-import", path: "synthetic.txt"
        ), .event(.voiceImport(path: "synthetic.txt", requestID: "opaque-import")))
        XCTAssertEqual(try DesktopVoiceSourceMessage(
            action: 118, source: 1, text: "", record: "", path: ""
        ), .preferences(.init(autoPlay: true, saveToRecordings: false)))
    }

    func testProviderTransition_StrictSessionEpochAndCanonicalProviderWithoutLegacyRetagging() throws {
        let context = VoiceAccountCredentialContext(provider: .mistral, sessionID: UUID(), epoch: UUID())
        let text = context.provider.id + "\n" + context.epoch.uuidString.lowercased()
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: -1, text: text,
            record: context.sessionID.uuidString.lowercased(), path: "account-provider"), .discoveryProvider(context))
        for invalid in ["mistral", text + "\n", "other\n" + context.epoch.uuidString,
                        "mistral\n{" + context.epoch.uuidString + "}", "mistral\nnot-an-epoch"] {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: -1, text: invalid,
                record: context.sessionID.uuidString, path: "account-provider"))
        }
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: 0, text: text,
            record: context.sessionID.uuidString, path: "account-provider"))
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: -1, text: text,
            record: "legacy-dialog", path: "account-provider"))
    }

    func testModernOpen_RequiresExplicitTagCanonicalSessionAndEmptySourcePayload() throws {
        let session = UUID()
        let record = session.uuidString.lowercased()
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "",
            record: record, path: "account-open-modern"), .discoveryOpenModern(session))
        for invalid in ["", "opaque-dialog", "{" + record + "}", String(record.dropLast()), record + " "] {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "",
                record: invalid, path: "account-open-modern"))
        }
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: 0, text: "",
            record: record, path: "account-open-modern"))
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "unexpected",
            record: record, path: "account-open-modern"))
        for legacy in [record, "{" + record + "}", "opaque-dialog"] {
            XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "",
                record: legacy, path: "account-open"), .discoveryOpen(legacy))
        }
    }

    func testNativeMessage_RejectsUnsupportedSelectionEmptyInputAndInvalidActionsOrOptions() {
        let cases: [InvalidMessage] = [
            .init(action: 110, source: 3, text: "Synthetic external selection", path: ""),
            .init(action: 115, source: 1, text: " ", path: "0"),
            .init(action: 115, source: 1, text: "Synthetic text", path: "4"),
            .init(action: 118, source: 4, text: "", path: ""),
            .init(action: 119, source: 1, text: "Synthetic text", path: "")
        ]
        for message in cases {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(
                action: message.action, source: message.source, text: message.text, record: "", path: message.path
            ))
        }
    }

    private struct InvalidMessage {
        let action: Int32
        let source: Int32
        let text: String
        let path: String
    }

    func testSynthesisPreferences_ValidateControlsAndKeepOpaqueAcknowledgementSeparateFromHistory() throws {
        let options = try VoiceSynthesisOptions(speed: 1.25, pitch: -2, useSSML: true)
        let payload = #"{"speed":1.25,"pitch":-2,"useSSML":true}"#
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 119, source: 0, text: payload,
            record: "opaque-preferences-request", path: ""),
            .synthesisPreferences(options, requestID: "opaque-preferences-request"))
        for speed in [0.25, 4.0] {
            let supported = try VoiceSynthesisOptions(speed: speed, quality: .highest)
            try supported.validate(for: .openai)
            let supportedPayload = #"{"speed":\#(speed),"pitch":0,"useSSML":false,"quality":"highest"}"#
            XCTAssertEqual(try DesktopVoiceSourceMessage(action: 119, source: 0, text: supportedPayload,
                record: "opaque-preferences-request", path: ""),
                .synthesisPreferences(supported, requestID: "opaque-preferences-request"))
        }
        for record in ["", String(repeating: "x", count: 65), "request\n"] {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 119, source: 0,
                text: payload, record: record, path: ""))
        }
        for payload in [
            #"{"speed":4.01,"pitch":0,"useSSML":false}"#,
            #"{"speed":0.24,"pitch":0,"useSSML":false}"#,
            #"{"speed":1,"pitch":0,"useSSML":false,"quality":"future-quality"}"#,
            #"{"speed":1,"pitch":1.5,"useSSML":false}"#,
            #"{"speed":1,"pitch":0,"useSSML":"true"}"#,
            String(repeating: " ", count: 1_025)
        ] {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 119, source: 0,
                text: payload, record: "request", path: ""))
        }
    }

    func testUsageABI_RequiresExactTagsTokensAndBooleanFlags() throws {
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "", record: "fixture",
            path: "usage-report"), .usageReport(text: "", requestID: "fixture"))
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: 0, text: "", record: "fixture",
            path: "usage-tracking"), .usageTracking(false, requestID: "fixture"))
        for source in [-1, 2, 4] {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: Int32(source), text: "",
                record: "fixture", path: "usage-tracking"))
        }
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "",
            record: "", path: "usage-report"))
        XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: 0, text: "",
            record: "fixture", path: "usage-unknown"))
    }

    func testDiscoveryABI_UsesStableIdentifierAndDistinctOpaqueDialogTokens() throws {
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "",
            record: "dialog", path: "account-open"), .discoveryOpen("dialog"))
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "",
            record: "dialog", path: "account-refresh"), .discoveryRefresh("dialog"))
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "",
            record: "dialog", path: "account-close"), .discoveryClose("dialog"))
        XCTAssertEqual(try DesktopVoiceSourceMessage(action: 118, source: -1, text: "xai/Account-A",
            record: "dialog", path: "account-choose"), .discoveryChoose(voiceID: "xai/Account-A", requestID: "dialog"))
        for text in ["xai/", "xai/a\n", "deepgram/a", "xai/" + String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: -1,
                text: text, record: "dialog", path: "account-choose"))
        }
        for path in ["account-open", "account-refresh", "account-close", "account-unknown"] {
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: 0,
                text: "", record: "dialog", path: path))
            XCTAssertThrowsError(try DesktopVoiceSourceMessage(action: 118, source: -1,
                text: "unexpected input", record: "dialog", path: path))
        }
    }
}
