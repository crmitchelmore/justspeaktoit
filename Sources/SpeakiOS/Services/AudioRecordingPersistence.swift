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

    /// Serial queue that owns the write-side `AVAudioFile`. Every write and
    /// the close on stop/cancel run here, so the audio pipeline never races
    /// main-actor teardown while `AVAudioFile.write` is in flight.
    private let ioQueue = DispatchQueue(label: "com.justspeaktoit.ios.audioPersistence.io")
    /// Only touched on `ioQueue` after `startRecording` hands the file over.
    nonisolated(unsafe) private var ioFile: AVAudioFile?
    /// Fast-path flag read by `writeBuffer` before copying; guarded by `stateLock`.
    private let stateLock = NSLock()
    nonisolated(unsafe) private var isWriterOpen = false
    /// Pool for buffer copies handed to `ioQueue` so writes never touch the
    /// caller's (reused) buffer.
    private let writeBufferPool = PCMBufferPool(maximumBuffers: 8)
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

        let file = try AVAudioFile(
            forWriting: url,
            settings: outputSettings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        // Install the file and open admission under one lock hold, so the
        // install is queued strictly ahead of any write this unlock admits.
        stateLock.lock()
        ioQueue.async { [weak self] in self?.ioFile = file }
        isWriterOpen = true
        stateLock.unlock()

        recordingID = rid
        startTime = Date()
        currentFileURL = url
        isRecording = true

        logger.info("Started persistent recording: \(filename)")
        return url
    }

    /// Write a buffer of audio data. Call from the audio pipeline.
    /// This method is nonisolated so it can be called from any thread: the
    /// buffer is copied immediately and the AAC encode + file write happen
    /// asynchronously on the persistence I/O queue.
    nonisolated public func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        // Admission and enqueue are one atomic step against `closeWriter`'s
        // barrier. Releasing the lock before `ioQueue.async` would let a stalled
        // caller enqueue *after* the session closed; that block would then
        // resolve `ioFile` at execution time and splice prior-session audio into
        // the next recording. Holding the lock across the submit means every
        // admitted write is already queued ahead of `closeWriter`'s `ioQueue.sync`
        // barrier, so it lands in the file it was admitted for — or not at all.
        // `ioQueue` blocks never take `stateLock`, so the async submit can't deadlock.
        stateLock.lock()
        defer { stateLock.unlock() }
        if isWriterOpen, let copy = writeBufferPool.copy(buffer) {
            ioQueue.async { [weak self] in
                guard let self else { return }
                defer { self.writeBufferPool.recycle(copy) }
                guard let file = self.ioFile else { return }
                do {
                    try file.write(from: copy)
                } catch {
                    // Log but don't throw — we don't want to interrupt the
                    // transcription pipeline for a write failure.
                    print("[AudioPersistence] Write error: \(error)")
                }
            }
        }
    }

    /// Flips the fast-path flag and drains + closes the file on the I/O
    /// queue. `sync` so pending writes finish and the file header is
    /// finalised before callers read the file (size, playback, deletion).
    private func closeWriter() {
        stateLock.lock()
        isWriterOpen = false
        stateLock.unlock()
        ioQueue.sync { ioFile = nil }
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

        closeWriter()
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
        closeWriter()
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
    ///
    /// Durations are not read here: opening each file just to ask for its
    /// length stalls the main thread on large libraries. Entries are returned
    /// with `duration == 0`; load real values asynchronously per file with
    /// `loadDuration(for:)`.
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

                let stem = url.deletingPathExtension().lastPathComponent
                let cleanStem = stem
                    .replacingOccurrences(of: "Recording-", with: "")
                let rid = UUID(uuidString: String(cleanStem.suffix(8))) ?? UUID()

                return RecordingInfo(
                    id: rid,
                    url: url,
                    startedAt: created,
                    duration: 0,
                    fileSize: size
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Load a recording's duration without blocking the calling thread.
    /// `AVURLAsset` reads just the metadata it needs, off the main thread.
    public static func loadDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? max(0, seconds) : 0
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
