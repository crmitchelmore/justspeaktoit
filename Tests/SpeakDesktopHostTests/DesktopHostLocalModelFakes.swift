import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// A local-model platform for DesktopHostLocalModelsTests: presenter, runtime,
// digest and transport stand-ins with no window, disk digest, network or
// speech runtime.

/// What the fake Local models presenter showed, and the platform's switches.
final class FakeLocalState: @unchecked Sendable {
    static let shared = FakeLocalState()
    private let lock = NSLock()
    private var shown: [[DesktopHostLocalModelRow]] = []
    private var shownStatus = ""
    private var shownGPU = true
    private var missing: String?
    private var openFailure: String?
    private var digest = ""
    private var hashes = 0
    private var transportValue: any LocalModelDownloadTransport = HeldTransport()
    let runtime = FakeRuntime()

    func reset() {
        lock.withLock {
            shown = []
            shownStatus = ""
            shownGPU = true
            missing = nil
            openFailure = nil
            digest = ""
            hashes = 0
            transportValue = HeldTransport()
        }
        runtime.reset()
    }

    var rows: [DesktopHostLocalModelRow] { lock.withLock { shown.last ?? [] } }
    var status: String { lock.withLock { shownStatus } }
    var useGPU: Bool { lock.withLock { shownGPU } }
    var runtimeMissing: String? {
        get { lock.withLock { missing } }
        set { lock.withLock { missing = newValue } }
    }
    var runtimeOpenFailure: String? {
        get { lock.withLock { openFailure } }
        set { lock.withLock { openFailure = newValue } }
    }
    /// The digest the stand-in hasher reports for whatever it reads.
    var pinnedDigest: String {
        get { lock.withLock { digest } }
        set { lock.withLock { digest = newValue } }
    }
    /// How many files the stand-in SHA-256 has hashed.
    var hashCount: Int { lock.withLock { hashes } }
    func countHash() { lock.withLock { hashes += 1 } }
    var transport: any LocalModelDownloadTransport {
        get { lock.withLock { transportValue } }
        set { lock.withLock { transportValue = newValue } }
    }

    func present(_ rows: [DesktopHostLocalModelRow], status: String, useGPU: Bool) {
        lock.withLock {
            shown.append(rows)
            shownStatus = status
            shownGPU = useGPU
        }
    }
}

/// Recognises with fixed text after an optional gate; records released paths.
final class FakeRuntime: DesktopHostLocalRuntime, @unchecked Sendable {
    let description = "fake whisper.cpp; CPU"
    private var gate = Gate(open: true)
    private let lock = NSLock()
    private var released: [String] = []
    private var arrivals = 0

    func reset() {
        lock.withLock {
            released = []
            arrivals = 0
            gate = Gate(open: true)
        }
    }

    func hold() { lock.withLock { gate = Gate(open: false) } }
    func release() { lock.withLock { gate }.release() }
    var recognitions: Int { lock.withLock { arrivals } }
    var releasedPaths: [String] { lock.withLock { released } }

    var recognizer: any DesktopLocalRecognizer { FakeRecognizer(runtime: self) }

    func releaseModel(loadedFrom modelFile: URL) -> Bool {
        lock.withLock { released.append(modelFile.path) }
        return true
    }

    fileprivate func arrive() -> Gate {
        lock.withLock {
            arrivals += 1
            return gate
        }
    }
}

struct FakeRecognizer: DesktopLocalRecognizer {
    let runtime: FakeRuntime

    func transcribe(
        samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
    ) async throws -> String {
        await runtime.arrive().pass()
        try Task.checkCancellation()
        return "  Local words   from \(model.displayName). "
    }
}

/// Stands in for the platform SHA-256 over the zero bytes `HeldTransport`
/// serves: reports the pinned digest it is given, or another one once it sees
/// a byte that is not zero. Counts every file it hashes.
private final class PinnedDigest: LocalModelSHA256Hasher {
    private let digest: String
    private var tampered = false
    init(_ digest: String) { self.digest = digest }
    private static let zeros = Data(count: 1 << 20)

    func update(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while !tampered, offset < bytes.count, let base = bytes.baseAddress {
            let count = min(bytes.count - offset, Self.zeros.count)
            // Data equality compares memory at once, even in a debug build.
            let chunk = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + offset), count: count,
                             deallocator: .none)
            tampered = chunk != Self.zeros.prefix(count)
            offset += count
        }
    }
    func finish() throws -> String {
        FakeLocalState.shared.countHash()
        return tampered ? String(repeating: "0", count: 64) : digest
    }
}

/// Serves zero bytes like a range-capable server. After `pauseAfter` bytes it
/// waits for `resume` (or cancellation), like a stalled connection.
final class HeldTransport: LocalModelDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pause: Int64?
    private var requested: [Int64] = []
    let resume = Gate(open: false)

    init(pauseAfter: Int64? = nil) { pause = pauseAfter }

    var offsets: [Int64] { lock.withLock { requested } }

    func download(
        _ request: LocalModelDownloadRequest, start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let pauseAt = lock.withLock { () -> Int64? in
            requested.append(request.resumeOffset)
            return pause
        }
        try start(request.resumeOffset > 0 ? .resumed(offset: request.resumeOffset) : .fromBeginning)
        var position = request.resumeOffset
        let chunk = Data(count: 1 << 20)
        while position < request.expectedByteCount {
            if let pauseAt, position >= pauseAt {
                lock.withLock { pause = nil }
                await resume.pass()
                try Task.checkCancellation()
            }
            let count = Int(min(request.expectedByteCount - position, Int64(chunk.count)))
            try sink(chunk.prefix(count))
            position += Int64(count)
        }
    }
}

enum FakeLocalPlatform: DesktopHostLocalModelPlatform {
    typealias VoiceOutputSettings = FakeHotKey
    typealias LocalRuntime = FakeRuntime
    typealias LocalModelsState = DesktopHostLocalModelsState<FakeRuntime>
    static let displayName = "Test"
    static let credentialStoreName = "the test keyring"

    static func update(_ status: String, transcript: String?, state: Int32) { FakeLog.shared.status(status) }
    static func recordingState(_ state: Int32) {}
    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {}
    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) {}
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {}
    static func publishModels(status: String, refreshing: Bool) throws {}
    static func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    static func saveAPIKey(_ key: String, name: String) throws { FakeLog.shared.setKey(key, name: name) }
    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        FakePlatform.uploadStaging(directory: directory)
    }
    static func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    static func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        throw DesktopHostError(message: "No converter in tests.")
    }
    static func openFile(_ url: URL) throws {}
    static func copyToClipboard(_ text: String) throws { FakeLog.shared.copy(text) }
    static func makeOutputJob(options: FakeTextOutput, target: String?) -> FakeJob? { nil }
    static func cancel(_ job: FakeJob) {}
    static func isClipboard(_ job: FakeJob) -> Bool { true }
    static func makePlayback() -> FakePlayback { FakePlayback() }
    static var defaultHotKey: FakeHotKey { FakeHotKey() }
    static func readyHint(_ hotKey: FakeHotKey) -> String { "Shortcut starts or stops recording." }
    static func finishHint(_ hotKey: FakeHotKey, for trigger: HotKeySessionTrigger) -> String { "Press to finish." }

    static var localModelHost: LocalModelHostSupport { .linux }
    static var localModelDigests: LocalModelDigestProvider {
        let digest = FakeLocalState.shared.pinnedDigest
        return LocalModelDigestProvider(name: "pinned stand-in") { PinnedDigest(digest) }
    }
    static var localModelTransport: any LocalModelDownloadTransport { FakeLocalState.shared.transport }
    static var localRuntimeMissing: String? { FakeLocalState.shared.runtimeMissing }
    static func openLocalRuntime(allowGPU: Bool) throws -> FakeRuntime {
        if let failure = FakeLocalState.shared.runtimeOpenFailure { throw DesktopHostError(message: failure) }
        return FakeLocalState.shared.runtime
    }
    static func localRuntimeSummary(useGPU: Bool) -> String { "Fake runtime ready." }
    static var localModelChoiceHint: String { "Choose it in tests." }
    static func presentLocalModels(
        _ rows: [DesktopHostLocalModelRow], status: String, useGPU: Bool, presenter: UnsafeMutableRawPointer?
    ) {
        FakeLocalState.shared.present(rows, status: status, useGPU: useGPU)
    }
}

/// Transcribes through the controller's prepared-audio path, as the native
/// hosts do, so on-device models reach the platform's local recogniser.
final class LocalEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakeLocalPlatform
    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? { nil }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakeLocalPlatform>
    ) async throws -> TranscriptionResult {
        try await controller.transcribePreparedAudio(
            request.audio, model: request.model, key: request.key, duration: request.duration,
            language: request.language
        )
    }
    func perform(_ job: FakeJob, text: String) -> String { "Delivered." }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

extension DesktopHostController where Platform == FakeLocalPlatform {
    var ownershipForTests: LocalModelOwnership { localModels.ownership }
    var settingsModelForTests: String { settings.model }
}
