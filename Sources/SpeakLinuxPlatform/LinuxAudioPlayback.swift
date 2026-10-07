import Foundation
import CLinuxSupport

/// One output stream of mono PCM16 through the sound server, playing from
/// creation. The playback serialises every call and destroys it exactly once.
public protocol LinuxAudioPlayer: AnyObject {
    var state: LinuxAudioPlayerState { get }
    /// Seconds heard so far.
    var position: TimeInterval { get }
    func setPaused(_ paused: Bool)
    /// Stops output and releases the stream.
    func destroy()
}

public enum LinuxAudioPlayerState: Sendable {
    case playing, paused, finished, failed
}

/// Where playback reaches the sound server and the window. The app uses the C
/// adapter; tests substitute a device-free player and record the display.
public struct LinuxAudioPlaybackBackend: Sendable {
    let makePlayer: @Sendable (_ samples: [Int16], _ sampleRate: Int) throws -> any LinuxAudioPlayer
    /// Record-bound controls: state 0 stopped, 1 playing, 2 paused.
    let show: @Sendable (_ recordID: UUID, _ state: Int32, _ text: String) -> Void
    let pollInterval: TimeInterval

    public init(
        makePlayer: @escaping @Sendable (_ samples: [Int16], _ sampleRate: Int) throws -> any LinuxAudioPlayer,
        show: @escaping @Sendable (_ recordID: UUID, _ state: Int32, _ text: String) -> Void,
        pollInterval: TimeInterval = 0.2
    ) {
        self.makePlayer = makePlayer
        self.show = show
        self.pollInterval = pollInterval
    }

    public static let native = LinuxAudioPlaybackBackend(
        makePlayer: { try LinuxNativePlayer(samples: $0, sampleRate: $1) },
        show: { record, state, text in _ = jsti_window_set_playback(record.uuidString, state, text) }
    )
}

/// In-app playback of the selected History recording through the sound
/// server, and of Read aloud's segments (see LinuxAudioPlayback+Speech). One
/// run at a time; every display report carries its record ID so the window
/// ignores a run for a record that is no longer selected, and reports are
/// made under the state lock so they reach the window in state order. Plays
/// the app's own mono PCM16 WAV recordings and synthesized speech; other
/// imports use Open audio.
public final class LinuxAudioPlayback: @unchecked Sendable {
    final class Run: @unchecked Sendable {
        let recordID: UUID
        let revision: UInt64
        let duration: TimeInterval
        /// A Read aloud segment: its caller reports the outcome, so the run
        /// never reports a status of its own.
        let isSpeech: Bool
        private let player: any LinuxAudioPlayer
        private let lock = NSLock()
        private var destroyed = false
        private var monitor: Task<Void, Never>?
        private var completion: ((Result<TimeInterval, Error>) -> Void)?

        init(
            recordID: UUID, revision: UInt64, duration: TimeInterval, player: any LinuxAudioPlayer,
            completion: ((Result<TimeInterval, Error>) -> Void)? = nil
        ) {
            self.recordID = recordID
            self.revision = revision
            self.duration = duration
            self.player = player
            self.isSpeech = completion != nil
            self.completion = completion
        }

        /// Every native call holds the run's lock, so none races destroy.
        func with<Value>(_ body: (any LinuxAudioPlayer) -> Value) -> Value? {
            lock.withLock { destroyed ? nil : body(player) }
        }

        func watch(_ task: Task<Void, Never>) {
            lock.withLock { if destroyed { task.cancel() } else { monitor = task } }
        }

        /// Stops output, releases the stream and resolves a segment's caller
        /// with `outcome`. Only the first call acts.
        func end(_ outcome: Result<TimeInterval, Error>) {
            let completion = lock.withLock { () -> ((Result<TimeInterval, Error>) -> Void)? in
                guard !destroyed else { return nil }
                destroyed = true
                monitor?.cancel()
                player.destroy()
                defer { self.completion = nil }
                return self.completion
            }
            completion?(outcome)
        }
    }

    // Shared with LinuxAudioPlayback+Speech; every mutable field is
    // protected by `lock`, which is taken before a run's own lock.
    let backend: LinuxAudioPlaybackBackend
    let lock = NSLock()
    var current: Run?
    var revision: UInt64 = 0
    var closed = false
    private var status: (@Sendable (UInt64, String) -> Void)?
    /// Read aloud in progress; see LinuxAudioPlayback+Speech.
    var speechState: SpeechState?

    public init(backend: LinuxAudioPlaybackBackend = .native) {
        self.backend = backend
    }

    public func setStatusHandler(_ handler: @escaping @Sendable (UInt64, String) -> Void) {
        lock.withLock { status = handler }
    }

    public func isCurrent(revision: UInt64) -> Bool { lock.withLock { self.revision == revision && !closed } }

    /// Starts `path` for `recordID`, replacing whatever plays and ending Read aloud.
    public func play(recordID: UUID, path: String, knownDuration: TimeInterval?) throws {
        let (samples, rate) = try Self.readPCM16WAV(URL(fileURLWithPath: path))
        stop()
        let player = try backend.makePlayer(samples, rate)
        let admitted = lock.withLock { () -> (Run, Run?)? in
            guard !closed else { return nil }
            speechState = nil
            revision &+= 1
            let run = Run(
                recordID: recordID, revision: revision, duration: Double(samples.count) / Double(rate), player: player
            )
            return (run, replaceLocked(with: run))
        }
        guard let (run, previous) = admitted else { player.destroy(); return }
        previous?.end(.failure(CancellationError()))
        watch(run)
    }

    public func togglePause(recordID: UUID) -> Bool {
        lock.withLock {
            guard let run = current, run.recordID == recordID else {
                return toggleSpeechPauseLocked(recordID: recordID)
            }
            let paused = run.with { player -> Bool in
                let pause = player.state != .paused
                player.setPaused(pause)
                return pause
            }
            // Paused speech keeps its later segments silent until resumed.
            if let paused, speechState?.speech.recordID == recordID { speechState?.paused = paused }
            showLocked(run)
            return true
        }
    }

    /// Ends Read aloud and the current run. Only the user's Stop is
    /// `announcing` and reports "Playback stopped."; stopping for another
    /// row, recording or import leaves the status line to that work, and a
    /// Read aloud segment's reader reports its own stop.
    public func stop(announcing: Bool = false) {
        let run = lock.withLock { () -> Run? in
            let speech = speechState
            speechState = nil
            let run = current
            current = nil
            if let recordID = run?.recordID ?? speech?.speech.recordID { backend.show(recordID, 0, "") }
            return run
        }
        run?.end(.failure(CancellationError()))
        guard announcing, let run, !run.isSpeech else { return }
        let handler = lock.withLock { status }
        handler?(run.revision, "Playback stopped.")
    }

    /// Stops another record's playback and speech when `recordID` is selected.
    /// The window resets its controls on every row change, so the selected
    /// record's own playback or speech is presented again.
    public func stop(unless recordID: UUID) {
        let ended = lock.withLock { () -> Run? in
            if let speech = speechState, speech.speech.recordID != recordID {
                speechState = nil
                backend.show(speech.speech.recordID, 0, "")
            }
            var ended: Run?
            if let run = current, run.recordID != recordID {
                current = nil
                backend.show(run.recordID, 0, "")
                ended = run
            }
            if let run = current {
                showLocked(run)
            } else if let speech = speechState {
                showLocked(speech)
            }
            return ended
        }
        ended?.end(.failure(CancellationError()))
    }

    /// Destroying the player stops output before returning.
    public func stopAndWait() async throws { stop() }

    public func close() async throws {
        lock.withLock { closed = true }
        stop()
    }

    /// Makes `run` current and returns the run it replaces, which the caller ends.
    func replaceLocked(with run: Run) -> Run? {
        let previous = current
        current = run
        return previous
    }

    /// Samples the run until it finishes, fails or is ended.
    func watch(_ run: Run) {
        run.watch(Task.detached { [weak self] in await self?.monitor(run) })
    }

    func showLocked(_ run: Run) {
        guard let (state, position) = run.with({ ($0.state, $0.position) }) else { return }
        let text = "\(Self.format(position)) / \(Self.format(run.duration))"
        backend.show(run.recordID, state == .paused ? 2 : 1, text)
    }

    private func monitor(_ run: Run) async {
        while !Task.isCancelled {
            guard let state = run.with({ $0.state }) else { return }
            if state == .finished || state == .failed {
                let ended = lock.withLock { () -> Bool in
                    guard current === run else { return false }
                    current = nil
                    // Between segments the speech stays the active owner.
                    if let speech = speechState, speech.speech.recordID == run.recordID {
                        showLocked(speech)
                    } else {
                        backend.show(run.recordID, 0, "")
                    }
                    return true
                }
                guard ended else { return }
                let failed = state == .failed
                let outcome: Result<TimeInterval, Error> = failed
                    ? .failure(LinuxNativeError(message: "The audio output failed.")) : .success(run.duration)
                run.end(outcome)
                guard !run.isSpeech else { return }
                let handler = lock.withLock { status }
                handler?(run.revision, failed ? "Playback stopped: the audio output failed." : "Playback finished.")
                return
            }
            lock.withLock { if current === run { showLocked(run) } }
            try? await Task.sleep(nanoseconds: UInt64(backend.pollInterval * 1_000_000_000))
        }
    }

    static func format(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Mono PCM16 WAV, walking chunks so extra ones are skipped. Deepgram's
    /// synthesized speech is rewritten to this format (24 kHz) before it plays.
    static func readPCM16WAV(_ url: URL) throws -> ([Int16], Int) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        let unsupported = LinuxNativeError(
            message: "In-app playback supports this app's WAV recordings. Use Open audio for this file."
        )
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw unsupported
        }
        var offset = 12
        var rate = 0
        while offset + 8 <= data.count {
            let identifier = data[offset..<offset + 4]
            let size = u32(offset + 4)
            let body = offset + 8
            if identifier == Data("fmt ".utf8), body + 16 <= data.count {
                guard u16(body) == 1, u16(body + 2) == 1, u16(body + 14) == 16 else { throw unsupported }
                rate = u32(body + 4)
            } else if identifier == Data("data".utf8), rate > 0 {
                let end = min(data.count, body + size)
                let count = (end - body) / 2
                var samples = [Int16](repeating: 0, count: count)
                _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0, from: body..<body + count * 2) }
                return (samples.map { Int16(littleEndian: $0) }, rate)
            }
            offset = body + size + (size & 1)
        }
        throw unsupported
    }
}

/// `jsti_player_*`: libpulse through the sound server's pulse interface.
final class LinuxNativePlayer: LinuxAudioPlayer {
    private let player: OpaquePointer

    init(samples: [Int16], sampleRate: Int) throws {
        var error = [CChar](repeating: 0, count: 512)
        let player = samples.withUnsafeBufferPointer {
            jsti_player_create($0.baseAddress, $0.count, UInt32(sampleRate), &error, error.count)
        }
        guard let player else { throw LinuxNativeError(message: String(cString: error)) }
        self.player = player
    }

    var state: LinuxAudioPlayerState {
        switch jsti_player_state(player) {
        case Int32(JSTI_PLAYER_PAUSED): return .paused
        case Int32(JSTI_PLAYER_FINISHED): return .finished
        case Int32(JSTI_PLAYER_FAILED): return .failed
        default: return .playing
        }
    }

    var position: TimeInterval { jsti_player_position(player) }

    func setPaused(_ paused: Bool) { _ = jsti_player_set_paused(player, paused ? 1 : 0) }

    func destroy() { jsti_player_destroy(player) }
}
