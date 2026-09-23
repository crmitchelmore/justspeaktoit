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
    func testAModelInUseCannotBeRemovedWhileTheSelectedOneCan() {
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
        XCTAssertFalse(ownership.beginRemoval(small))
        XCTAssertFalse(ownership.isRemoving(small))
        XCTAssertTrue(ownership.beginRemoval(tiny))
        XCTAssertTrue(ownership.isRemoving(tiny))
        ownership.endRemoval(tiny)

        ownership.endUse(small)
        XCTAssertFalse(ownership.beginRemoval(small), "The transcription still holds it")
        ownership.endUse(small)
        ownership.endUse(small) // Unmatched: must not leave a count behind.
        XCTAssertFalse(ownership.isInUse(small))
        XCTAssertTrue(ownership.beginRemoval(small))
    }

    /// A removal must not delete a download in progress, and a download must
    /// not write into a folder being deleted. Other models are independent.
    func testEachModelsFilesHaveOneOwnerAtATime() {
        var ownership = LocalModelOwnership()
        XCTAssertTrue(ownership.beginDownload(tiny))
        XCTAssertFalse(ownership.beginDownload(tiny))
        XCTAssertFalse(ownership.beginRemoval(tiny))
        XCTAssertTrue(ownership.beginDownload(base))
        ownership.endDownload(tiny)

        XCTAssertTrue(ownership.beginRemoval(tiny))
        XCTAssertFalse(ownership.beginDownload(tiny))
        XCTAssertFalse(ownership.beginRemoval(tiny), "Removing twice at once")
        ownership.endDownload(tiny) // A stale download end leaves the removal owning the files.
        XCTAssertTrue(ownership.isRemoving(tiny))
        XCTAssertFalse(ownership.isDownloading(tiny))
        ownership.endRemoval(tiny)

        XCTAssertFalse(ownership.isRemoving(tiny))
        XCTAssertTrue(ownership.beginDownload(tiny))
        XCTAssertTrue(ownership.isDownloading(base))
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

    /// The model was meant to go, so the runtime is still asked to free it when
    /// its files could not be deleted, and the failure is reported.
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

/// Stands in for whisper.cpp: freeing the cached model waits for the running
/// recognition, as the runtime's release waits for the lock a transcription
/// holds throughout inference.
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
