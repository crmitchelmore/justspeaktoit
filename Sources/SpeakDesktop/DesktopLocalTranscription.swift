import Foundation
import SpeakCore

/// Runs one downloaded model over 16 kHz mono float samples.
public protocol DesktopLocalRecognizer: Sendable {
    /// Returns the raw transcript. Throws `CancellationError` when the calling
    /// task is cancelled before or during recognition.
    ///
    /// Recognises only with bytes whose SHA-256 is `model.artifact.sha256`:
    /// loading hashes the very bytes the runtime reads from `modelFile`, so a
    /// file replaced or rewritten at any moment cannot supply unverified bytes.
    /// Throws `DesktopLocalTranscriptionError.modelDoesNotMatchDigest` when
    /// they differ, having used none of them.
    func transcribe(samples: [Float], modelFile: URL, model: WhisperCppModel, language: String?) async throws -> String
}

public enum DesktopLocalTranscriptionError: LocalizedError, Equatable {
    case unsupportedAudio(String)
    case tooLong(maximumMinutes: Int)
    case runtimeUnavailable(String)
    /// The bytes the runtime read do not match the model's pinned SHA-256.
    case modelDoesNotMatchDigest

    public var errorDescription: String? {
        switch self {
        case .unsupportedAudio(let detail):
            return "Local transcription needs 16 kHz mono 16-bit PCM WAV audio. \(detail)"
        case .tooLong(let minutes):
            return "Local transcription accepts recordings up to \(minutes) minutes."
        case .runtimeUnavailable(let detail):
            return "The on-device speech runtime is unavailable. \(detail)"
        case .modelDoesNotMatchDigest:
            return "The downloaded model does not match its pinned SHA-256, so it was not used."
        }
    }
}

/// The desktop host's projection of the shared downloaded-model catalogue and
/// the local batch transcription path.
///
/// Identifiers, ordering and persisted selections come from
/// `ModelCatalog.localTranscription`; `WhisperCppModels` adds only the pinned
/// weights. Only entries the host's backends can execute are offered.
public enum DesktopLocalTranscription {
    /// Longest recording accepted: about 1.9 hours of 16 kHz mono PCM16.
    public static let maximumAudioBytes = 220_000_000
    public static let maximumMinutes = 110

    /// Catalogue entries the host runs through whisper.cpp, in catalogue order.
    public static func models(host: LocalModelHostSupport) -> [WhisperCppModel] {
        guard host.canExecute(.whisperCppGGML) else { return [] }
        return host.executableModels(in: ModelCatalog.localTranscription).compactMap { entry in
            guard entry.backends.contains(.whisperCppGGML) else { return nil }
            return WhisperCppModels.model(forCatalogueID: entry.id)
        }
    }

    /// Picker options keeping each catalogue identifier.
    public static func options(host: LocalModelHostSupport) -> [ModelCatalog.Option] {
        models(host: host).map { model in
            ModelCatalog.Option(
                id: model.catalogueID,
                displayName: model.displayName + " (on-device)",
                description: model.summary,
                latencyTier: .medium,
                tags: [.privacy]
            )
        }
    }

    public static func model(for identifier: String, host: LocalModelHostSupport) -> WhisperCppModel? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return models(host: host).first { $0.catalogueID == trimmed }
    }

    /// The friendly name of a whisper.cpp selection, or `nil` for any other
    /// identifier. History keeps showing it even if a host stops offering it.
    public static func displayName(for identifier: String) -> String? {
        WhisperCppModels.model(forCatalogueID: identifier).map { $0.displayName + " (on-device)" }
    }

    /// Whisper takes a bare ISO 639 code. Region and script subtags are
    /// dropped; anything else lets the model detect the language.
    public static func whisperLanguage(_ language: String?) -> String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !language.isEmpty, language != "auto" else { return nil }
        let primary = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard (2...3).contains(primary.count), primary.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return primary
    }

    public static func transcribe(
        audioURL: URL, model: WhisperCppModel, modelFile: URL, language: String?,
        recognizer: DesktopLocalRecognizer
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let audio = try DesktopLocalAudio.read(audioURL, maximumBytes: maximumAudioBytes)
        let text: String
        if DesktopLocalAudio.isSilent(audio.samples) {
            // Whisper invents text for silence. An empty recording stays empty.
            text = ""
        } else {
            let raw = try await recognizer.transcribe(
                samples: audio.samples, modelFile: modelFile, model: model, language: whisperLanguage(language)
            )
            text = cleanTranscript(raw)
        }
        try Task.checkCancellation()
        let segments = text.isEmpty ? [] : [TranscriptionSegment(startTime: 0, endTime: audio.duration, text: text)]
        return TranscriptionResult(
            text: text, segments: segments, confidence: nil, duration: audio.duration,
            modelIdentifier: model.catalogueID, cost: nil, rawPayload: nil, debugInfo: nil
        )
    }

    /// Collapses whitespace and removes whole-transcript non-speech markers
    /// such as `[BLANK_AUDIO]` or `(silence)`, which are never dictated text.
    public static func cleanTranscript(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var remainder = collapsed
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\*[^*]*\*"#] {
            remainder = remainder.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let meaningful = remainder.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        return meaningful ? collapsed : ""
    }
}

/// 16 kHz mono PCM16 WAV input for local recognition.
public enum DesktopLocalAudio {
    public struct Samples: Sendable {
        public let samples: [Float]
        public let duration: TimeInterval
    }

    /// Reads a RIFF/WAVE file with a PCM16 mono 16 kHz `fmt ` chunk, skipping
    /// other chunks such as `LIST`. Other formats must be converted first.
    public static func read(_ url: URL, maximumBytes: Int) throws -> Samples {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumBytes else {
            throw DesktopLocalTranscriptionError.tooLong(maximumMinutes: DesktopLocalTranscription.maximumMinutes)
        }
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> Samples {
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8),
              Array(bytes[8..<12]) == Array("WAVE".utf8) else {
            throw DesktopLocalTranscriptionError.unsupportedAudio("The file is not a WAV recording.")
        }
        var offset = 12
        var formatOK = false
        var payload: Range<Int>?
        while offset + 8 <= bytes.count {
            let identifier = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let length = u32(offset + 4)
            let body = offset + 8
            guard length >= 0, body + length <= bytes.count || identifier == "data" else {
                throw DesktopLocalTranscriptionError.unsupportedAudio("The WAV chunk layout is damaged.")
            }
            if identifier == "fmt " {
                guard length >= 16 else {
                    throw DesktopLocalTranscriptionError.unsupportedAudio("Invalid format chunk.")
                }
                let formatTag = u16(body), channels = u16(body + 2), rate = u32(body + 4), bits = u16(body + 14)
                guard formatTag == 1, channels == 1, rate == 16_000, bits == 16 else {
                    throw DesktopLocalTranscriptionError.unsupportedAudio(
                        "This file is \(channels)-channel, \(rate) Hz, \(bits)-bit."
                    )
                }
                formatOK = true
            } else if identifier == "data" {
                let end = min(body + length, bytes.count)
                payload = body..<(end - (end - body) % 2)
                break
            }
            offset = body + length + (length % 2)
        }
        guard formatOK, let payload else {
            throw DesktopLocalTranscriptionError.unsupportedAudio("The WAV file has no PCM audio chunk.")
        }
        var samples = [Float]()
        samples.reserveCapacity(payload.count / 2)
        var index = payload.lowerBound
        while index + 1 < payload.upperBound {
            let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            samples.append(Float(value) / 32_768)
            index += 2
        }
        return Samples(samples: samples, duration: Double(samples.count) / 16_000)
    }

    /// True when nothing rises above about -50 dBFS: no speech to transcribe.
    public static func isSilent(_ samples: [Float], threshold: Float = 0.003) -> Bool {
        samples.allSatisfy { abs($0) < threshold }
    }
}
