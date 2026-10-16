import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

actor VoicePronunciationGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

final class VoicePronunciationProbe: @unchecked Sendable {
    struct Call: Sendable {
        let source: VoiceOutputSourceSnapshot
        let selection: DesktopSpeechSelection
    }
    static let shared = VoicePronunciationProbe()
    private let lock = NSLock()
    private var requests: [Call] = []
    private var slots: [String] = []
    private var handler: (@Sendable (Call) async throws -> Data)?

    var calls: [Call] { lock.withLock { requests } }
    var keys: [String] { lock.withLock { slots } }

    func reset() { lock.withLock { requests = []; slots = []; handler = nil } }
    func readKey(_ name: String) { lock.withLock { slots.append(name) } }
    func install(_ action: @escaping @Sendable (Call) async throws -> Data) {
        lock.withLock { handler = action }
    }

    func synthesize(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        let key = try await credential()
        XCTAssertEqual(key, "synthetic-pronunciation-key")
        try Task.checkCancellation()
        let call = Call(source: source, selection: selection)
        let action = lock.withLock { requests.append(call); return handler }
        let capture = VoiceSynthesisUsage.capture
        let ticket = capture?.begin(
            voice: selection.voice, inputCharacters: source.text.unicodeScalars.count,
            usesSSML: selection.options.useSSML)
        do {
            let wav: Data
            if let action { wav = try await action(call) } else {
                wav = try Self.audio(rate: selection.sampleRate)
            }
            try Task.checkCancellation()
            if let ticket { capture?.finish(ticket, outcome: .completed, audioDuration: 0.01) }
            return wav
        } catch {
            if let ticket { capture?.finish(ticket, outcome: error is CancellationError ? .cancelled : .failed) }
            throw error
        }
    }

    static func audio(rate: Int = 24_000) throws -> Data {
        try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: rate / 50), sampleRate: rate))
    }
}

// A dedicated recording boundary observes the actual generic Read request
// without changing the incumbent fake platform or any other owner's fixture.
enum PronunciationVoicePlatform: DesktopHostReadAloudPlatform {
    typealias VoiceOutputSettings = DesktopVoiceOutputSettings
    typealias TextOutputOptions = FakeTextOutput
    typealias HotKeySettings = FakeHotKey
    typealias InsertionTarget = String
    typealias OutputJob = FakeJob
    typealias Playback = FakePlayback
    typealias VoiceOutput = FakeVoiceOutput
    typealias ReadAloudState = DesktopHostReadAloudState<FakePlayback.Speech, FakeVoiceOutput>

    static let displayName = "Synthetic pronunciation host"
    static let credentialStoreName = "synthetic vault"
    static let deepgramKeyHint = "synthetic key"
    static var voiceConfigurationKeys: Set<String> { DesktopConfiguration.voiceTransferKeys }
    static func exportVoiceConfiguration(
        _ voiceOutput: VoiceOutputSettings?, over configuration: DesktopConfiguration
    ) throws -> DesktopConfiguration {
        try VoiceOutputSettings.exportConfiguration(voiceOutput, over: configuration)
    }
    static func importVoiceConfiguration(
        from configuration: DesktopConfiguration, into voiceOutput: inout VoiceOutputSettings?
    ) throws -> DesktopConfiguration {
        try VoiceOutputSettings.importConfiguration(from: configuration, into: &voiceOutput)
    }
    static func update(_ status: String, transcript: String?, state: Int32) {
        FakePlatform.update(status, transcript: transcript, state: state)
    }
    static func recordingState(_ state: Int32) {}
    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {}
    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) {}
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {}
    static func publishModels(status: String, refreshing: Bool) throws {}
    static func apiKey(name: String) throws -> String { try FakePlatform.apiKey(name: name) }
    static func saveAPIKey(_ key: String, name: String) throws { try FakePlatform.saveAPIKey(key, name: name) }
    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        FakePlatform.uploadStaging(directory: directory)
    }
    static func preparePrivateDirectory(_ directory: URL) throws { try FakePlatform.preparePrivateDirectory(directory) }
    static func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        throw DesktopHostError(message: "No converter in pronunciation tests.")
    }
    static func openFile(_ url: URL) throws {}
    static func copyToClipboard(_ text: String) throws { try FakePlatform.copyToClipboard(text) }
    static func makeOutputJob(options: FakeTextOutput, target: String?) -> FakeJob? { nil }
    static func requiresInsertionTarget(_ options: FakeTextOutput) -> Bool { false }
    static func cancel(_ job: FakeJob) {}
    static func isClipboard(_ job: FakeJob) -> Bool { false }
    static func makePlayback() -> FakePlayback { FakePlayback() }
    static var defaultHotKey: FakeHotKey { FakeHotKey() }
    static func readyHint(_ hotKey: FakeHotKey) -> String { "" }
    static func finishHint(_ hotKey: FakeHotKey, for trigger: HotKeySessionTrigger) -> String { "" }
    static func makeVoiceOutput(stagingDirectory: URL) throws -> FakeVoiceOutput { FakeVoiceOutput() }
    static func synthesizeVoiceOutput(
        _ source: VoiceOutputSourceSnapshot, selection: DesktopSpeechSelection,
        credential: @Sendable () async throws -> String
    ) async throws -> Data {
        try await VoicePronunciationProbe.shared.synthesize(source, selection: selection, credential: credential)
    }
}

struct VoicePronunciationEffects: DesktopHostEffects {
    typealias Platform = PronunciationVoicePlatform
    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        throw DesktopHostError(message: "No capture in pronunciation tests.")
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<Platform>
    ) async throws -> TranscriptionResult {
        throw DesktopHostError(message: "No transcription in pronunciation tests.")
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        DesktopTextOutputResult(.confirmedInsertion, status: "Synthetic output.")
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

extension DesktopHostController where Platform == PronunciationVoicePlatform {
    func installPronunciationLoad(_ task: Task<DesktopVocabulary, Error>?) { vocabularyLoad = task }

    func installPronunciationHistory(_ record: DesktopRecordingStore.Record) async throws {
        try await store.save(record)
        history[record.id] = record
        selectedHistoryID = record.id
    }
}
