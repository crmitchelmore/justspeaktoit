import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class LocalModelOwnershipTests: XCTestCase {
    private let tiny = "local/whisperkit/tiny"
    private let base = "local/whisperkit/base"
    private let small = "local/whisperkit/small"

    /// A recording holds the model it will be transcribed with, which a
    /// profile may choose, not the app's selected model: that one stays
    /// removable while the other is refused until every use has ended.
    func testAModelInUseCannotBeRemovedWhileTheSelectedOneCan() throws {
        let capabilities = DesktopProfileCapabilities(
            batchModels: [], liveModels: [], polishModels: [],
            localModels: DesktopLocalTranscription.options(host: .windows)
        )
        let profile = DictationProfile(name: "Notes", transcriptionModelID: small, transcriptionRouting: .localBatch)
        let session = DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: tiny, defaultPostProcessing: .init(), capabilities: capabilities
        )
        XCTAssertEqual(session.modelIdentifier, small)

        var ownership = LocalModelOwnership()
        ownership.beginUse(session.modelIdentifier) // Recording start.
        ownership.beginUse(session.modelIdentifier) // Its transcription.
        XCTAssertNil(ownership.beginRemoval(small))
        XCTAssertFalse(ownership.isRemoving(small))
        let selected = try XCTUnwrap(ownership.beginRemoval(tiny))
        XCTAssertEqual(selected.model, tiny)
        XCTAssertTrue(ownership.isRemoving(tiny))
        ownership.endRemoval(selected)

        ownership.endUse(small)
        XCTAssertNil(ownership.beginRemoval(small), "The transcription still holds it")
        ownership.endUse(small)
        ownership.endUse(small) // Unmatched: must not leave a count behind.
        XCTAssertFalse(ownership.isInUse(small))
        XCTAssertNotNil(ownership.beginRemoval(small))
    }

    /// A removal must not delete a download in progress, and a download must
    /// not write into a folder being deleted. Other models are independent.
    func testEachModelsFilesHaveOneOwnerAtATime() throws {
        var ownership = LocalModelOwnership()
        XCTAssertTrue(ownership.beginDownload(tiny))
        XCTAssertFalse(ownership.beginDownload(tiny))
        XCTAssertNil(ownership.beginRemoval(tiny))
        XCTAssertTrue(ownership.beginDownload(base))
        ownership.endDownload(tiny)

        let removal = try XCTUnwrap(ownership.beginRemoval(tiny))
        XCTAssertFalse(ownership.beginDownload(tiny))
        XCTAssertNil(ownership.beginRemoval(tiny), "Removing twice at once")
        ownership.endDownload(tiny) // A stale download end leaves the removal owning the files.
        XCTAssertTrue(ownership.isRemoving(tiny))
        XCTAssertFalse(ownership.isDownloading(tiny))
        ownership.endRemoval(removal)

        XCTAssertFalse(ownership.isRemoving(tiny))
        XCTAssertTrue(ownership.beginDownload(tiny))
        XCTAssertTrue(ownership.isDownloading(base))
    }

    /// The runtime keeps the last model it loaded. Removing a model it has
    /// since replaced, or never ran, must not evict the one it holds.
    func testRemovalFreesTheRuntimeOnlyWhenItMayHoldTheModel() throws {
        var ownership = LocalModelOwnership()
        ownership.record(.completed, of: tiny)
        ownership.record(.completed, of: small)
        ownership.record(.skipped, of: base)
        let replaced = try XCTUnwrap(ownership.beginRemoval(tiny))
        let neverRun = try XCTUnwrap(ownership.beginRemoval(base))
        XCTAssertFalse(replaced.freesRuntime)
        XCTAssertFalse(neverRun.freesRuntime)
        ownership.endRemoval(replaced)
        ownership.endRemoval(neverRun)
        XCTAssertTrue(ownership.mayBeLoaded(small))

        // Cancelled: base may or may not have replaced small.
        ownership.record(.interrupted, of: base)
        XCTAssertTrue(ownership.mayBeLoaded(small))
        XCTAssertTrue(ownership.mayBeLoaded(base))
        let held = try XCTUnwrap(ownership.beginRemoval(small))
        XCTAssertTrue(held.freesRuntime)
        ownership.endRemoval(held)
        XCTAssertFalse(ownership.mayBeLoaded(small))
        XCTAssertTrue(ownership.mayBeLoaded(base))

        ownership.record(.completed, of: tiny)
        XCTAssertFalse(ownership.mayBeLoaded(base))
        XCTAssertTrue(ownership.mayBeLoaded(tiny))
    }

    /// Silence never reaches the runtime; a failed or cancelled recognition
    /// may have loaded the model; only a finished one surely did.
    func testProbeReportsWhatTheRuntimeDidWithTheModel() async throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let silence = directory.appendingPathComponent("silence.wav")
        try LocalModelTestFiles.wav(samples: [Int16](repeating: 3, count: 16_000)).write(to: silence)
        let speech = directory.appendingPathComponent("speech.wav")
        let tone = (0..<8_000).map { Int16(8_000 * sin(Double($0) * 0.2)) }
        try LocalModelTestFiles.wav(samples: tone).write(to: speech)
        let model = try XCTUnwrap(WhisperCppModels.model(forCatalogueID: tiny))

        let skipped = LocalRecognitionProbe(ScriptedRecognizer(fails: false))
        _ = try await DesktopLocalTranscription.transcribe(
            audioURL: silence, model: model, modelFile: directory, language: nil, recognizer: skipped
        )
        XCTAssertEqual(skipped.recognition, .skipped)

        let completed = LocalRecognitionProbe(ScriptedRecognizer(fails: false))
        let result = try await DesktopLocalTranscription.transcribe(
            audioURL: speech, model: model, modelFile: directory, language: nil, recognizer: completed
        )
        XCTAssertEqual(result.text, ScriptedRecognizer.reply)
        XCTAssertEqual(completed.recognition, .completed)

        let interrupted = LocalRecognitionProbe(ScriptedRecognizer(fails: true))
        do {
            _ = try await DesktopLocalTranscription.transcribe(
                audioURL: speech, model: model, modelFile: directory, language: nil, recognizer: interrupted
            )
            XCTFail("A cancelled recognition completed")
        } catch is CancellationError {}
        XCTAssertEqual(interrupted.recognition, .interrupted)
    }

    /// The removal bug: freeing the runtime's cache waits for the recognition
    /// it is running. Done on the Windows controller's actor, that wait stopped
    /// the actor serving cancellation and recording until the recognition
    /// ended. Through the teardown the host keeps serving while the runtime is
    /// held, the files go at once and the cache is freed after the recognition.
    func testTeardownWaitsForAHeldRuntimeWithoutBlockingItsCaller() async throws {
        let directory = try LocalModelTestFiles.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("local_whisperkit_small", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: folder.appendingPathComponent("ggml-small.bin"))
        let releasing = expectation(description: "The teardown asked the held runtime to free its cache")
        let runtime = HeldRuntime { releasing.fulfill() }
        let host = TeardownHost()

        let removal = Task { await host.remove(folder, freeing: runtime) }
        await fulfillment(of: [releasing], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "The files go before the cache is freed")
        let served = await host.serve()
        XCTAssertEqual(served, 1)
        XCTAssertEqual(runtime.releases, 0, "The cache is freed only once the recognition ends")

        runtime.finishRecognition()
        let failure = await removal.value
        XCTAssertNil(failure)
        XCTAssertEqual(runtime.releases, 1)
        XCTAssertFalse(runtime.timedOut)
    }

    /// The model was meant to go, so its cache is freed even when its files
    /// could not be deleted, and the failure is reported.
    func testTeardownFreesTheCacheEvenWhenFilesCannotBeDeleted() async {
        let runtime = HeldRuntime {}
        runtime.finishRecognition()
        let failure = await LocalModelTeardown().remove(
            { throw CocoaError(.fileWriteNoPermission) }, release: { runtime.releaseModel() }
        )
        XCTAssertNotNil(failure)
        XCTAssertEqual(runtime.releases, 1)
    }
}

/// Replies like whisper.cpp, or is cancelled mid-recognition.
private struct ScriptedRecognizer: DesktopLocalRecognizer {
    static let reply = "Ask not what your country can do for you."
    let fails: Bool

    func transcribe(
        samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?
    ) async throws -> String {
        if fails { throw CancellationError() }
        return Self.reply
    }
}

/// Stands in for whisper.cpp: freeing the cached model waits for the running
/// recognition, as `jsti_whisper_runtime_release_model` waits for the mutex a
/// transcription holds throughout inference.
private final class HeldRuntime: @unchecked Sendable {
    private let recognition = DispatchSemaphore(value: 0)
    private let entered: @Sendable () -> Void
    private let lock = NSLock()
    private var count = 0
    private var expired = false

    init(entered: @escaping @Sendable () -> Void) { self.entered = entered }

    var releases: Int { lock.withLock { count } }
    var timedOut: Bool { lock.withLock { expired } }

    func releaseModel() {
        entered()
        let ended = recognition.wait(timeout: .now() + 10) == .success
        lock.withLock {
            count += 1
            expired = expired || !ended
        }
    }

    func finishRecognition() { recognition.signal() }
}

/// Removes a model as the Windows controller does, and serves other calls.
private actor TeardownHost {
    private let teardown = LocalModelTeardown()
    private var calls = 0

    func remove(_ folder: URL, freeing runtime: HeldRuntime) async -> String? {
        await teardown.remove({ try FileManager.default.removeItem(at: folder) }, release: { runtime.releaseModel() })
    }

    /// Other work, such as cancelling a transcription or stopping a recording.
    func serve() -> Int {
        calls += 1
        return calls
    }
}
