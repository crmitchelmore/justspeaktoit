#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
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
    /// Persistence truth for the most recently stopped recording (issue #705):
    /// dropped audio and write failures make `isComplete` false, so the saved
    /// file is never presented as healthy when it has gaps.
    @Published private(set) public var lastDiagnostics: RecordingPersistenceDiagnostics?

    /// Invoked (off the audio thread) the first time a session drops audio or
    /// fails a write, so the owning session can surface the problem while the
    /// recording is still running rather than discovering it at stop.
    nonisolated public var onPersistenceIssue: (@Sendable (RecordingPersistenceDiagnostics) -> Void)? {
        get { issueLock.withLock { storedIssueHandler } }
        set { issueLock.withLock { storedIssueHandler = newValue } }
    }

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
    /// Bounded admission (issue #705): short I/O stalls are absorbed by
    /// fallback allocations up to a duration budget sized from the sample
    /// format; sustained overflow drops frames and records the gap instead of
    /// silently presenting a complete recording. Replaced per session.
    nonisolated(unsafe) private var admission = RecordingPersistenceAdmissionController()
    /// Leaf lock for the once-per-session issue latch and its handler. The
    /// latch is tested from `writeBuffer` (which holds `stateLock`) and from
    /// `ioQueue` blocks (which never take `stateLock`), so it needs its own
    /// lock: a check-then-set on a bare flag would let both paths fire the
    /// callback, and `stateLock` cannot be taken on `ioQueue` without
    /// inverting the order against `closeWriter`'s barrier.
    private let issueLock = NSLock()
    /// Guarded by `issueLock`.
    nonisolated(unsafe) private var storedIssueHandler: (@Sendable (RecordingPersistenceDiagnostics) -> Void)?
    /// Set once per session after the first drop/write failure so the
    /// owning-session callback fires exactly once, off the audio thread.
    /// Guarded by `issueLock`.
    nonisolated(unsafe) private var didReportIssue = false
    private var startTime: Date?

    private let logger = SpeakLogger.logger(category: "AudioPersistence")

    #if DEBUG
    // MARK: - Test Seams
    //
    // Debug-only hooks that let a test drive the write/stop/start interleaving
    // deterministically. Set them before recording starts and leave them nil in
    // every non-test build.

    /// Called from `writeBuffer` once admission has been granted and the buffer
    /// copied, i.e. exactly where the pre-fix code released `stateLock` before
    /// submitting to `ioQueue`. A test blocks here to hold a writer mid-flight
    /// while it stops the session and starts the next one.
    nonisolated(unsafe) public var writeAdmissionStallHook: (@Sendable () -> Void)?

    /// Called on `ioQueue` with the URL of the file each admitted buffer was
    /// actually written into, so a test can assert a stalled write never lands
    /// in a later session's file.
    nonisolated(unsafe) public var didWriteBufferHook: (@Sendable (URL) -> Void)?

    /// Called from `closeWriter` only when `stateLock` is genuinely held by an
    /// in-flight admitted write, i.e. the close path is about to block behind
    /// it. A test releases its stalled writer here, so the interleaving it
    /// asserts on is observed rather than guessed at with a sleep.
    nonisolated(unsafe) public var writerCloseContentionHook: (@Sendable () -> Void)?
    #endif

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
        admission = RecordingPersistenceAdmissionController()
        issueLock.withLock { didReportIssue = false }
        stateLock.unlock()

        startTime = Date()
        currentFileURL = url
        isRecording = true
        lastDiagnostics = nil

        logger.info("Started persistent recording: \(filename)")
        return url
    }

    /// Write a buffer of audio data. Call from the audio pipeline.
    /// This method is nonisolated so it can be called from any thread: the
    /// buffer is copied immediately and the AAC encode + file write happen
    /// asynchronously on the persistence I/O queue.
    @discardableResult
    nonisolated public func writeBuffer(_ buffer: AVAudioPCMBuffer) -> RecordingPersistenceAdmission? {
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
        guard isWriterOpen else { return nil }

        // Bounded admission (issue #705): the pool absorbs the steady state, a
        // duration budget derived from the actual format absorbs short stalls
        // via fallback allocations, and sustained overflow drops the frame
        // while recording exactly how much audio was lost.
        let sampleRate = buffer.format.sampleRate
        let frameSeconds = sampleRate > 0 ? Double(buffer.frameLength) / sampleRate : 0
        let admissionController = admission
        let pooledCopy = writeBufferPool.copy(buffer)
        let verdict = admissionController.admit(
            frameSeconds: frameSeconds,
            poolHasCapacity: pooledCopy != nil
        )

        let copy: AVAudioPCMBuffer?
        switch verdict {
        case .accepted:
            copy = pooledCopy
        case .acceptedViaOverflow:
            copy = Self.fallbackCopy(of: buffer)
        case .backpressured:
            copy = nil
        }

        guard let copy else {
            // Admission granted but the fallback allocation itself failed, or
            // the frame was backpressured: either way it is a recorded gap.
            // An abandoned admission is reversed and counted as dropped audio
            // so `droppedSeconds` stays exact and the diagnostics agree with
            // the `.backpressured` result returned here.
            if verdict != .backpressured {
                admissionController.abandonAdmittedFrame(frameSeconds: frameSeconds)
            }
            reportIssueIfNeeded(admissionController)
            return .backpressured
        }

        #if DEBUG
        writeAdmissionStallHook?()
        #endif
        enqueueAdmittedWrite(
            copy: copy,
            isPooled: verdict == .accepted,
            frameSeconds: frameSeconds,
            controller: admissionController
        )
        return verdict
    }

    /// Submits one admitted copy to the I/O queue. Must be called while
    /// `stateLock` is held so the submit is ordered ahead of `closeWriter`'s
    /// barrier (see `writeBuffer`).
    private nonisolated func enqueueAdmittedWrite(
        copy: AVAudioPCMBuffer,
        isPooled: Bool,
        frameSeconds: Double,
        controller: RecordingPersistenceAdmissionController
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            defer {
                if isPooled { self.writeBufferPool.recycle(copy) }
            }
            guard let file = self.ioFile else {
                controller.completeWrite(frameSeconds: frameSeconds, failed: false)
                return
            }
            do {
                try file.write(from: copy)
                controller.completeWrite(frameSeconds: frameSeconds, failed: false)
                #if DEBUG
                self.didWriteBufferHook?(file.url)
                #endif
            } catch {
                // Never interrupt the transcription pipeline for a write
                // failure — but never pretend it didn't happen either.
                controller.completeWrite(frameSeconds: frameSeconds, failed: true)
                self.reportIssueIfNeeded(controller)
                self.logger.error("Write error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Controlled fallback allocation for a pool-exhausted frame within the
    /// admission budget.
    private nonisolated static func fallbackCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else { continue }
            memcpy(destinationData, sourceData, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }

    /// Surfaces the first drop/failure of the session to the owning session,
    /// exactly once, without blocking the audio thread.
    private nonisolated func reportIssueIfNeeded(_ controller: RecordingPersistenceAdmissionController) {
        // Latch and handler are read under one lock hold so two threads can
        // never both observe an unset latch (see `issueLock`).
        let handler = issueLock.withLock { () -> (@Sendable (RecordingPersistenceDiagnostics) -> Void)? in
            guard !didReportIssue else { return nil }
            didReportIssue = true
            return storedIssueHandler
        }
        guard let handler else { return }
        let diagnostics = controller.diagnostics
        DispatchQueue.global(qos: .utility).async {
            handler(diagnostics)
        }
    }

    /// Flips the fast-path flag and drains + closes the file on the I/O
    /// queue. `sync` so pending writes finish and the file header is
    /// finalised before callers read the file (size, playback, deletion).
    private func closeWriter() {
        acquireStateLockForClose()
        isWriterOpen = false
        stateLock.unlock()
        ioQueue.sync { ioFile = nil }
    }

    /// Takes `stateLock` for the close path. A failed `try()` means an admitted
    /// write still holds the lock across its `ioQueue` submit — the exact state
    /// the lock scope exists to guarantee — so DEBUG builds report it before
    /// blocking. Release builds just take the lock.
    private func acquireStateLockForClose() {
        #if DEBUG
        if stateLock.try() { return }
        writerCloseContentionHook?()
        #endif
        stateLock.lock()
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

        // closeWriter drained the I/O queue, so the diagnostics are final:
        // drops or write failures mark this saved file incomplete instead of
        // presenting it as a healthy recording (issue #705).
        let diagnostics = admission.diagnostics
        lastDiagnostics = diagnostics
        if !diagnostics.isComplete {
            logger.error(
                """
                Recording persisted incomplete: dropped \
                \(String(format: "%.2f", diagnostics.droppedSeconds), privacy: .public)s \
                across \(diagnostics.droppedFrames) frames, \
                \(diagnostics.writeFailures) write failures
                """
            )
        }

        // The same identity a later listing derives for this file, so the
        // in-session entry and the library entry are one recording to the UI.
        let info = RecordingInfo(
            id: Self.stableRecordingID(for: url),
            url: url,
            startedAt: startTime ?? Date(),
            duration: duration,
            fileSize: fileSize,
            diagnostics: diagnostics
        )

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
        startTime = nil

        if let url {
            try? FileManager.default.removeItem(at: url)
            logger.info("Cancelled and deleted: \(url.lastPathComponent)")
        }
    }
}
#endif
