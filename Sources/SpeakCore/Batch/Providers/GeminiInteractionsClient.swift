#if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
import AVFoundation
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Gemini 3.5 Transcribe batch client
//
// Google's Interactions API, not `generateContent`:
//   POST https://generativelanguage.googleapis.com/v1beta/interactions
//   x-goog-api-key: <key>
// Docs: https://ai.google.dev/gemini-api/docs/interactions/audio
//       https://ai.google.dev/gemini-api/docs/files

/// Cross-platform batch/file client for `gemini-3.5-transcribe` over the
/// Interactions API.
///
/// Recordings small enough for the API's 20 MB request cap are sent inline as
/// base64; larger ones go through the Files API first. Word-level timestamps
/// and speaker diarization are requested in verbatim mode, which is why the
/// upstream limit is 30 minutes of audio rather than the unannotated 1 hour.
///
/// Never logs audio, transcript text or the API key.
public struct GeminiInteractionsClient: Sendable {
    private let session: URLSession
    private let durationResolver: @Sendable (URL) async -> TimeInterval
    private let inlineAudioByteLimit: Int
    private let filePollInterval: TimeInterval
    private let filePollTimeout: TimeInterval
    // Internal seam lets tests inspect the on-disk source without buffering it.
    var uploadRecording: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

    #if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
    /// Preserves native asset probing for existing macOS and iOS callers.
    public init(
        session: URLSession = .shared,
        inlineAudioByteLimit: Int = GeminiTranscribeModels.inlineAudioByteLimit,
        filePollInterval: TimeInterval = 1.5,
        filePollTimeout: TimeInterval = 60
    ) {
        self.init(
            session: session, inlineAudioByteLimit: inlineAudioByteLimit,
            filePollInterval: filePollInterval, filePollTimeout: filePollTimeout,
            durationResolver: { url in await Self.assetDuration(for: url) }
        )
    }
    #endif

    /// Portable hosts provide the duration they measured during native capture
    /// or import; provider transport and Files API lifecycle stay shared.
    public init(
        session: URLSession = .shared,
        inlineAudioByteLimit: Int = GeminiTranscribeModels.inlineAudioByteLimit,
        filePollInterval: TimeInterval = 1.5,
        filePollTimeout: TimeInterval = 60,
        durationResolver: @escaping @Sendable (URL) async -> TimeInterval
    ) {
        self.session = session
        self.durationResolver = durationResolver
        self.inlineAudioByteLimit = inlineAudioByteLimit
        self.filePollInterval = filePollInterval
        self.filePollTimeout = filePollTimeout
        self.uploadRecording = { request, url in
            try await session.upload(for: request, fromFile: url)
        }
    }

    public func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String = GeminiTranscribeModels.batchCatalogID,
        language: String?
    ) async throws -> TranscriptionResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw GeminiBatchError.missingAPIKey }
        guard GeminiTranscribeModels.directBatchModelIDs.contains(model) else {
            throw GeminiBatchError.unsupportedModel(model)
        }

        let mimeType = GeminiAudioMIMEType.forFile(at: url)
        let source = try await self.audioSource(for: url, mimeType: mimeType, apiKey: trimmedKey)
        let request = try GeminiInteractionsRequest.make(
            apiKey: trimmedKey,
            model: GeminiTranscribeModels.batchAPIName,
            audio: source,
            mimeType: mimeType,
            language: language
        )
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiInteractionsResponse.mapHTTPFailure(status: http.statusCode, body: data)
        }

        let decoded = try JSONDecoder().decode(GeminiInteractionsResponse.self, from: data)
        let transcript = decoded.transcript
        guard !transcript.isEmpty else { throw GeminiBatchError.emptyTranscript }

        let duration = await self.durationResolver(url)
        return TranscriptionResult(
            text: transcript,
            segments: Self.segments(from: decoded, transcript: transcript, duration: duration),
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            // `TranscriptionSegment` has no speaker field yet, so the `spk_N` labels
            // Gemini returns alongside each word survive only here. Typed speaker
            // metadata is the follow-up tracked in issue #816.
            rawPayload: String(data: data, encoding: .utf8),
            debugInfo: nil
        )
    }

    /// Small recordings go inline; anything above the Interactions API's request
    /// cap is uploaded through the Files API first.
    private func audioSource(
        for url: URL,
        mimeType: String,
        apiKey: String
    ) async throws -> GeminiAudioSource {
        let source = url.resolvingSymlinksInPath()
        // A small recording is read straight into memory: `Data(contentsOf:)`
        // is already an atomic snapshot, and the inline path must not depend on
        // a writable temporary directory or spare disk space.
        if try Self.byteCount(at: source) <= self.inlineAudioByteLimit {
            let data = try Data(contentsOf: source)
            if Int64(data.count) <= self.inlineAudioByteLimit { return .inline(data) }
            // The file grew between the size check and the read; upload it instead.
        }
        // Freeze a large source before the first network suspension. A retry,
        // file replacement or deletion must not change the bytes/length that
        // URLSession streams from disk or the length declared to the session.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("recording")
        try FileManager.default.copyItem(at: source, to: snapshot)
        let byteCount = try Self.byteCount(at: snapshot)
        return .fileURI(
            try await GeminiFilesAPI(
                session: self.session, pollInterval: self.filePollInterval, pollTimeout: self.filePollTimeout,
                uploadRecording: self.uploadRecording
            ).upload(
                at: snapshot,
                byteCount: byteCount,
                mimeType: mimeType,
                apiKey: apiKey,
                displayName: url.lastPathComponent
            )
        )
    }

    private static func byteCount(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return fileSize.int64Value
    }

    /// One segment per annotated word, or a single whole-recording segment when
    /// the response carries no word annotations.
    private static func segments(
        from response: GeminiInteractionsResponse,
        transcript: String,
        duration: TimeInterval
    ) -> [TranscriptionSegment] {
        let words = response.wordAnnotations
        guard !words.isEmpty else {
            return [TranscriptionSegment(startTime: 0, endTime: duration, text: transcript)]
        }
        return words.map {
            TranscriptionSegment(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
        }
    }

    #if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
    private static func assetDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? seconds : 0
    }
    #endif
}
