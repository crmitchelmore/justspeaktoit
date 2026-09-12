import Foundation
import class WhisperKit.WhisperKit

extension LocalModelManager {
    func makeWhisperKitStream(
        request: WhisperKitStreamRequest, onEvent: @escaping WhisperKitStreamEventHandler
    ) async throws -> any WhisperKitLiveStreaming {
        let lease = try await self.makeReadyPipelineLease(modelID: request.batchModelID)
        let stream = try WhisperKitLiveStream(pipeline: lease.pipeline, request: request, onEvent: onEvent)
        return LeasedWhisperKitStream(stream: stream, lease: lease)
    }
}

/// Owns a use of downloaded files independently of the pipeline cache. Work
/// that outlives its controller (for example a timed-out tail decode) keeps
/// this lease alive until the decoder actually finishes.
@MainActor
final class LocalModelPipelineLease {
    let pipeline: WhisperKit
    private let release: @MainActor @Sendable () -> Void

    init(pipeline: WhisperKit, release: @escaping @MainActor @Sendable () -> Void) {
        self.pipeline = pipeline
        self.release = release
    }

    deinit {
        let release = self.release
        Task { @MainActor in release() }
    }
}

/// Stream capture ends before tail decoding begins, so stopStream cannot
/// release the files. Retain them for the stream and every suspended call.
@MainActor
final class LeasedWhisperKitStream: WhisperKitLiveStreaming {
    private let stream: any WhisperKitLiveStreaming
    private let lease: LocalModelPipelineLease

    init(stream: any WhisperKitLiveStreaming, lease: LocalModelPipelineLease) {
        self.stream = stream
        self.lease = lease
    }

    func startStream() async throws {
        defer { withExtendedLifetime(self.lease) {} }
        try await self.stream.startStream()
    }

    func stopStream() async {
        defer { withExtendedLifetime(self.lease) {} }
        await self.stream.stopStream()
    }

    func decodeTail(after confirmedEndSeconds: Float) async throws -> String {
        defer { withExtendedLifetime(self.lease) {} }
        return try await self.stream.decodeTail(after: confirmedEndSeconds)
    }
}
