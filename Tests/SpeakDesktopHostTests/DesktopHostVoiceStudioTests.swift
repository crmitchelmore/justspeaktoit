import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostVoiceStudioTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-voice-studio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = StubURLProtocol.makeSession()
        // Unconsented host: local voice studios must never require cloud AI sharing consent.
        controller = try DesktopHostController<FakePlatform>(
            directory: directory,
            effects: SyntheticEffects(),
            shutdownGrace: .milliseconds(60)
        )
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    func testConfigurationAndAPIKeyStayIsolatedInPlatformSecureStore() async throws {
        let unsafeConfig = VoiceStudioConfiguration(
            enabled: true,
            kind: .voicebox,
            baseURLString: "http://remote-voice.example.com:17493"
        )
        do {
            try await controller.saveVoiceStudioConfiguration(unsafeConfig)
            XCTFail("Expected cleartextNonLoopbackDisallowed")
        } catch let error as VoiceStudioError {
            XCTAssertEqual(error, .cleartextNonLoopbackDisallowed(host: "remote-voice.example.com"))
        }

        let secret = "desktop-studio-secret-\(UUID().uuidString)"
        try await controller.saveVoiceStudioAPIKey(secret, for: .voicebox)
        let hasKey = await controller.hasVoiceStudioAPIKey(for: .voicebox)
        XCTAssertTrue(hasKey)
        XCTAssertEqual(FakeLog.shared.key(VoiceStudioKind.voicebox.apiKeyCredentialIdentifier), secret)

        let safeConfig = VoiceStudioConfiguration(
            enabled: true,
            kind: .voicebox,
            baseURLString: "https://remote-voice.example.com"
        )
        try await controller.saveVoiceStudioConfiguration(safeConfig)
        let storedJSON = try String(
            contentsOf: directory.appendingPathComponent("settings.json"),
            encoding: .utf8
        )
        XCTAssertFalse(storedJSON.contains(secret), "Studio API key must never be written into settings.json")
        let loaded = await controller.voiceStudioConfiguration
        XCTAssertEqual(loaded, safeConfig)
    }

    func testConnectionProbeDiscoveryAndAutomationListing() async throws {
        installVoiceboxStub(wavPayload: try Self.makePCM16MonoWAV(sampleRate: 24_000, frames: 960))
        try await controller.saveVoiceStudioConfiguration(VoiceStudioConfiguration(enabled: true, kind: .voicebox))

        let probeResult = await controller.testVoiceStudioConnection(session: session)
        guard case .success(let connection) = probeResult else {
            return XCTFail("Expected studio probe success, got \(probeResult)")
        }
        XCTAssertEqual(connection.studioVersion, "0.5.0")
        XCTAssertEqual(connection.voiceCount, 1)

        let inventory = try await controller.refreshVoiceStudioVoices(session: session)
        let alice = try XCTUnwrap(inventory.desktopVoices.first)
        XCTAssertEqual(alice.id, "studio/voicebox/alice-1")

        await controller.selectVoiceOutput(alice)
        let selection = try await controller.currentVoiceSelection()
        XCTAssertEqual(selection.voice, alice)
        XCTAssertEqual(selection.studioConfiguration?.enabled, true)

        let automationList = try await controller.automationVoices()
        XCTAssertTrue(automationList.contains { $0.id == alice.id && $0.selected })
    }

    func testGenerationSucceedsWithoutCloudConsentAndFailsWhenStopped() async throws {
        installVoiceboxStub(wavPayload: try Self.makePCM16MonoWAV(sampleRate: 24_000, frames: 960))
        try await controller.saveVoiceStudioConfiguration(VoiceStudioConfiguration(enabled: true, kind: .voicebox))
        let inventory = try await controller.refreshVoiceStudioVoices(session: session)
        let alice = try XCTUnwrap(inventory.desktopVoices.first)
        await controller.selectVoiceOutput(alice)

        let snapshot = try VoiceOutputSourceSnapshot(source: .typedText, text: "Desktop host voice studio check.")
        await runGeneration(snapshot: snapshot)
        let retained = await controller.generatedVoice
        XCTAssertEqual(retained?.voice, alice)
        XCTAssertEqual(retained?.audio.sampleRate, 24_000)

        StubURLProtocol.handler = { _ in .fail(URLError(.cannotConnectToHost)) }
        await runGeneration(snapshot: snapshot)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Voicebox isn't running") == true)
    }

    private func installVoiceboxStub(wavPayload: Data) {
        StubURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/health" {
                let data = try JSONSerialization.data(withJSONObject: ["version": "0.5.0"])
                let http = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                ))
                return .respond(http, data)
            }
            if url.path == "/profiles" {
                let data = try JSONSerialization.data(withJSONObject: [
                    ["id": "alice-1", "name": "Alice", "language": "en"]
                ])
                let http = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                ))
                return .respond(http, data)
            }
            if url.path == "/generate" {
                let http = try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"]
                ))
                return .respond(http, wavPayload)
            }
            XCTFail("Unexpected request: \(url.path)")
            return .fail(URLError(.badURL))
        }
    }

    private func runGeneration(snapshot: VoiceOutputSourceSnapshot) async {
        let sessionBox = session!
        await controller.generateVoiceSource(
            snapshot,
            options: .init(autoPlay: false, saveToRecordings: false)
        ) { source, chosen, credential in
            try await DesktopSpeechSynthesis(session: sessionBox).synthesize(
                source, selection: chosen, credential: credential
            )
        }
        let genTask = await controller.voiceGenerationTask
        await genTask?.value
    }

    private static func makePCM16MonoWAV(sampleRate: Int, frames: Int) throws -> Data {
        var pcm = Data(capacity: frames * 2)
        for index in 0..<frames {
            let sample = Int16(sin(Double(index) * 0.25) * 8_000.0)
            var little = UInt16(bitPattern: sample).littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        return try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16))
    }
}
