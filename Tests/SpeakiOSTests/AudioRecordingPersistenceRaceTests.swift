#if os(iOS)
import AVFoundation
import XCTest

@testable import SpeakiOSLib

/// Regression coverage for the writer-admission race: `writeBuffer` holds
/// `stateLock` across the `ioQueue` submit, so a buffer admitted while a session
/// is open is queued ahead of that session's close barrier. If the lock were
/// released before the submit (the pre-fix shape), a stalled writer could enqueue
/// after `stopRecording`, resolve `ioFile` at execution time, and splice its audio
/// into the *next* recording's file.
final class AudioRecordingPersistenceRaceTests: XCTestCase {

    /// Collects the file each admitted buffer actually landed in. Written from
    /// `ioQueue`, read from the test thread after a close barrier.
    private final class WrittenFileRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []

        func record(_ url: URL) {
            lock.lock()
            names.append(url.lastPathComponent)
            lock.unlock()
        }

        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return names
        }
    }

    private var createdURLs: [URL] = []

    override func tearDown() {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs = []
        super.tearDown()
    }

    @MainActor
    func testStalledAdmittedWrite_landsInTheSessionItWasAdmittedFor() async throws {
        // Arrange
        let persistence = AudioRecordingPersistence()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(Self.makeSilentBuffer(format: format))
        let recorder = WrittenFileRecorder()
        persistence.didWriteBufferHook = { recorder.record($0) }

        let firstURL = try persistence.startRecording(format: format)
        createdURLs.append(firstURL)

        let admitted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        persistence.writeAdmissionStallHook = {
            admitted.signal()
            _ = release.wait(timeout: .now() + 5)
        }

        // Act: stall a writer that has already been admitted to session one.
        DispatchQueue.global().async { persistence.writeBuffer(buffer) }
        await Self.wait(for: admitted)
        persistence.writeAdmissionStallHook = nil

        // Release the stalled writer at the verified synchronisation point: the
        // hook fires only when the close path finds `stateLock` already held by
        // the admitted write, so the overlap under test is observed rather than
        // timed. Under the pre-fix lock scope nothing contends, the hook never
        // fires, and the stalled write lands in session two — which is exactly
        // what the assertions below reject.
        persistence.writerCloseContentionHook = { release.signal() }

        XCTAssertNotNil(persistence.stopRecording())
        persistence.writerCloseContentionHook = nil

        let secondURL = try persistence.startRecording(format: format)
        createdURLs.append(secondURL)
        persistence.writeBuffer(buffer)
        XCTAssertNotNil(persistence.stopRecording())

        // Assert: the stalled buffer belongs to session one, and session two saw
        // only the single buffer written while it was open.
        let written = recorder.snapshot
        XCTAssertEqual(
            written.first,
            firstURL.lastPathComponent,
            "A buffer admitted during session one must be written into session one's file."
        )
        XCTAssertEqual(
            written.filter { $0 == secondURL.lastPathComponent }.count,
            1,
            "Session two must contain only the buffer written while it was open."
        )
        XCTAssertEqual(written.count, 2)
    }

    @MainActor
    func testWriteAfterStop_isNotAdmitted() throws {
        // Arrange
        let persistence = AudioRecordingPersistence()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(Self.makeSilentBuffer(format: format))
        let recorder = WrittenFileRecorder()
        persistence.didWriteBufferHook = { recorder.record($0) }

        let url = try persistence.startRecording(format: format)
        createdURLs.append(url)
        persistence.writeBuffer(buffer)

        // Act
        XCTAssertNotNil(persistence.stopRecording())
        persistence.writeBuffer(buffer)

        // Assert
        XCTAssertEqual(recorder.snapshot, [url.lastPathComponent])
    }

    // MARK: - Helpers

    private static func makeSilentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount: AVAudioFrameCount = 1024
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frameCount) {
                    channels[channel][frame] = 0
                }
            }
        }
        return buffer
    }

    /// Waits on `semaphore` off the main thread so the awaiting test never blocks
    /// the main actor the persistence class is isolated to.
    private static func wait(for semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = semaphore.wait(timeout: .now() + 5)
                continuation.resume()
            }
        }
    }
}
#endif
