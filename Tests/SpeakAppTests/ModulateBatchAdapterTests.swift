import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakApp

final class ModulateBatchAdapterTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testAppleAdapterReadsChangedPersistedFeaturesForEveryRequest() async throws {
        let suite = "ModulateBatchAdapter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // Preserve the existing native provider's suite-identity contract.
        defaults.setVolatileDomain(["test": true], forName: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.removeVolatileDomain(forName: suite)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("fixture.wav")
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0]), sampleRate: 16_000)).write(to: audio)
        let uploads = root.appendingPathComponent("uploads")
        let provider = ModulateTranscriptionProvider(
            session: StubURLProtocol.makeSession(), defaults: defaults,
            multipartStaging: MultipartUploadStaging(directory: uploads)
        )
        for diarization in [false, true] {
            defaults.set(diarization, forKey: AppSettings.DefaultsKey.modulateSpeakerDiarization.rawValue)
            defaults.set(true, forKey: AppSettings.DefaultsKey.modulateEmotionSignal.rawValue)
            StubURLProtocol.handler = { request in
                XCTAssertNil(request.httpBody)
                let files = try FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: nil)
                let body = try Data(contentsOf: XCTUnwrap(files.first))
                let flag = "name=\"speaker_diarization\"\r\n\r\n\(diarization ? "true" : "false")\r\n"
                XCTAssertNotNil(body.range(of: Data(flag.utf8)))
                XCTAssertNotNil(body.range(of: Data("name=\"emotion_signal\"\r\n\r\ntrue\r\n".utf8)))
                return .ok(Data(Self.response.utf8), url: request.url!)
            }
            let result = try await provider.transcribeFile(
                at: audio, apiKey: "fixture-key", model: "modulate/velma-2-stt-batch", language: nil
            )
            XCTAssertEqual(result.text, diarization ? "Speaker 1: Hello\nSpeaker 2: world" : "Hello world")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: uploads.path), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        }
        XCTAssertEqual(provider.supportedModels(), ModelCatalog.batchTranscriptionOptions(forProvider: "modulate"))
    }

    private static let response = #"""
    {"text":"Hello world","duration_ms":1000,"utterances":[
      {"text":"Hello","start_ms":0,"duration_ms":500,"speaker":1,"language":"en"},
      {"text":"world","start_ms":500,"duration_ms":500,"speaker":2,"language":"en"}]}
    """#
}
