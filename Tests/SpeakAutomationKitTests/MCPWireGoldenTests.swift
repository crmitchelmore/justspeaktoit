import SpeakCore
import XCTest
@testable import SpeakAutomationKit

#if canImport(Darwin)
/// Byte-for-byte MCP replies. Agents parse these lines, so the JSON-RPC envelope
/// types must keep every key, number spelling and escape the server has always
/// written: sorted keys, escaped slashes, 17-digit doubles and integer ids.
/// The spelling is Apple Foundation's; other platforms' writers differ in places,
/// and `MCPServerBehaviourTests` covers the same replies structurally there.
final class MCPWireGoldenTests: XCTestCase {
    private let handler: MCPRequestHandler = {
        let entry = AutomationHistoryEntry(
            id: "e/1", text: #"héllo "q" / ok"#, createdAt: Date(timeIntervalSince1970: 1_700_000_000.25),
            model: "nova-3", durationSeconds: 0.1, wordCount: 1
        )
        var result = AutomationResult(
            text: "agent ready / é", model: "nova-3", durationSeconds: 12.34, sessionActive: true,
            appVersion: "1.0", entries: [entry]
        )
        result.entry = entry
        result.captureID = "C"
        return MCPRequestHandler(client: StubAutomationClient(result: result), version: "9.9.9")
    }()

    private func assertReply(
        _ request: String, _ expected: String?, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(self.handler.handle(line: request), expected, request, file: file, line: line)
    }

    func testInitializeAndToolsList_keepTheirBytes() {
        self.assertReply(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{"listChanged":false}},"instructions":"Dic"#
            + #"tation and transcription tools backed by the running Just Speak To It app. The app owns provider cre"#
            + #"dentials; this server never sees them.","protocolVersion":"2025-06-18","serverInfo":{"name":"justspe"#
            + #"aktoit","version":"9.9.9"}}}"#
        )
        self.assertReply(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"id":2,"jsonrpc":"2.0","result":{"tools":[{"description":"Await an identified active local Mac capt"#
            + #"ure. No recording start or phone\/Watch sync.","inputSchema":{"properties":{"capture_id":{"format":""#
            + #"uuid","type":"string"},"since_id":{"format":"uuid","type":"string"},"timeout_seconds":{"exclusiveMin"#
            + #"imum":0,"maximum":600,"type":"number"}},"required":["capture_id"],"type":"object"},"name":"await_tra"#
            + #"nscript"},{"description":"Report app status and the active local capture identity, when present.","i"#
            + #"nputSchema":{"properties":{},"type":"object"},"name":"status"},{"description":"Transcribe a local au"#
            + #"dio file using the user's configured provider.","inputSchema":{"properties":{"path":{"description":""#
            + #"Absolute path to an audio file.","type":"string"},"timeout_seconds":{"description":"Deadline in seco"#
            + #"nds.","type":"number"}},"required":["path"],"type":"object"},"name":"transcribe_file"},{"description"#
            + #"":"Return the most recent transcriptions, newest first.","inputSchema":{"properties":{"limit":{"desc"#
            + #"ription":"How many entries to return (default 10).","maximum":200,"minimum":1,"type":"integer"}},"ty"#
            + #"pe":"object"},"name":"get_history"},{"description":"Start a dictation session in the app. Idempotent"#
            + #" per call id.","inputSchema":{"properties":{},"type":"object"},"name":"start_dictation"},{"descripti"#
            + #"on":"Stop the active dictation session and return its transcript.","inputSchema":{"properties":{},"t"#
            + #"ype":"object"},"name":"stop_dictation"},{"description":"Speak text aloud with the app's voices, or s"#
            + #"ave it as an audio file. Returns once playback finishes and the file is complete.","inputSchema":{"p"#
            + #"roperties":{"language":{"description":"automatic or a voice language ID, e.g. en-US.","type":"string"#
            + #""},"model":{"description":"Model ID from list_voices.","type":"string"},"path":{"description":"Audio"#
            + #" file to write (.wav, .mp3 or .m4a).","type":"string"},"pitch":{"description":"Semitones; only voice"#
            + #"s with pitch control accept it.","maximum":12,"minimum":-12,"type":"integer"},"play":{"description":"#
            + #""Play aloud. Defaults to true without a path.","type":"boolean"},"provider":{"description":"Provider"#
            + #" ID or name from list_voices.","type":"string"},"quality":{"enum":["standard","high","highest"],"typ"#
            + #"e":"string"},"speed":{"description":"Speaking rate; 1 is normal. Checked against the voice.","maximu"#
            + #"m":4,"minimum":0.25,"type":"number"},"text":{"description":"The text to speak.","maxLength":100000,""#
            + #"type":"string"},"timeout_seconds":{"description":"Deadline in seconds.","type":"number"},"voice":{"d"#
            + #"escription":"Voice ID or name from list_voices; omit for the app's selected voice, \"system\" for th"#
            + #"e on-device voice.","type":"string"}},"required":["text"],"type":"object"},"name":"speak_text"},{"de"#
            + #"scription":"List the providers, voices and models speak_text can use: the app's selected voice, conf"#
            + #"igured cloud voices and on-device voices.","inputSchema":{"properties":{"provider":{"description":"O"#
            + #"nly this provider's voices.","type":"string"}},"type":"object"},"name":"list_voices"},{"description""#
            + #":"Read the app's settings with their schema (type, default, allowed values, range, platforms). API k"#
            + #"eys report only whether they are set; secrets are never returned. Needs automation turned on in the "#
            + #"app.","inputSchema":{"properties":{"keys":{"description":"Only these setting keys.","items":{"type":"#
            + #""string"},"maxItems":256,"type":"array"},"prefix":{"description":"Only setting keys starting with th"#
            + #"is prefix.","type":"string"}},"type":"object"},"name":"get_configuration"},{"description":"Change on"#
            + #"e or more settings at once. Every change is validated against the schema and applied all together or"#
            + #" not at all. dry_run only validates. Writes also need \"Allow automation to change settings\" turned"#
            + #" on in the app.","inputSchema":{"properties":{"changes":{"description":"Setting key to new value, e."#
            + #"g. {\"ttsSpeed\": 1.2}. Use get_configuration for keys and allowed values.","type":"object"},"dry_ru"#
            + #"n":{"description":"Validate without changing anything.","type":"boolean"}},"required":["changes"],"t"#
            + #"ype":"object"},"name":"set_configuration"}]}}"#
        )
    }

    /// Ids are echoed with the JSON type they arrived with on every platform.
    func testPingIDs_areEchoedWithTheirJSONType() {
        let cases: [(id: String, reply: String)] = [
            (#"0"#, #"{"id":0,"jsonrpc":"2.0","result":{}}"#),
            (#"1"#, #"{"id":1,"jsonrpc":"2.0","result":{}}"#),
            (#"1.5"#, #"{"id":1.5,"jsonrpc":"2.0","result":{}}"#),
            (#"0.1"#, #"{"id":0.10000000000000001,"jsonrpc":"2.0","result":{}}"#),
            (#"1.0"#, #"{"id":1,"jsonrpc":"2.0","result":{}}"#),
            (#"1e2"#, #"{"id":100,"jsonrpc":"2.0","result":{}}"#),
            (#"18446744073709551615"#, #"{"id":18446744073709551615,"jsonrpc":"2.0","result":{}}"#),
            (#"18446744073709551616"#, #"{"id":1.8446744073709552e+19,"jsonrpc":"2.0","result":{}}"#),
            (#"null"#, #"{"id":null,"jsonrpc":"2.0","result":{}}"#),
            (#"[1]"#, #"{"id":null,"jsonrpc":"2.0","result":{}}"#),
            (#"true"#, #"{"id":1,"jsonrpc":"2.0","result":{}}"#)
        ]
        for (id, reply) in cases {
            self.assertReply(#"{"jsonrpc":"2.0","id":"# + id + #","method":"ping"}"#, reply)
        }
    }

    func testToolResults_keepTheirBytes() {
        self.assertReply(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"transcribe_file","arguments":{"path""#
            + #":"/x.wav"}}}"#,
            #"{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"agent ready \/ é","type":"text"}],"isError":fa"#
            + #"lse,"structuredContent":{"appVersion":"1.0","captureID":"C","durationSeconds":12.34,"entries":[{"cre"#
            + #"atedAt":"2023-11-14T22:13:20Z","durationSeconds":0.10000000000000001,"id":"e\/1","model":"nova-3","t"#
            + #"ext":"héllo \"q\" \/ ok","wordCount":1}],"entry":{"createdAt":"2023-11-14T22:13:20Z","durationSecond"#
            + #"s":0.10000000000000001,"id":"e\/1","model":"nova-3","text":"héllo \"q\" \/ ok","wordCount":1},"model"#
            + #"":"nova-3","sessionActive":true,"text":"agent ready \/ é"}}}"#
        )
        self.assertReply(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_history","arguments":{"limit":10"#
            + #"0000}}}"#,
            #"{"id":3,"jsonrpc":"2.0","result":{"content":[{"text":"invalid_argument: get_history limit must be be"#
            + #"tween 1 and 200.","type":"text"}],"isError":true}}"#
        )
    }

    func testProtocolErrorsAndNotifications_keepTheirBytes() {
        self.assertReply(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rm_rf"}}"#,
            #"{"error":{"code":-32602,"message":"Unknown tool: rm_rf."},"id":3,"jsonrpc":"2.0"}"#
        )
        self.assertReply(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":[]}"#,
            #"{"error":{"code":-32602,"message":"tools\/call requires a \"name\"."},"id":3,"jsonrpc":"2.0"}"#
        )
        self.assertReply(
            #"{"jsonrpc":"2.0","id":1.5,"method":"tools/call","params":{"name":"await_transcript","arguments":{"ca"#
            + #"pture_id":"x"}}}"#,
            #"{"error":{"code":-32600,"message":"Await requires a string or 64-bit integer JSON-RPC ID."},"id":nul"#
            + #"l,"jsonrpc":"2.0"}"#
        )
        self.assertReply(
            #"{"jsonrpc":"2.0","id":3,"method":5}"#,
            #"{"error":{"code":-32600,"message":"Invalid request: missing \"method\"."},"id":3,"jsonrpc":"2.0"}"#
        )
        self.assertReply(
            #"{"jsonrpc":"2.0","id":3,"method":"a/b/é"}"#,
            #"{"error":{"code":-32601,"message":"Method not found: a\/b\/é."},"id":3,"jsonrpc":"2.0"}"#
        )
        self.assertReply(
            #"{"jsonrpc":"2.0","id":3,"method":"ping","id":4}"#,
            #"{"id":3,"jsonrpc":"2.0","result":{}}"#
        )
        self.assertReply(
            #"[1,2]"#,
            #"{"error":{"code":-32700,"message":"Parse error: invalid JSON."},"id":null,"jsonrpc":"2.0"}"#
        )
        self.assertReply(
            #"{not json"#,
            #"{"error":{"code":-32700,"message":"Parse error: invalid JSON."},"id":null,"jsonrpc":"2.0"}"#
        )
        self.assertReply(
            #"{"jsonrpc":"2.0","method":"ping"}"#,
            nil
        )
    }
}
#endif
