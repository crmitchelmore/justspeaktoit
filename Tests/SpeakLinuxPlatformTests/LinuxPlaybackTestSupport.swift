import Foundation
import XCTest
import SpeakCore
@testable import SpeakLinuxPlatform

/// A device-free stream: it plays until the test finishes or fails it.
final class FakeLinuxPlayer: LinuxAudioPlayer, @unchecked Sendable {
    let sampleCount: Int
    let sampleRate: Int
    private let lock = NSLock()
    private var current: LinuxAudioPlayerState = .playing
    private var destroyedFlag = false
    private var pauseRequests: [Bool] = []

    init(sampleCount: Int, sampleRate: Int) {
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
    }

    var state: LinuxAudioPlayerState { lock.withLock { current } }
    var position: TimeInterval { 0 }
    var destroyed: Bool { lock.withLock { destroyedFlag } }
    var pauses: [Bool] { lock.withLock { pauseRequests } }

    func setPaused(_ paused: Bool) {
        lock.withLock {
            pauseRequests.append(paused)
            if current == .playing || current == .paused { current = paused ? .paused : .playing }
        }
    }

    func destroy() { lock.withLock { destroyedFlag = true } }
    func finish() { lock.withLock { current = .finished } }
    func fail() { lock.withLock { current = .failed } }
}

/// The player factory and window a playback under test reaches.
final class FakeLinuxAudio: @unchecked Sendable {
    struct Display: Equatable {
        let recordID: UUID
        let state: Int32
        let text: String
    }

    private let lock = NSLock()
    private var created: [FakeLinuxPlayer] = []
    private var shown: [Display] = []
    private var reported: [String] = []

    var players: [FakeLinuxPlayer] { lock.withLock { created } }
    var displays: [Display] { lock.withLock { shown } }
    var statuses: [String] { lock.withLock { reported } }

    func makePlayback() -> LinuxAudioPlayback {
        let playback = LinuxAudioPlayback(backend: LinuxAudioPlaybackBackend(
            makePlayer: { samples, rate in
                let player = FakeLinuxPlayer(sampleCount: samples.count, sampleRate: rate)
                self.lock.withLock { self.created.append(player) }
                return player
            },
            show: { record, state, text in
                self.lock.withLock { self.shown.append(Display(recordID: record, state: state, text: text)) }
            },
            pollInterval: 0.002
        ))
        playback.setStatusHandler { _, message in self.lock.withLock { self.reported.append(message) } }
        return playback
    }
}

enum LinuxSpeechFixture {
    /// The canonical 24 kHz mono PCM16 WAV Deepgram speech is rewritten to
    /// before it plays: 0.1 s of a quiet square wave.
    static func wav(frames: Int = 2_400) -> Data {
        var pcm = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let sample = UInt16(bitPattern: (frame / 60).isMultiple(of: 2) ? 512 : -512)
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000)!
    }

    /// The header Deepgram streams before synthesis ends (RIFF 0x7FFF0024,
    /// data 0x7FFF0000), which the shared engine rewrites.
    static func streamedWAV(frames: Int = 2_400) -> Data {
        var wav = wav(frames: frames)
        wav.replaceSubrange(4..<8, with: [0x24, 0x00, 0xFF, 0x7F])
        wav.replaceSubrange(40..<44, with: [0x00, 0x00, 0xFF, 0x7F])
        return wav
    }
}

/// Polls `condition` until it holds, failing after about two seconds.
func linuxEventually(
    _ description: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("Timed out waiting for \(description)", file: file, line: line)
}
