import AVFoundation
import Foundation

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
    private let inlineAudioByteLimit: Int
    private let filePollInterval: TimeInterval
    private let filePollTimeout: TimeInterval

    public init(
        session: URLSession = .shared,
        inlineAudioByteLimit: Int = GeminiTranscribeModels.inlineAudioByteLimit,
        filePollInterval: TimeInterval = 1.5,
        filePollTimeout: TimeInterval = 60
    ) {
        self.session = session
        self.inlineAudioByteLimit = inlineAudioByteLimit
        self.filePollInterval = filePollInterval
        self.filePollTimeout = filePollTimeout
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

        let duration = await Self.assetDuration(for: url)
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
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        let byteCount = fileSize.int64Value
        guard byteCount > self.inlineAudioByteLimit else {
            return .inline(try Data(contentsOf: url))
        }
        return .fileURI(
            try await self.uploadFile(
                at: url,
                byteCount: byteCount,
                mimeType: mimeType,
                apiKey: apiKey,
                displayName: url.lastPathComponent
            )
        )
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

    // MARK: - Files API

    /// Resumable upload used when the recording is too large to inline. Returns
    /// the `file.uri` the Interactions request references.
    private func uploadFile(
        at url: URL,
        byteCount: Int64,
        mimeType: String,
        apiKey: String,
        displayName: String
    ) async throws -> String {
        var start = URLRequest(url: GeminiTranscribeModels.fileUploadURL)
        start.httpMethod = "POST"
        start.setValue(apiKey, forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader)
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(byteCount), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": displayName]]
        )

        let (startBody, startResponse) = try await self.session.data(for: start)
        guard let startHTTP = startResponse as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard (200..<300).contains(startHTTP.statusCode) else {
            throw GeminiInteractionsResponse.mapHTTPFailure(
                status: startHTTP.statusCode, body: startBody)
        }
        guard
            let uploadURLString = startHTTP.value(forHTTPHeaderField: "x-goog-upload-url"),
            let uploadURL = URL(string: uploadURLString)
        else {
            throw GeminiBatchError.uploadFailed("The upload session URL was missing.")
        }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")
        upload.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        // URLSession reads the recording from disk as it uploads. Keeping it out
        // of httpBody avoids retaining a full recording (and copies) in memory.
        let (uploadBody, uploadResponse) = try await self.session.upload(for: upload, fromFile: url)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard (200..<300).contains(uploadHTTP.statusCode) else {
            throw GeminiInteractionsResponse.mapHTTPFailure(
                status: uploadHTTP.statusCode, body: uploadBody)
        }
        guard let file = try? JSONDecoder().decode(GeminiFileUploadResponse.self, from: uploadBody),
            let uploaded = file.file, uploaded.uri != nil
        else {
            throw GeminiBatchError.uploadFailed("The upload response did not contain a file URI.")
        }
        return try await self.activeFileURI(for: uploaded, apiKey: apiKey)
    }

    /// A freshly uploaded file starts in `PROCESSING`; referencing its URI before
    /// the Files API reports `ACTIVE` fails the Interactions request. Polls the
    /// file resource until it is usable, or gives up inside a bounded budget.
    private func activeFileURI(
        for file: GeminiUploadedFile,
        apiKey: String
    ) async throws -> String {
        guard let uri = file.uri else {
            throw GeminiBatchError.uploadFailed("The upload response did not contain a file URI.")
        }
        switch file.state?.uppercased() {
        case "ACTIVE":
            return uri
        case "FAILED":
            throw GeminiBatchError.uploadFailed("Google could not process the uploaded recording.")
        default:
            break
        }
        guard let name = file.name,
            let statusURL = GeminiTranscribeModels.fileStatusURL(name: name)
        else {
            throw GeminiBatchError.uploadFailed("The upload response did not name the uploaded file.")
        }

        let deadline = Date().addingTimeInterval(self.filePollTimeout)
        while Date() < deadline {
            try await Task.sleep(
                nanoseconds: UInt64(max(0, self.filePollInterval) * 1_000_000_000))
            switch try await self.fileState(at: statusURL, apiKey: apiKey)?.uppercased() {
            case "ACTIVE":
                return uri
            case "FAILED":
                throw GeminiBatchError.uploadFailed(
                    "Google could not process the uploaded recording.")
            default:
                continue
            }
        }
        throw GeminiBatchError.uploadFailed(
            "The uploaded recording was still processing after \(Int(self.filePollTimeout)) seconds.")
    }

    private func fileState(at url: URL, apiKey: String) async throws -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: GeminiTranscribeModels.apiKeyHeader)

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiInteractionsResponse.mapHTTPFailure(status: http.statusCode, body: data)
        }
        let decoder = JSONDecoder()
        // The status endpoint answers with the File resource itself; the upload
        // endpoint wraps it in `{"file": …}`. Accept either spelling.
        if let file = try? decoder.decode(GeminiUploadedFile.self, from: data), file.state != nil {
            return file.state
        }
        return (try? decoder.decode(GeminiFileUploadResponse.self, from: data))?.file?.state
    }

    private static func assetDuration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite ? seconds : 0
    }
}
