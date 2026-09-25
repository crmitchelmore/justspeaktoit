import Foundation
import Glibc
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakLinuxPlatform

/// How the real runtime loads a model: only a regular file, only bytes that
/// match the pinned digest, and never past a cancellation. Uses the fixture
/// and CI variables `LinuxLocalTranscriptionTests` documents.
final class LinuxModelLoadTests: XCTestCase {
    /// Loading hashes the bytes whisper.cpp reads through one open file. A copy
    /// changed at its pinned size is refused and never cached, and the cached
    /// model is not reused for a digest its bytes do not have.
    func testTheRuntimeUsesOnlyBytesMatchingThePinnedDigest() async throws {
        let fixture = try await LocalRuntimeFixture.make()
        defer { fixture.cleanUp() }
        let tampered = try fixture.copy("tampered")
        let handle = try FileHandle(forUpdating: tampered)
        let last = try handle.seekToEnd() - 1
        try handle.seek(toOffset: last)
        let byte = try XCTUnwrap(handle.readData(ofLength: 1).first)
        try handle.seek(toOffset: last)
        try handle.write(contentsOf: Data([byte ^ 0xff]))
        try handle.close()
        do {
            try await fixture.recognise(tampered)
            XCTFail("Bytes that do not match the pinned digest were recognised with")
        } catch DesktopLocalTranscriptionError.modelDoesNotMatchDigest {}
        XCTAssertFalse(fixture.runtime.releaseModel(loadedFrom: tampered), "The refused model was cached")

        try await fixture.recognise(fixture.installed)
        do {
            _ = try await fixture.runtime.transcribe(
                samples: fixture.samples, modelFile: fixture.installed, modelSHA256: String(repeating: "0", count: 64),
                language: "en"
            )
            XCTFail("The cached model was reused for a digest its bytes do not have")
        } catch DesktopLocalTranscriptionError.modelDoesNotMatchDigest {}
        XCTAssertFalse(fixture.runtime.releaseModel(loadedFrom: fixture.installed), "The refused load stayed cached")
        try await fixture.recognise(fixture.installed)
    }

    /// A model path that reaches a FIFO or a device is refused before any
    /// read: opening never waits for a writer, and nothing that could stall a
    /// read, and cancellation behind it, is loaded.
    func testAModelThatIsNotARegularFileIsRefusedWithoutReadingIt() async throws {
        let fixture = try await LocalRuntimeFixture.make()
        defer { fixture.cleanUp() }
        let fifo = fixture.scratch.appendingPathComponent("stalled.bin")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let device = fixture.scratch.appendingPathComponent("device.bin")
        try FileManager.default.createSymbolicLink(at: device, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        for model in [fifo, device] {
            let started = Date()
            do {
                _ = try await fixture.runtime.transcribe(
                    samples: fixture.samples, modelFile: model, modelSHA256: fixture.spec.artifact.sha256,
                    language: "en"
                )
                XCTFail("\(model.lastPathComponent) was loaded as a model")
            } catch let error as LinuxLocalTranscriptionError {
                XCTAssertTrue(error.message.contains("not a regular file"), error.message)
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "\(model.lastPathComponent) was waited on")
            XCTAssertFalse(fixture.runtime.releaseModel(loadedFrom: model))
        }
        try await fixture.recognise(fixture.installed)
    }

    /// Cancelling while a model loads stops reading within a chunk, even in
    /// the middle of a tensor. The test watches the runtime's read position on
    /// its open descriptor and cancels a tenth of the way in, inside the tiny
    /// model's 40 MB token embedding, which runs to 43 MB.
    func testCancellingWhileAModelLoadsStopsReadingIt() async throws {
        let fixture = try await LocalRuntimeFixture.make()
        defer { fixture.cleanUp() }
        let model = try fixture.copy("cancelled-load")
        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: model.path)[.size] as? NSNumber)?.intValue
        )
        let finished = FinishedFlag()
        let loading = Task {
            defer { finished.set() }
            return try await fixture.runtime.transcribe(
                samples: fixture.samples, modelFile: model, modelSHA256: fixture.spec.artifact.sha256,
                language: "en"
            )
        }
        var cancelledAt: Int?
        var furthest = 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let position = ReadPosition.of(model) else {
                if cancelledAt != nil || furthest > 0 || finished.value { break }
                try await Task.sleep(nanoseconds: 100_000)
                continue
            }
            furthest = max(furthest, position)
            if cancelledAt == nil, position >= size / 10 {
                cancelledAt = position
                loading.cancel()
            }
            try await Task.sleep(nanoseconds: 100_000)
        }
        loading.cancel()
        let cancelled: Bool
        do {
            _ = try await loading.value
            cancelled = false
        } catch is CancellationError {
            cancelled = true
        }
        guard let cancelledAt else {
            throw XCTSkip("The model loaded before its read position could be observed")
        }
        XCTAssertTrue(cancelled, "A load cancelled part way through completed")
        XCTAssertLessThan(furthest - cancelledAt, 8 << 20, "Loading went on reading after it was cancelled")
        XCTAssertFalse(fixture.runtime.releaseModel(loadedFrom: model), "A partly read model was cached")
        try await fixture.recognise(fixture.installed)
    }
}

/// Set once, from any thread.
private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}

/// Where this process's open descriptor on a file is reading, from procfs.
private enum ReadPosition {
    /// The position of the first descriptor open on `file`, or nil when none is.
    static func of(_ file: URL) -> Int? {
        let target = file.resolvingSymlinksInPath().path
        let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        for descriptor in descriptors {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(descriptor)"))
                    == target,
                  let info = try? String(contentsOfFile: "/proc/self/fdinfo/\(descriptor)", encoding: .utf8),
                  let line = info.split(separator: "\n").first(where: { $0.hasPrefix("pos:") }) else { continue }
            return Int(line.dropFirst(4).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
