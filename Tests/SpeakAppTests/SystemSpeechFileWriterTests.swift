import AVFoundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// `speak say` must write the whole utterance, never a prefix (#1464).
final class SystemSpeechFileWriterTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-\(UUID().uuidString).wav")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func buffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        pcm.frameLength = frames
        return pcm
    }

    /// Drives the writer with a scripted synthesizer: each step is a delay, then
    /// a buffer (or the finish callback when `frames` is nil).
    private func writer(
        steps: [(delay: TimeInterval, frames: AVAudioFrameCount?)], stallTimeout: TimeInterval = 5
    ) throws -> SystemSpeechFileWriter {
        let buffers = try steps.map { step in try step.frames.map { try buffer(frames: $0) } }
        var writer: SystemSpeechFileWriter?
        writer = SystemSpeechFileWriter(
            url: url, format: .wav, finishGrace: 0.05, stallTimeout: stallTimeout
        ) { synthesizer, utterance, onBuffer in
            DispatchQueue.global().async { [weak writer] in
                for (step, pcm) in zip(steps, buffers) {
                    Thread.sleep(forTimeInterval: step.delay)
                    if let pcm {
                        onBuffer(pcm)
                    } else {
                        writer?.speechSynthesizer(synthesizer, didFinish: utterance)
                    }
                }
            }
        }
        return try XCTUnwrap(writer)
    }

    func testEmptyBufferBetweenSentences_KeepsWritingUntilFinish() async throws {
        let writer = try writer(steps: [(0, 1_000), (0.05, 0), (0.05, 2_000), (0.01, nil)])
        try await writer.write(AVSpeechUtterance(string: "One. Two."))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 3_000)
    }

    func testSynthesizerThatGoesQuiet_FailsInsteadOfReturningAPrefix() async throws {
        let writer = try writer(steps: [(0, 1_000)], stallTimeout: 0.3)
        do {
            try await writer.write(AVSpeechUtterance(string: "One. Two."))
            XCTFail("A render that never finished must not succeed")
        } catch TTSError.synthesisFailure {}
    }

    func testStallBoundRunsFromLastBuffer_SoLongTextCompletes() async throws {
        let steps: [(delay: TimeInterval, frames: AVAudioFrameCount?)] =
            Array(repeating: (0.1, 100), count: 8) + [(0.01, nil)]
        let writer = try writer(steps: steps, stallTimeout: 0.3)
        try await writer.write(AVSpeechUtterance(string: "A long text."))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 800)
    }

    func testCrashRestorePrompt_IsSkippedUnlessTheUserOptsBackIn() throws {
        let suite = "SystemSpeechRestore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SpeakApp.skipWindowRestorationAfterCrashes(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "ApplePersistenceIgnoreState"))
        defaults.set(false, forKey: "ApplePersistenceIgnoreState")
        XCTAssertFalse(defaults.bool(forKey: "ApplePersistenceIgnoreState"))
    }
}
