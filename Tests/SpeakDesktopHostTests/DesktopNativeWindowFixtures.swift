import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

/// What the fake native window received, with borrowed C strings copied.
final class NativeWindowLog: @unchecked Sendable {
    static let shared = NativeWindowLog()
    private let lock = NSLock()
    private var calls: [String] = []
    private var statuses: [String] = []
    private var refusing = false

    /// While true every fake native call reports failure.
    var refuses: Bool {
        get { lock.withLock { refusing } }
        set { lock.withLock { refusing = newValue } }
    }

    func reset() { lock.withLock { calls = []; statuses = []; refusing = false } }
    func record(_ name: String, _ values: [Any?]) -> Int32 {
        lock.withLock {
            calls.append(([name] + values.map(Self.describe)).joined(separator: "|"))
            return refusing ? -1 : 0
        }
    }
    func status(_ status: String) { lock.withLock { statuses.append(status) } }
    var recorded: [String] { lock.withLock { calls } }
    var statusLines: [String] { lock.withLock { statuses } }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case let pointer as UnsafePointer<CChar>: return String(cString: pointer)
        case .some(let value): return "\(value)"
        case .none: return "nil"
        }
    }
}

enum NativeTestPlatform: DesktopNativeWindowPlatform {
    typealias VoiceOutputSettings = DesktopVoiceOutputSettings
    typealias TextOutputOptions = FakeTextOutput
    typealias HotKeySettings = FakeHotKey
    typealias InsertionTarget = String
    typealias OutputJob = FakeJob
    typealias Playback = FakePlayback
    typealias VoiceOutput = FakeVoiceOutput
    typealias ReadAloudState = DesktopHostReadAloudState<FakePlayback.Speech, FakeVoiceOutput>
    static let displayName = "Native test host"
    static var defaultTextOutput: FakeTextOutput { .init() }
    static let credentialStoreName = "the test vault"
    static let deepgramKeyHint = "test key"

    private static var log: NativeWindowLog { .shared }

    static let nativeWindow = DesktopNativeWindowCalls(
        beginCleanupPreview: { 7 },
        cleanupPreview: { log.record("cleanupPreview", [$0, $1]) },
        endCleanupPreview: { _ = log.record("endCleanupPreview", [$0]) },
        setHistoryManagement: { log.record("historyManagement", [$0]) },
        setHUDLayout: { log.record("hud", [$0, $1, $2, $3, $4, $5, $6]) }
    )
    static let nativeComparison = DesktopNativeComparisonCalls(
        presentBatch: { models, _, _, _, busy, _, _, _, _, _, _, _, remaining, _ in
            log.record("comparison", [models, busy, remaining])
        },
        setSaveHistory: { log.record("saveHistory", [$0]) }
    )
    static let nativeVoice = DesktopNativeVoiceCalls(
        setUsage: { log.record("usage", [$0, $1, $2]) },
        setTextImport: { log.record("textImport", [$0, $1, $2]) },
        setGeneratedResult: { log.record("generated", [$0, $1, $2, $3]) },
        setGenerationOptions: { log.record("generationOptions", [$0]) },
        finishSynthesisOptions: { log.record("finishSynthesis", [$0, $1]) }
    )
    static let nativeVoiceAccounts = DesktopNativeVoiceAccountCalls(
        setInventory: { log.record("inventory", [$0, $1, $2, $3, $4, $5]) },
        setProviders: { log.record("providers", [$0, $1, $2, $3, $4]) },
        keys: DesktopNativeVoiceCredentialCalls(
            setCredential: { log.record("credential", [$0, $1, $2, $3, $4, $5, $6, $7]) },
            finishCredential: { log.record("credentialFinished", [$0, $1, $2, $3]) },
            setProviderCredential: { log.record("providerCredential", [$0, $3, $8, $9]) },
            finishProviderCredential: { log.record("providerCredentialFinished", [$0, $3, $4, $5]) }
        )
    )

    static func showVoiceAudioFormats(_ settings: DesktopVoiceOutputSettings, status: String) {
        _ = log.record("audioFormats", [status])
    }
    static func showVoiceControls(_ settings: DesktopVoiceOutputSettings, accountInventory: VoiceAccountInventory?) {
        _ = log.record("voiceControls", [])
    }
    static func update(_ status: String, transcript: String?, state: Int32) { log.status(status) }
    static func recordingState(_ state: Int32) {}
    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {}
    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) {}
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {}
    static func publishModels(status: String, refreshing: Bool) throws {}
    static func apiKey(name: String) throws -> String { "" }
    static func saveAPIKey(_ key: String, name: String) throws {}
    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        FakePlatform.uploadStaging(directory: directory)
    }
    static func preparePrivateDirectory(_ directory: URL) throws { try FakePlatform.preparePrivateDirectory(directory) }
    static func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        throw DesktopHostError(message: "No conversion in native window tests.")
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
}

struct NativeTestEffects: DesktopHostEffects {
    typealias Platform = NativeTestPlatform
    func apiKey(name: String) throws -> String { "" }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { throw DesktopHostError(message: "No capture in native window tests.") }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<Platform>
    ) async throws -> TranscriptionResult { throw DesktopHostError(message: "No transcription in native tests.") }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        DesktopTextOutputResult(.confirmedInsertion, status: "Synthetic output.")
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

/// A window event holder whose settings queue runs in order on demand.
final class NativeTestHolder: DesktopNativeEventHolder, @unchecked Sendable {
    let controller: DesktopHostController<NativeTestPlatform>
    private let lock = NSLock()
    private var queued: [@Sendable () async -> Void] = []
    private var history: [DesktopHistoryEvent] = []

    init(controller: DesktopHostController<NativeTestPlatform>) { self.controller = controller }

    func enqueueSettings(_ action: @escaping @Sendable () async -> Void) { lock.withLock { queued.append(action) } }
    func submitHistoryPlayback(_ event: DesktopHistoryEvent) { lock.withLock { history.append(event) } }

    /// Fails every preferences action, as an unreadable import does.
    func performConfigurationAction(_ action: Int32, values: [String], editorID: String?) async throws {
        _ = NativeWindowLog.shared.record("perform", [action])
        throw DesktopHostError(message: "Import failed.")
    }
    func configureConfiguration() async throws { _ = NativeWindowLog.shared.record("redisplay", []) }

    var queuedCount: Int { lock.withLock { queued.count } }
    var historyEvents: [DesktopHistoryEvent] { lock.withLock { history } }

    func drainSettings() async {
        let actions = lock.withLock { () -> [@Sendable () async -> Void] in
            defer { queued = [] }
            return queued
        }
        for action in actions { await action() }
    }
}
