import Foundation

/// Shared plumbing for provider batch APIs that transcribe as an asynchronous
/// job: upload the recording, start the job, poll until a terminal state, then
/// read the transcript.
///
/// Gladia and Speechmatics both work this way, so the multipart snapshot, the
/// polling loop and the HTTP failure vocabulary live here instead of being
/// written twice. Cartesia's `/stt` endpoint answers in one round trip and
/// keeps its own client.
public enum BatchTranscriptionJob {

    /// One poll of a job: still running, or finished with a value.
    public enum Poll<Value: Sendable>: Sendable {
        case pending
        case finished(Value)
    }

    /// Polls `step` until it reports a value. Cancellation is checked both
    /// before each attempt and before each wait, so cancelling dictation stops
    /// the polling immediately rather than at the end of the current interval.
    public static func poll<Value: Sendable>(
        interval: TimeInterval,
        timeout: TimeInterval,
        sleep: @Sendable (TimeInterval) async throws -> Void,
        step: @Sendable () async throws -> Poll<Value>
    ) async throws -> Value {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if case .finished(let value) = try await step() {
                return value
            }
            guard Date() < deadline else { throw BatchTranscriptionJobError.timedOut }
            try Task.checkCancellation()
            try await sleep(interval)
        }
    }

    /// The default wait between polls, backed by `Task.sleep` so a cancelled
    /// task stops waiting straight away.
    public static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// The recording part of a multipart body.
    public struct FilePart: Sendable {
        public let field: String
        public let filename: String
        public let mimeType: String
        public let source: URL

        public init(field: String, filename: String, mimeType: String, source: URL) {
            self.field = field
            self.filename = filename
            self.mimeType = mimeType
            self.source = source
        }
    }

    /// Writes a `multipart/form-data` body to a private temporary file, copying
    /// the recording in 64 KiB chunks so a long dictation is never held in
    /// memory as well as on disk. Upload it with
    /// `URLSession.upload(for:fromFile:)`, then call `discard(_:)`.
    public static func writeMultipart(
        fields: [(name: String, value: String)],
        file part: FilePart,
        boundary: String
    ) throws -> URL {
        var header = Data()
        for field in fields {
            header.appendFormField(named: field.name, value: field.value, boundary: boundary)
        }
        header.appendString("--\(boundary)\r\n")
        header.appendString(
            "Content-Disposition: form-data; name=\"\(part.field)\"; filename=\"\(part.filename)\"\r\n")
        header.appendString("Content-Type: \(part.mimeType)\r\n\r\n")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("upload.multipart")
        do {
            try header.write(to: file)
            let input = try FileHandle(forReadingFrom: part.source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            try output.seekToEnd()
            while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Removes a multipart snapshot and the private directory holding it. The
    /// recording itself is never touched.
    public static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    /// Maps a response onto the shared failure vocabulary so authentication and
    /// quota problems are named rather than surfacing as a bare status code.
    public static func validate(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 401, 403:
            throw BatchTranscriptionJobError.authenticationFailed(provider)
        case 402, 429:
            throw BatchTranscriptionJobError.quotaExceeded(provider)
        default:
            throw TranscriptionProviderError.httpError(http.statusCode, body)
        }
    }

    /// `URLError.cancelled` from a cancelled upload is a cancellation, not a
    /// network failure; callers use this so both spellings reach the UI as one.
    public static func mapCancellation(_ error: Error) -> Error {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        return error
    }

    /// Content types for the containers the recorder and the file importer can
    /// produce. Both providers sniff the container themselves, but an accurate
    /// part header avoids a rejected upload.
    public static func mimeType(for url: URL) -> String? {
        [
            "aac": "audio/aac", "flac": "audio/flac", "m4a": "audio/mp4", "mp3": "audio/mpeg",
            "mp4": "audio/mp4", "mpeg": "audio/mpeg", "mpga": "audio/mpeg", "oga": "audio/ogg",
            "ogg": "audio/ogg", "opus": "audio/ogg", "wav": "audio/wav", "webm": "audio/webm"
        ][url.pathExtension.lowercased()]
    }

    /// The language code a provider config wants, or `nil` when the recording
    /// language is unset or explicitly automatic.
    public static func languageCode(from language: String?) -> String? {
        let normalized = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalized.isEmpty, normalized != "auto", normalized != "automatic" else { return nil }
        guard let code = normalized.split(whereSeparator: { $0 == "-" || $0 == "_" }).first else { return nil }
        return String(code)
    }
}

extension BatchTranscriptionJob.Poll: Equatable where Value: Equatable {}

/// Failures shared by the asynchronous batch job clients.
public enum BatchTranscriptionJobError: LocalizedError, Equatable {
    case unsupportedModel(String)
    case unsupportedAudioFormat(String)
    case authenticationFailed(String)
    case quotaExceeded(String)
    case jobFailed(String, String)
    case emptyTranscript(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let provider):
            return "That model is not a \(provider) file-transcription model."
        case .unsupportedAudioFormat(let provider):
            return "\(provider) needs a WAV, M4A, MP3, MP4, AAC, Ogg, Opus, FLAC, or WebM recording."
        case .authenticationFailed(let provider):
            return "\(provider) rejected the API key. Check it in Settings → \(provider)."
        case .quotaExceeded(let provider):
            return "\(provider) reported no remaining quota or credit for this account."
        case .jobFailed(let provider, let message):
            return message.isEmpty
                ? "\(provider) could not transcribe the recording."
                : "\(provider) could not transcribe the recording: \(message)"
        case .emptyTranscript(let provider):
            return "\(provider) returned no speech for this recording."
        case .timedOut:
            return "The transcription job did not finish in time."
        }
    }
}
