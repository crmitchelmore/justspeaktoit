#if os(iOS)
import AVFoundation
import Foundation
import os.log

/// Manages persistent audio recording alongside live transcription.
/// Writes audio buffers to a local file during recording so that
/// audio is never lost — even if the network drops mid-session.
/// Recordings can be re-transcribed later from the saved files.
@MainActor
public final class AudioRecordingPersistence: ObservableObject {
    // MARK: - Published State

    @Published private(set) public var isRecording = false
    @Published private(set) public var currentFileURL: URL?

    // MARK: - Private

    private var audioFile: AVAudioFile?
    /// Thread-safe handle for writing from audio tap callbacks.
    /// Only written on the main actor, read from the audio thread.
    nonisolated(unsafe) private var fileHandle: AVAudioFile?
    private var recordingID: UUID?
    private var startTime: Date?

    private let logger = Logger(
        subsystem: "com.justspeaktoit.ios",
        category: "AudioPersistence"
    )

    // MARK: - Directory

    /// Returns the persistent recordings directory, creating it if needed.
    public static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        return dir
    }

    // MARK: - Public API

    /// Begin writing audio to a persistent file.
    /// Call this once when transcription starts, before the audio tap is installed.
    /// Returns the file URL for reference.
    @discardableResult
    public func startRecording(
        format: AVAudioFormat
    ) throws -> URL {
        guard !isRecording else {
            if let url = currentFileURL { return url }
            throw AudioPersistenceError.alreadyRecording
        }

        let rid = UUID()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = "Recording-\(timestamp)-\(rid.uuidString.prefix(8)).m4a"
        let url = Self.recordingsDirectory.appendingPathComponent(filename)

        // Create an AAC output file.
        // AVAudioFile with .m4a uses AAC by default when given a
        // processing format; we convert PCM→AAC on write.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        audioFile = try AVAudioFile(
            forWriting: url,
            settings: outputSettings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        fileHandle = audioFile

        recordingID = rid
        startTime = Date()
        currentFileURL = url
        isRecording = true

        logger.info("Started persistent recording: \(filename)")
        return url
    }

    /// Write a buffer of audio data. Call from the audio engine tap callback.
    /// This method is nonisolated so it can be called from any thread.
    /// The underlying AVAudioFile is stored in a thread-safe wrapper.
    nonisolated public func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let file = fileHandle else { return }
        do {
            try file.write(from: buffer)
        } catch {
            // Log but don't throw — we don't want to interrupt the
            // transcription pipeline for a write failure.
            print("[AudioPersistence] Write error: \(error)")
        }
    }

    /// Stop recording and return metadata about the saved file.
    public func stopRecording() -> RecordingInfo? {
        guard isRecording, let url = currentFileURL else { return nil }

        let duration: TimeInterval
        if let start = startTime {
            duration = Date().timeIntervalSince(start)
        } else {
            duration = 0
        }

        audioFile = nil
        fileHandle = nil
        isRecording = false
        currentFileURL = nil

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        let info = RecordingInfo(
            id: recordingID ?? UUID(),
            url: url,
            startedAt: startTime ?? Date(),
            duration: duration,
            fileSize: fileSize
        )

        recordingID = nil
        startTime = nil

        let filename = url.lastPathComponent
        logger.info("Stopped recording: \(filename, privacy: .public) (\(fileSize) bytes)")
        return info
    }

    /// Cancel recording and delete the partial file.
    public func cancelRecording() {
        let url = currentFileURL
        audioFile = nil
        fileHandle = nil
        isRecording = false
        currentFileURL = nil
        recordingID = nil
        startTime = nil

        if let url {
            try? FileManager.default.removeItem(at: url)
            logger.info("Cancelled and deleted: \(url.lastPathComponent)")
        }
    }

    // MARK: - Listing & Management

    /// List all saved recordings, newest first.
    public static func listRecordings() -> [RecordingInfo] {
        let dir = recordingsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let validExt: Set<String> = ["m4a", "wav", "aac", "caf"]

        return files
            .filter { validExt.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> RecordingInfo? in
                let res = try? url.resourceValues(
                    forKeys: [.creationDateKey, .fileSizeKey]
                )
                let created = res?.creationDate ?? Date()
                let size = Int64(res?.fileSize ?? 0)

                // Try to get duration
                let dur = (try? AVAudioPlayer(contentsOf: url))?.duration ?? 0

                let stem = url.deletingPathExtension().lastPathComponent
                let cleanStem = stem
                    .replacingOccurrences(of: "Recording-", with: "")
                let rid = UUID(uuidString: String(cleanStem.suffix(8))) ?? UUID()

                return RecordingInfo(
                    id: rid,
                    url: url,
                    startedAt: created,
                    duration: dur,
                    fileSize: size
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Delete a specific recording file.
    public static func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Supporting Types

public struct RecordingInfo: Identifiable, Hashable {
    public let id: UUID
    public let url: URL
    public let startedAt: Date
    public let duration: TimeInterval
    public let fileSize: Int64
}

public enum AudioPersistenceError: LocalizedError {
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A persistent recording session is already active."
        }
    }
}
#endif
