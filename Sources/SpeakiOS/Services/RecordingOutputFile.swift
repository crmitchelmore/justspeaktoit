#if os(iOS)
import AVFoundation
import Foundation

/// The AAC file one recording is written to: its name in the recordings
/// directory and the encoder settings it is opened with.
enum RecordingOutputFile {
    /// `Recording-<ISO 8601 start>-<8 hex>.m4a`; the library lists every file
    /// in the directory, so the name only needs to be unique and sortable.
    static func fileName(startedAt: Date, id: UUID) -> String {
        let timestamp = ISO8601DateFormatter().string(from: startedAt)
        return "Recording-\(timestamp)-\(id.uuidString.prefix(8)).m4a"
    }

    /// AAC at 128 kbit/s in the capture's own sample rate and channel count.
    static func settings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    /// Opens a new file in `directory` that accepts `format`'s PCM buffers and
    /// encodes them to AAC on write.
    static func create(
        for format: AVAudioFormat, in directory: URL, now: Date = Date()
    ) throws -> (url: URL, file: AVAudioFile) {
        let url = directory.appendingPathComponent(fileName(startedAt: now, id: UUID()))
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings(for: format),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        return (url, file)
    }
}
#endif
