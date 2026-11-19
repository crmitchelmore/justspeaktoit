#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import Foundation

/// One response's ordered decoder/consumer. A successful callback means the
/// current playback generation accepted this chunk, not merely decoded it.
/// The caller must throw cancellation when that owner has been replaced.
actor OpenRouterProgressiveSpeech {
    private let decoder: IncrementalMP3Decoder
    private let onPCM: @Sendable (Data) async throws -> Void
    private var committed = false
    private var completedFileRequired = false
    private var busy = false
    private var finished = false

    init(
        decoder: IncrementalMP3Decoder = IncrementalMP3Decoder(),
        onPCM: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.decoder = decoder
        self.onPCM = onPCM
    }

    func append(_ bytes: Data) async throws {
        guard !busy, !finished else { throw OpenRouterAudioError.invalidResponse }
        busy = true
        defer { busy = false }
        do {
            try await decoder.append(bytes)
            try await deliverAvailablePCM()
        } catch {
            try await handle(error)
        }
    }

    func finish() async throws -> (pcmProduced: Bool, completedFileRequired: Bool) {
        guard !busy, !finished else { throw OpenRouterAudioError.invalidResponse }
        busy = true
        defer { busy = false }
        do {
            do {
                try await decoder.finishInput()
                try await deliverAvailablePCM()
            } catch {
                try await handle(error)
            }
            guard committed || completedFileRequired else { throw OpenRouterAudioError.invalidResponse }
            try Task.checkCancellation()
            finished = true
            await decoder.close()
            return (committed, completedFileRequired)
        } catch {
            await decoder.close()
            finished = true
            throw Self.publicError(error)
        }
    }

    func cancel() async {
        finished = true
        await decoder.close()
    }

    private func deliverAvailablePCM() async throws {
        while let pcm = try await decoder.nextPCM() {
            try Task.checkCancellation()
            guard !finished else { throw CancellationError() }
            // At most one 100 ms chunk is retained here, including while the
            // consumer waits for bounded playback headroom. No chunk tasks.
            try await onPCM(pcm)
            try Task.checkCancellation()
            guard !finished else { throw CancellationError() }
            committed = true
        }
    }

    private func handle(_ error: Error) async throws {
        if !committed, !finished, !Task.isCancelled,
           let failure = error as? IncrementalMP3Decoder.Failure, case .unavailable = failure {
            // Continue downloading this very response. No second request and
            // no replay after any consumer-owned scheduling has succeeded.
            completedFileRequired = true
            await decoder.useCompletedFile()
            return
        }
        finished = true
        await decoder.close()
        throw Self.publicError(error)
    }

    private static func publicError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        return (error as? OpenRouterAudioError) ?? OpenRouterAudioError.invalidResponse
    }
}
#endif
