#if DEBUG
import Foundation
import SpeakCore

/// A fixed synthetic PCM recording, not microphone input or speech recognition.
/// The HTTP fixture accepts only these exact bytes after production serialization.
enum CoreJourneyBatchFixture {
    static let model = "core-journey/batch-fixture"
    static let transcript = "A complete batch journey, through the clipboard."
    static let duration: TimeInterval = 0.25
    static let audioData: Data = {
        let sampleCount = 4_000
        var data = Data("RIFF".utf8)
        append(UInt32(36 + sampleCount * 2), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(16_000), to: &data)
        append(UInt32(32_000), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(sampleCount * 2), to: &data)
        for index in 0..<sampleCount {
            append(Int16(index % 40 < 20 ? 1_000 : -1_000), to: &data)
        }
        return data
    }()

    private static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    static func makeClient() -> OpenRouterAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoreJourneyBatchURLProtocol.self]
        configuration.urlCache = nil
        return OpenRouterAPIClient(
            apiKeyProvider: { "core-journey-fixture-not-a-real-key" },
            session: URLSession(configuration: configuration)
        )
    }
}

actor CoreJourneyRecordingSource: RecordingCaptureSource {
    private var recording: RecordingSummary?

    func start(in directory: URL) throws -> RecordingStart {
        guard recording == nil else { throw AudioFileManagerError.alreadyRecording }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = UUID()
        let url = directory.appendingPathComponent("Recording-\(identifier.uuidString).wav")
        try CoreJourneyBatchFixture.audioData.write(to: url, options: .atomic)
        recording = RecordingSummary(
            id: identifier, url: url, startedAt: Date(), duration: CoreJourneyBatchFixture.duration,
            fileSize: Int64(CoreJourneyBatchFixture.audioData.count)
        )
        return RecordingStart(url: url, usedWarmRecorder: false)
    }

    func stop() throws -> RecordingSummary {
        guard let recording else { throw AudioFileManagerError.noActiveRecording }
        self.recording = nil
        return recording
    }

    func cancel(deleteFile: Bool) {
        if deleteFile, let recording { try? FileManager.default.removeItem(at: recording.url) }
        recording = nil
    }
}

/// Intercepts every request on the fixture session, including unexpected hosts,
/// so an incorrectly routed request fails closed instead of reaching the network.
final class CoreJourneyBatchURLProtocol: URLProtocol, @unchecked Sendable {
    private static let diagnostics = CoreJourneyBatchHTTPDiagnostics()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let accepted = Self.accepts(request)
        Self.diagnostics.record(accepted: accepted)
        guard accepted, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let payload: [String: Any] = [
            "id": "core-journey-response", "model": CoreJourneyBatchFixture.model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": CoreJourneyBatchFixture.transcript]]]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func accepts(_ request: URLRequest) -> Bool {
        guard request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions",
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer core-journey-fixture-not-a-real-key",
              let body = body(of: request),
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              payload["model"] as? String == CoreJourneyBatchFixture.model,
              payload["stream"] as? Bool == false,
              let messages = payload["messages"] as? [[String: Any]], messages.count == 1,
              let content = messages.first?["content"] as? [[String: Any]] else { return false }
        let audio = content.filter { $0["type"] as? String == "input_audio" }
        guard audio.count == 1, let input = audio.first?["input_audio"] as? [String: String],
              input["format"] == "wav", let encoded = input["data"] else { return false }
        return Data(base64Encoded: encoded) == CoreJourneyBatchFixture.audioData
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= 64 * 1_024 {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }
}

private final class CoreJourneyBatchHTTPDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptedRequests = 0
    private var rejectedRequests = 0

    func record(accepted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if accepted { acceptedRequests += 1 } else { rejectedRequests += 1 }
        guard let rawID = ProcessInfo.processInfo.environment[CoreJourneyLaunchProfile.environmentKey],
              let identifier = UUID(uuidString: rawID) else {
            preconditionFailure("Batch HTTP fixture requires an isolated launch profile")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.justspeaktoit.tests.core-journey.\(identifier.uuidString)")
        let payload = ["acceptedRequests": acceptedRequests, "rejectedRequests": rejectedRequests]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: directory.appendingPathComponent("batch-http.json"), options: .atomic)
        } catch {
            preconditionFailure("Cannot persist batch HTTP diagnostics: \(error.localizedDescription)")
        }
    }
}
#endif
