import AVFoundation
import Foundation

/// Errors raised while preparing audio for the paid transcription route.
public enum PaidAudioPayloadError: LocalizedError, Equatable {
    case unreadableAudio
    case conversionFailed

    public var errorDescription: String? {
        switch self {
        case .unreadableAudio:
            return "That recording could not be read as audio."
        case .conversionFailed:
            return "That recording could not be converted for upload."
        }
    }
}

/// Prepares a recording for the paid batch transcription endpoint.
///
/// The endpoint accepts WAV and nothing else. That is not fussiness: it bills by
/// duration, and the only duration it can trust is the one it reads out of the
/// header of the bytes it was actually sent. A compressed container's duration
/// cannot be derived from its size, and no upstream provider reports it back.
///
/// The app records AAC in an `.m4a`, so without this every paid transcription
/// would fall through to the user's own API key and the subscription would
/// silently do nothing. Conversion happens here, on the client, once per
/// recording.
public enum PaidAudioPayload {
    /// The content type every payload this type produces is sent as.
    public static let contentType = "audio/wav"

    /// Reads `url` and returns 16-bit PCM WAV bytes ready to upload.
    ///
    /// A file that is already WAV is passed through untouched rather than
    /// re-encoded, so the common case costs nothing and loses nothing.
    public static func wavData(contentsOf url: URL) throws -> Data {
        if url.pathExtension.lowercased() == "wav" {
            return try Data(contentsOf: url)
        }

        let source: AVAudioFile
        do {
            source = try AVAudioFile(forReading: url)
        } catch {
            throw PaidAudioPayloadError.unreadableAudio
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        // Best-effort cleanup: the bytes are read into memory before returning,
        // so the file on disk is scratch space and must not outlive the call.
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try transcode(source, to: destination)
            return try Data(contentsOf: destination)
        } catch {
            throw PaidAudioPayloadError.conversionFailed
        }
    }

    /// Writes `source` out as a linear-PCM WAV at its own sample rate.
    ///
    /// The rate and channel count are preserved rather than normalised: the
    /// server reads them from the header, so resampling would only lose fidelity
    /// and cost time. Sixteen-bit is the width every transcription provider
    /// expects, and halves the upload against the 32-bit float `AVAudioFile`
    /// hands back.
    private static func transcode(_ source: AVAudioFile, to destination: URL) throws {
        let format = source.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        // Created from `settings` alone, so the file's own processing format
        // matches `source.processingFormat` and buffers can be handed straight
        // across; `AVAudioFile` narrows to 16-bit on the way to disk.
        let output = try AVAudioFile(forWriting: destination, settings: settings)

        let frameCapacity: AVAudioFrameCount = 65_536
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        else {
            throw PaidAudioPayloadError.conversionFailed
        }

        while true {
            try source.read(into: buffer, frameCount: frameCapacity)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}
