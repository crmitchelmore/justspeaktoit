// AVFAudio types (AVAudioPCMBuffer, AVAudioConverter callbacks) predate
// Sendable annotations; @preconcurrency downgrades those diagnostics.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os
import Speech

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleLocalModels {
    public static let legacySpeechModelID = "apple/local/SFSpeechRecognizer"
    public static let speechTranscriberModelID = "apple/local/SpeechTranscriber"
    public static let dictationTranscriberModelID = "apple/local/DictationTranscriber"
    public static let foundationModelID = "apple/local/FoundationModels"

    public static var supportsSpeechTranscriber: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    /// Device-level catalogue capability. `DictationTranscriber` ships with OS
    /// 26 and does not require Apple Intelligence, but locale support is async;
    /// the shared SpeechAnalyzer module factory resolves that before dispatch.
    public static var supportsDictationTranscriber: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return true
        }
        return false
    }

    public static var preferredSpeechModelID: String {
        preferredSpeechModelID(
            speechTranscriberAvailable: supportsSpeechTranscriber,
            dictationTranscriberAvailable: supportsDictationTranscriber
        )
    }

    public static func preferredSpeechModelID(
        speechTranscriberAvailable: Bool,
        dictationTranscriberAvailable: Bool
    ) -> String {
        if speechTranscriberAvailable { return speechTranscriberModelID }
        if dictationTranscriberAvailable { return dictationTranscriberModelID }
        return legacySpeechModelID
    }

    /// Preserves the original selection API for package consumers that only
    /// know about SpeechTranscriber availability.
    public static func preferredSpeechModelID(speechTranscriberAvailable: Bool) -> String {
        preferredSpeechModelID(
            speechTranscriberAvailable: speechTranscriberAvailable,
            dictationTranscriberAvailable: false
        )
    }

    /// `SpeechDetector` ships with the OS 26 Speech framework, so support tracks
    /// the OS gate. Whether its assets install is decided when arming.
    public static var supportsSpeechDetector: Bool {
        if #available(macOS 26.0, iOS 26.0, *) {
            return true
        }
        return false
    }

    public static var supportsFoundationModels: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    public static func isAppleSpeechModel(_ modelID: String) -> Bool {
        modelID == legacySpeechModelID || isSpeechAnalyzerModel(modelID)
    }

    /// Whether the model runs on the SpeechAnalyzer pipeline (OS 26+).
    public static func isSpeechAnalyzerModel(_ modelID: String) -> Bool {
        modelID == speechTranscriberModelID || modelID == dictationTranscriberModelID
    }
}

public enum AppleLocalModelError: LocalizedError {
    case speechTranscriberUnavailable
    case speechDetectorFailed
    case speechDetectorUnavailable
    case localeUnsupported(String)
    case modelAssetsUnavailable
    case compatibleAudioFormatUnavailable
    case foundationModelUnavailable
    case emptyTranscript

    // Descriptions stay engine-neutral: the same errors surface from both
    // SpeechTranscriber and DictationTranscriber, so naming one engine would
    // misreport failures from the other.
    public var errorDescription: String? {
        switch self {
        case .speechTranscriberUnavailable:
            return "Apple on-device speech recognition isn't available on this device."
        case .speechDetectorFailed:
            return "Apple's on-device speech detector stopped unexpectedly."
        case .speechDetectorUnavailable:
            return "Hands-free dictation needs Apple's on-device speech detector, "
                + "which isn't available on this device."
        case .localeUnsupported(let identifier):
            return "Apple on-device speech recognition doesn't support the \(identifier) locale "
                + "on this device."
        case .modelAssetsUnavailable:
            return "Apple's on-device speech model could not be installed."
        case .compatibleAudioFormatUnavailable:
            return "Apple on-device speech recognition could not provide a compatible audio format."
        case .foundationModelUnavailable:
            return "Apple Intelligence's on-device language model isn't available on this device."
        case .emptyTranscript:
            return "Apple on-device speech recognition returned an empty transcript."
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
public final class AppleSpeechAudioConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private let lock = NSLock()

    public init(sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AppleLocalModelError.compatibleAudioFormatUnavailable
        }
        self.converter = converter
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        // Lock-guarded flag instead of a captured `var`: the input block is
        // @Sendable in the SDK, so mutating a captured local would be a
        // strict-concurrency violation (it is only ever called synchronously
        // inside `convert`, but the compiler cannot see that).
        let providedInput = OSAllocatedUnfairLock(initialState: false)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            let alreadyProvided = providedInput.withLock { provided -> Bool in
                if provided { return true }
                provided = true
                return false
            }
            if alreadyProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else { return nil }
        guard output.frameLength > 0 else { return nil }
        return output
    }
}

public enum AppleFoundationModelPolisher {
    public static var isAvailable: Bool {
        AppleLocalModels.supportsFoundationModels
    }

    /// Transcript cleanup: wraps the text in the shared cleanup payload.
    public static func process(text: String, systemPrompt: String) async throws -> String {
        try await respond(
            systemPrompt: systemPrompt,
            userMessage: TranscriptCleanupPolicy.userMessage(transcript: text)
        )
    }

    /// Sends an explicit prompt pair verbatim. Used when the caller (for
    /// example the Polish Text App Intent with a custom prompt) has already
    /// decided the exact system prompt and user message; wrapping the text in
    /// the cleanup payload here would fight instructions like "summarise this".
    public static func respond(systemPrompt: String, userMessage: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw AppleLocalModelError.foundationModelUnavailable
            }
            let session = LanguageModelSession(instructions: systemPrompt)
            let response = try await session.respond(to: userMessage)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw AppleLocalModelError.foundationModelUnavailable
    }
}
