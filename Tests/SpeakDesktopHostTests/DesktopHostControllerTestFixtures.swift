import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

// Fakes and synthetic doubles shared by `DesktopHostControllerTests`, split
// out to keep that file under the pinned file-length limit. No window,
// microphone, keyring, network or clipboard: these run on every host that
// builds the portable package, so the orchestration Windows and Linux share
// is exercised without either native adapter.

struct FakeTextOutput: Codable, Equatable, Sendable, DesktopAppSwitchOutputOptions {
    var label = "default"
    var appSwitchDelivery: AppSwitchDelivery?
}

extension FakeTextOutput {
    init(appSwitchDelivery: AppSwitchDelivery?) {
        self.init(label: "default", appSwitchDelivery: appSwitchDelivery)
    }
}

struct FakeHotKey: Codable, Sendable {}

struct FakeJob: Sendable {
    let label: String
    let target: String?
    var appSwitchDelivery: AppSwitchDelivery?
}

final class FakePlayback: DesktopHostPlayback, @unchecked Sendable {
    let stopping = Gate(open: true)
    var stopGate: Gate?
    func setStatusHandler(_ handler: @escaping @Sendable (UInt64, String) -> Void) {}
    func isCurrent(revision: UInt64) -> Bool { false }
    func play(recordID: UUID, path: String, knownDuration: TimeInterval?) throws {}
    func togglePause(recordID: UUID) -> Bool { false }
    func stop(announcing: Bool) {}
    func stop(unless recordID: UUID) {}
    // With no suspending `stopGate`, this preserves the pre-existing hold/release
    // contract hands-free arming relies on. When a comparison suspends playback via
    // `stopGate`, releasing `stopping` first signals suspension has begun (so callers
    // can synchronize) before blocking on the externally controlled gate.
    func stopAndWait() async throws {
        if let stopGate {
            stopping.release()
            await stopGate.pass()
        } else {
            await stopping.pass()
        }
    }
    func stopSavedAudioAndWait() async throws { await FakeLog.shared.stopSavedAudio() }
    func close() async throws {}
}

/// Everything the fake window and services were asked to do.
final class FakeLog: @unchecked Sendable {
    static let shared = FakeLog()
    private let lock = NSLock()
    private var statuses: [String] = []
    private var clipboard: [String] = []
    private var hudStates: [DesktopHUDState] = []
    private var folders: [URL] = []
    private var directoryLauncher: (@Sendable (URL) throws -> Void)?
    private var savedAudioStopper: (@Sendable () async -> Void)?
    private var audioConverter: (@Sendable (URL, URL) async throws -> TimeInterval)?
    private var presentationStates: [Int32] = []
    private var displayedTranscriptValues: [String] = []
    private var transcriptValues: [String] = []
    private var keyReadHook: (@Sendable (String) -> Void)?
    private var keyWriteHook: (@Sendable (String, String) throws -> Void)?
    private var learningReadback: (any DesktopCorrectionReadback)?
    var correctionReadback: (any DesktopCorrectionReadback)? { lock.withLock { learningReadback } }
    func installCorrectionReadback(_ readback: (any DesktopCorrectionReadback)?) {
        lock.withLock { learningReadback = readback }
    }
    var keys: [String: String] = [:]

    func reset() {
        lock.withLock {
            statuses = []
            clipboard = []
            hudStates = []
            folders = []
            directoryLauncher = nil
            savedAudioStopper = nil
            audioConverter = nil
            keys = [:]
            presentationStates = []
            displayedTranscriptValues = []
            transcriptValues = []
            keyReadHook = nil
            keyWriteHook = nil
            learningReadback = nil
        }
    }
    /// Lets a test observe (or block inside) the instant a stored key is actually
    /// read, without the hook itself holding `lock` for the duration.
    func installKeyReadHook(_ hook: @escaping @Sendable (String) -> Void) {
        lock.withLock { keyReadHook = hook }
    }
    /// Lets a test observe, block inside, or fail the actual vault write that
    /// backs `Platform.saveAPIKey` before it lands. The hook runs first and may
    /// throw to simulate a vault failure (skipping persistence); otherwise the
    /// write still persists via `setKey` afterward, matching the uncooperative
    /// I/O the hook cannot roll back once it returns normally. A hook body may
    /// also call `setKey` itself to simulate persistence racing ahead of the
    /// surrounding controller logic (e.g. late-confirmed writes); doing so is
    /// redundant with, not a replacement for, the automatic post-hook persist.
    func installKeyWriteHook(_ hook: @escaping @Sendable (String, String) throws -> Void) {
        lock.withLock { keyWriteHook = hook }
    }
    func writeKey(_ key: String, name: String) throws {
        let hook = lock.withLock { keyWriteHook }
        if let hook {
            try hook(key, name)
        }
        setKey(key, name: name)
    }
    func setDirectoryLauncher(_ launcher: (@Sendable (URL) throws -> Void)?) {
        lock.withLock { directoryLauncher = launcher }
    }
    func reveal(_ folder: URL) throws {
        let launcher = lock.withLock { folders.append(folder); return directoryLauncher }
        try launcher?(folder)
    }
    var revealedFolders: [URL] { lock.withLock { folders } }
    func setSavedAudioStopper(_ stopper: (@Sendable () async -> Void)?) {
        lock.withLock { savedAudioStopper = stopper }
    }
    func setAudioConverter(_ converter: (@Sendable (URL, URL) async throws -> TimeInterval)?) {
        lock.withLock { audioConverter = converter }
    }
    func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        guard let converter = lock.withLock({ audioConverter }) else {
            throw DesktopHostError(message: "No converter in tests.")
        }
        return try await converter(input, output)
    }
    func stopSavedAudio() async {
        let stopper = lock.withLock { savedAudioStopper }
        await stopper?()
    }
    func hud(_ state: DesktopHUDState) { lock.withLock { hudStates.append(state) } }
    var huds: [DesktopHUDState] { lock.withLock { hudStates } }
    func status(_ text: String, transcript: String? = nil, state: Int32? = nil) {
        lock.withLock {
            statuses.append(text)
            if let transcript { displayedTranscriptValues.append(transcript) }
            if let state { presentationStates.append(state) }
        }
    }
    func copy(_ text: String) { lock.withLock { clipboard.append(text) } }
    var allStatuses: [String] { lock.withLock { statuses } }
    var copies: [String] { lock.withLock { clipboard } }
    var states: [Int32] { lock.withLock { presentationStates } }
    var displayedTranscripts: [String] { lock.withLock { displayedTranscriptValues } }
    func transcript(_ text: String?) {
        if let text { lock.withLock { transcriptValues.append(text) } }
    }
    var transcripts: [String] { lock.withLock { transcriptValues } }
    func key(_ name: String) -> String {
        let hook = lock.withLock { keyReadHook }
        hook?(name)
        return lock.withLock { keys[name] ?? "" }
    }
    func setKey(_ key: String, name: String) { lock.withLock { keys[name] = key } }
}

protocol FakeObservationalConsent: Sendable {
    func consentActionIsCurrent(_ allowed: Bool, token: UInt64) -> Bool
    func setLocalConsent(_ allowed: Bool, token: UInt64?) -> Bool
}

enum FakePlatform: DesktopHostAutomationPlatform {
    static var supportsObservationalCorrections: Bool {
        FakeLog.shared.correctionReadback?.provenance == .observationalATSPISpan
    }
    @discardableResult
    static func setObservationalCorrectionConsent(_ allowed: Bool, token: UInt64?) -> Bool {
        guard let native = FakeLog.shared.correctionReadback as? any FakeObservationalConsent else {
            return !allowed
        }
        return native.setLocalConsent(allowed, token: token)
    }
    static func observationalCorrectionActionIsCurrent(_ allowed: Bool, token: UInt64) -> Bool {
        (FakeLog.shared.correctionReadback as? any FakeObservationalConsent)?
            .consentActionIsCurrent(allowed, token: token) == true
    }
    static var correctionLearningUnavailable: String? {
        FakeLog.shared.correctionReadback == nil ? "Synthetic host has no owned text span." : nil
    }
    static func correctionReadback(_ job: FakeJob) -> (any DesktopCorrectionReadback)? {
        FakeLog.shared.correctionReadback
    }
    static var defaultTextOutput: FakeTextOutput { .init() }
    static func handsFreeReadinessFailure() -> String? { nil }
    typealias VoiceOutputSettings = DesktopVoiceOutputSettings
    static let displayName = "Test"
    static let credentialStoreName = "the test keyring"

    static func update(_ status: String, transcript: String?, state: Int32) {
        FakeLog.shared.status(status, transcript: transcript, state: state)
        FakeLog.shared.transcript(transcript)
    }
    static func recordingState(_ state: Int32) {}
    static func hud(_ state: DesktopHUDState) { FakeLog.shared.hud(state) }
    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {}
    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) { FakeLog.shared.status(status) }
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {}
    static func publishModels(status: String, refreshing: Bool) throws {}
    static func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    static func voiceTextImportCancelled(_ requestID: String) {
        FakeLog.shared.status("Import stopped: \(requestID)")
    }
    static func saveAPIKey(_ key: String, name: String) throws { try FakeLog.shared.writeKey(key, name: name) }
    static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        // No `.posix` default on Windows, where these tests also run.
        SharedMultipartUploadStaging(directory: directory, securityPolicy: .init(
            prepareDirectory: { url, manager in
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            },
            createFile: { url, manager in manager.createFile(atPath: url.path, contents: nil) }
        ))
    }
    static func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    static func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        try await FakeLog.shared.convertAudio(input: input, output: output)
    }
    static func openFile(_ url: URL) throws {}
    static func revealDirectory(_ url: URL) throws { try FakeLog.shared.reveal(url) }
    static func confirmAudioCleanup(id: UUID, count: Int) throws {
        FakeLog.shared.status("Audio confirmation \(id.uuidString): \(count)")
    }
    static func copyToClipboard(_ text: String) throws { FakeLog.shared.copy(text) }
    static func makeOutputJob(options: FakeTextOutput, target: String?) -> FakeJob? {
        options.label == "copy" || target != nil
            ? FakeJob(label: options.label, target: target, appSwitchDelivery: options.appSwitchDelivery) : nil
    }
    static func requiresInsertionTarget(_ options: FakeTextOutput) -> Bool { options.label != "copy" }
    static func cancel(_ job: FakeJob) {}
    static func isClipboard(_ job: FakeJob) -> Bool { job.target == nil }
    static func makePlayback() -> FakePlayback { FakePlayback() }
    static var defaultHotKey: FakeHotKey { FakeHotKey() }
    static func readyHint(_ hotKey: FakeHotKey) -> String { "Shortcut starts or stops recording." }
    static func finishHint(_ hotKey: FakeHotKey, for trigger: HotKeySessionTrigger) -> String { "Press to finish." }
}

/// Opens and closes like a physical gate for synthetic work.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Bool
    init(open: Bool) { self.open = open }
    var isOpen: Bool { lock.withLock { open } }
    func hold() { lock.withLock { open = false } }
    func release() { lock.withLock { open = true } }
    func pass() async {
        while !lock.withLock({ open }) {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

final class SyntheticCapture: DesktopRecordingCapture {
    let context: DesktopCaptureContext
    init(context: DesktopCaptureContext) { self.context = context }
    func start() throws {
        let samples: [Int16] = (0..<1_600).map { Int16(($0 % 32) * 256 - 4_000) }
        samples.withUnsafeBufferPointer { context.receive($0.baseAddress!, count: $0.count) }
    }
    func stop() throws {}
    func destroy() {}
}

final class SyntheticEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let transcription = Gate(open: true)
    private let lock = NSLock()
    private var performed: [(FakeJob, String)] = []
    private let outputDisposition: DesktopTextOutputResult.Disposition
    init(outputDisposition: DesktopTextOutputResult.Disposition = .confirmedInsertion) {
        self.outputDisposition = outputDisposition
    }
    var outputs: [(FakeJob, String)] { lock.withLock { performed } }

    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        nil
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        await transcription.pass()
        try Task.checkCancellation()
        return TranscriptionResult(
            text: "Synthetic transcript", segments: [], confidence: nil, duration: request.duration,
            modelIdentifier: request.model, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        lock.withLock { performed.append((job, text)) }
        return DesktopTextOutputResult(outputDisposition, status: "Delivered.")
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}

/// Transcription blocks until cancelled or released.
final class GatedEffects: DesktopHostEffects, @unchecked Sendable {
    typealias Platform = FakePlatform
    let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func apiKey(name: String) throws -> String { FakeLog.shared.key(name) }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture { SyntheticCapture(context: context) }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        nil
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult {
        await gate.pass()
        try Task.checkCancellation()
        throw CancellationError()
    }
    func perform(_ job: FakeJob, text: String) -> DesktopTextOutputResult {
        DesktopTextOutputResult(.confirmedInsertion, status: "Delivered.")
    }
    func writeSettings(_ data: Data, to url: URL) throws { try data.write(to: url, options: .atomic) }
}
