import Foundation
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// In-app playback of the selected History recording through the sound
/// server. One run at a time; every display report carries its record ID so
/// the window ignores a run for a record that is no longer selected. Plays the
/// app's own mono PCM16 WAV recordings; other imports use Open audio.
final class LinuxAudioPlayback: DesktopHostPlayback, @unchecked Sendable {
    private final class Run: @unchecked Sendable {
        let recordID: UUID
        let revision: UInt64
        let duration: TimeInterval
        private let player: OpaquePointer
        private let lock = NSLock()
        private var destroyed = false
        var monitor: Task<Void, Never>?

        /// Every native call holds the run's lock, so none races destroy.
        func with<Value>(_ body: (OpaquePointer) -> Value) -> Value? {
            lock.withLock { destroyed ? nil : body(player) }
        }

        func destroy() {
            lock.withLock {
                guard !destroyed else { return }
                destroyed = true
                jsti_player_destroy(player)
            }
        }

        init(recordID: UUID, revision: UInt64, duration: TimeInterval, player: OpaquePointer) {
            self.recordID = recordID
            self.revision = revision
            self.duration = duration
            self.player = player
        }
    }

    private let lock = NSLock()
    private var current: Run?
    private var revision: UInt64 = 0
    private var closed = false
    private var status: (@Sendable (UInt64, String) -> Void)?

    package func setStatusHandler(_ handler: @escaping @Sendable (UInt64, String) -> Void) {
        lock.withLock { status = handler }
    }

    package func isCurrent(revision: UInt64) -> Bool { lock.withLock { self.revision == revision && !closed } }

    package func play(recordID: UUID, path: String, knownDuration: TimeInterval?) throws {
        let (samples, rate) = try Self.readPCM16WAV(URL(fileURLWithPath: path))
        stop()
        var error = [CChar](repeating: 0, count: 512)
        let player = samples.withUnsafeBufferPointer {
            jsti_player_create($0.baseAddress, $0.count, UInt32(rate), &error, error.count)
        }
        guard let player else { throw LinuxNativeError(message: String(cString: error)) }
        let run = lock.withLock { () -> Run? in
            guard !closed else { return nil }
            revision &+= 1
            let run = Run(
                recordID: recordID, revision: revision, duration: Double(samples.count) / Double(rate), player: player
            )
            current = run
            return run
        }
        guard let run else { jsti_player_destroy(player); return }
        run.monitor = Task.detached { [weak self] in await self?.monitor(run) }
    }

    package func togglePause(recordID: UUID) -> Bool {
        guard let run = lock.withLock({ current }), run.recordID == recordID else { return false }
        _ = run.with { player in
            let paused = jsti_player_state(player) == Int32(JSTI_PLAYER_PAUSED)
            return jsti_player_set_paused(player, paused ? 0 : 1)
        }
        show(run)
        return true
    }

    /// Only the user's Stop is `announcing` and reports "Playback stopped.";
    /// stopping for another row, recording or import leaves the status line
    /// to that work.
    package func stop(announcing: Bool = false) {
        let run = lock.withLock { () -> Run? in defer { current = nil }; return current }
        end(run)
        guard announcing, let run else { return }
        let handler = lock.withLock { status }
        handler?(run.revision, "Playback stopped.")
    }

    package func stop(unless recordID: UUID) {
        end(lock.withLock { () -> Run? in
            guard let run = current, run.recordID != recordID else { return nil }
            current = nil
            return run
        })
    }

    /// Destroying the player stops output before returning.
    package func stopAndWait() async throws { stop() }

    package func close() async throws {
        lock.withLock { closed = true }
        stop()
    }

    private func end(_ run: Run?) {
        guard let run else { return }
        run.monitor?.cancel()
        run.destroy()
        _ = jsti_window_set_playback(run.recordID.uuidString, 0, "")
    }

    private func show(_ run: Run) {
        guard let (state, position) = run.with({ (jsti_player_state($0), jsti_player_position($0)) }) else { return }
        let text = "\(Self.format(position)) / \(Self.format(run.duration))"
        _ = jsti_window_set_playback(run.recordID.uuidString, state == Int32(JSTI_PLAYER_PAUSED) ? 2 : 1, text)
    }

    private func monitor(_ run: Run) async {
        while !Task.isCancelled {
            guard let state = run.with({ jsti_player_state($0) }) else { return }
            if state == Int32(JSTI_PLAYER_FINISHED) || state == Int32(JSTI_PLAYER_FAILED) {
                let ended = lock.withLock { () -> Bool in
                    guard current === run else { return false }
                    current = nil
                    return true
                }
                guard ended else { return }
                run.destroy()
                _ = jsti_window_set_playback(run.recordID.uuidString, 0, "")
                let handler = lock.withLock { status }
                handler?(run.revision, state == Int32(JSTI_PLAYER_FAILED)
                    ? "Playback stopped: the audio output failed." : "Playback finished.")
                return
            }
            show(run)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    static func format(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Mono PCM16 WAV, walking chunks so extra ones are skipped.
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
