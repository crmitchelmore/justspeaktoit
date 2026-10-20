import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

actor VoiceFormatGate {
    private var open = false
    private var entered = false
    private var work: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let pending = observers; observers = []; pending.forEach { $0.resume() }
        if open { return }
        await withCheckedContinuation { work = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() { open = true; work?.resume(); work = nil }
}

final class VoiceFormatProbe: @unchecked Sendable {
    static let shared = VoiceFormatProbe()
    private let lock = NSLock()
    private var checks = 0, conversions = 0, credentials = 0, requests = 0
    private var unsupported = false
    private var encodingFailure = false
    private var held: VoiceFormatGate?
    private var availability: VoiceFormatGate?
    private var presentation: DesktopVoiceResultPresentation?
    var lastPresentation: DesktopVoiceResultPresentation? { lock.withLock { presentation } }
    func show(_ value: DesktopVoiceResultPresentation) { lock.withLock { presentation = value } }
    var counts: [Int] { lock.withLock { [checks, conversions, credentials, requests] } }
    func reset() { lock.withLock { checks = 0; conversions = 0; credentials = 0; requests = 0
        unsupported = false; encodingFailure = false; held = nil; availability = nil; presentation = nil } }
    func refuse(_ value: Bool) { lock.withLock { unsupported = value } }
    func hold(_ gate: VoiceFormatGate?) { lock.withLock { held = gate } }
    func holdAvailability(_ gate: VoiceFormatGate) { lock.withLock { availability = gate } }
    func failConversion() { lock.withLock { encodingFailure = true } }
    func key() -> String { lock.withLock { credentials += 1 }; return "synthetic-format-key" }
    func request() { lock.withLock { requests += 1 } }
    func check() async throws {
        let (refused, gate) = lock.withLock { checks += 1; return (unsupported, availability) }
        if let gate { await gate.wait() }
        if refused { throw VoiceAudioFormatError.unavailable("Synthetic installed codec unavailable; choose WAV.") }
    }
    func encode(_ audio: VoiceGeneratedAudio, format: VoiceAudioFormat) async throws -> VoiceGeneratedAudio {
        let gate = lock.withLock { conversions += 1; return held }
        if let gate { await gate.wait() }
        if lock.withLock({ encodingFailure }) {
            throw VoiceAudioFormatError.unavailable("Synthetic native codec failure.")
        }
        // Deliberately ignores cancellation: the real Host ticket must fence this late result.
        return try encoded(audio, format: format)
    }
    func encoded(_ audio: VoiceGeneratedAudio, format: VoiceAudioFormat) throws -> VoiceGeneratedAudio {
        if format == .wav { return audio }
        let bytes: Data
        if format == .mp3 {
            // Container-shaped synthetic fake, not proof of an executable MP3 encoder.
            bytes = Data([0xFF, 0xF3, 0x90, 0, 1, 2, 3, 4])
        } else {
            bytes = box("ftyp", Data("M4A ".utf8)) + box("moov", Data([1])) + box("mdat", Data([2, 3]))
        }
        return try VoiceGeneratedAudio(encoded: bytes, format: format, decodedWAV: audio.wav,
                                       sampleRate: audio.sampleRate)
    }
    private func box(_ kind: String, _ payload: Data) -> Data {
        Data([0, 0, 0, UInt8(payload.count + 8)]) + Data(kind.utf8) + payload
    }
}

enum VoiceFormatPlatform: DesktopHostReadAloudPlatform {
    typealias VoiceOutputSettings = DesktopVoiceOutputSettings
    typealias TextOutputOptions = FakeTextOutput
    typealias HotKeySettings = FakeHotKey
    typealias InsertionTarget = String
    typealias OutputJob = FakeJob
    typealias Playback = FakePlayback
    typealias VoiceOutput = FakeVoiceOutput
    typealias ReadAloudState = DesktopHostReadAloudState<FakePlayback.Speech, FakeVoiceOutput>
    static let displayName = "Synthetic format host"
    static var defaultTextOutput: FakeTextOutput { .init() }
    static let credentialStoreName = "synthetic vault"
    static let deepgramKeyHint = "synthetic key"
    static var voiceConfigurationKeys: Set<String> { DesktopConfiguration.voiceTransferKeys }
    static func exportVoiceConfiguration(
        _ voiceOutput: VoiceOutputSettings?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration { try VoiceOutputSettings.exportConfiguration(voiceOutput, over: configuration) }
    static func importVoiceConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout VoiceOutputSettings?
    ) throws -> DesktopConfiguration {
        try VoiceOutputSettings.importConfiguration(from: configuration, into: &voiceOutput)
    }
    static func update(_ status: String, transcript: String?, state: Int32) {
        FakePlatform.update(status, transcript: transcript, state: state)
    }
    static func recordingState(_ state: Int32) {}
    static func voiceGenerated(_ value: DesktopVoiceResultPresentation) { VoiceFormatProbe.shared.show(value) }
    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {}
    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) {}
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {}
    static func publishModels(status: String, refreshing: Bool) throws {}
    static func apiKey(name: String) throws -> String { VoiceFormatProbe.shared.key() }
    static func saveAPIKey(_ key: String, name: String) throws {}
    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        FakePlatform.uploadStaging(directory: directory)
    }
    static func preparePrivateDirectory(_ directory: URL) throws { try FakePlatform.preparePrivateDirectory(directory) }
    static func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        throw DesktopHostError(message: "No transcription conversion in format tests.")
    }
    static func openFile(_ url: URL) throws {}
    static func copyToClipboard(_ text: String) throws {}
    static func makeOutputJob(options: FakeTextOutput, target: String?) -> FakeJob? { nil }
    static func requiresInsertionTarget(_ options: FakeTextOutput) -> Bool { false }
    static func cancel(_ job: FakeJob) {}
    static func isClipboard(_ job: FakeJob) -> Bool { false }
    static func makePlayback() -> FakePlayback { FakePlayback() }
    static var defaultHotKey: FakeHotKey { FakeHotKey() }
    static func readyHint(_ hotKey: FakeHotKey) -> String { "" }
    static func finishHint(_ hotKey: FakeHotKey, for trigger: HotKeySessionTrigger) -> String { "" }
    static func makeVoiceOutput(stagingDirectory: URL) throws -> FakeVoiceOutput { FakeVoiceOutput() }
    static func requireVoiceAudioFormat(_ format: VoiceAudioFormat, sampleRate: Int) async throws {
        if format != .wav { try await VoiceFormatProbe.shared.check() }
    }
    static func encodeVoiceAudio(
        _ audio: VoiceGeneratedAudio, format: VoiceAudioFormat
    ) async throws -> VoiceGeneratedAudio {
        if format == .wav { return audio }
        return try await VoiceFormatProbe.shared.encode(audio, format: format)
    }
}

struct VoiceFormatEffects: DesktopHostEffects {
    typealias Platform = VoiceFormatPlatform
    func apiKey(name: String) throws -> String { VoiceFormatProbe.shared.key() }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { throw DesktopHostError(message: "No capture in format tests.") }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<Platform>
    ) async throws -> TranscriptionResult { throw DesktopHostError(message: "No transcription in format tests.") }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        DesktopTextOutputResult(.confirmedInsertion, status: "Synthetic output.")
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}
