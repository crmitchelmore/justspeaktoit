import Foundation

/// The player's actual counters and ownership, independent of the audio device.
/// State tests establish admission/identity behavior, never audible playback.
struct TTSProgressivePlaybackState: Sendable {
    struct SessionID: Equatable, Sendable {
        private let value = UUID()
    }

    enum Mode: Sendable { case legacy, bounded }
    enum Failure: Error, Equatable { case invalidFormat, invalidChunk, queueFull }

    private static let maximumScheduledSeconds = 10
    static let scheduledAheadLimit = TimeInterval(maximumScheduledSeconds)

    private(set) var session: SessionID?
    private(set) var mode = Mode.legacy
    private(set) var sampleRate = 0
    private(set) var scheduledBuffers = 0
    private(set) var scheduledFrames = 0

    var isActive: Bool { session != nil }
    var maximumFrames: Int { sampleRate * Self.maximumScheduledSeconds }
    var maximumChunkFrames: Int { sampleRate / 10 }
    var scheduledSeconds: TimeInterval {
        sampleRate > 0 ? Double(scheduledFrames) / Double(sampleRate) : 0
    }

    mutating func begin(sampleRate: Int, mode: Mode) throws -> SessionID {
        guard sampleRate > 0, sampleRate <= Int.max / Self.maximumScheduledSeconds else { throw Failure.invalidFormat }
        let session = SessionID()
        self.session = session
        self.sampleRate = sampleRate
        self.mode = mode
        scheduledBuffers = 0
        scheduledFrames = 0
        return session
    }

    func requireCurrent(_ owner: SessionID) throws {
        guard session == owner else { throw CancellationError() }
    }

    func hasHeadroom(for frames: Int, owner: SessionID) throws -> Bool {
        try requireCurrent(owner)
        guard mode == .bounded, frames > 0, frames <= maximumChunkFrames else { throw Failure.invalidChunk }
        return scheduledFrames <= maximumFrames - frames
    }

    mutating func reserve(frames: Int, owner: SessionID) throws {
        try requireCurrent(owner)
        guard frames > 0 else { throw Failure.invalidChunk }
        if mode == .bounded, try !hasHeadroom(for: frames, owner: owner) { throw Failure.queueFull }
        guard scheduledFrames <= Int.max - frames, scheduledBuffers < Int.max else { throw Failure.queueFull }
        scheduledFrames += frames
        scheduledBuffers += 1
    }

    /// A late completion from an old engine cannot release current headroom.
    @discardableResult
    mutating func complete(frames: Int, owner: SessionID) -> Bool {
        guard session == owner, frames > 0 else { return false }
        scheduledBuffers = max(0, scheduledBuffers - 1)
        scheduledFrames = max(0, scheduledFrames - frames)
        return scheduledBuffers == 0
    }

    mutating func stop() {
        session = nil
        sampleRate = 0
        scheduledBuffers = 0
        scheduledFrames = 0
    }
}
