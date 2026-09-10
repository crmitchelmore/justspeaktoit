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
    ///
    /// `timeout` bounds the whole operation *and* each individual attempt: a
    /// `step` that stalls is abandoned at the deadline rather than being left
    /// to URLSession's own, much longer, request and resource limits.
    ///
    /// The timing arguments are validated because this is a public boundary; a
    /// negative or non-finite interval would otherwise spin the loop with no
    /// wait, turning one pending job into unbounded request traffic.
    public static func poll<Value: Sendable>(
        interval: TimeInterval,
        timeout: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void,
        step: @escaping @Sendable () async throws -> Poll<Value>
    ) async throws -> Value {
        guard interval.isFinite, interval >= 0, timeout.isFinite, timeout > 0 else {
            throw BatchTranscriptionJobError.invalidPollingSchedule
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            try Task.checkCancellation()
            if case .finished(let value) = try await Self.attempt(step, before: deadline) {
                return value
            }
            guard Date() < deadline else { throw BatchTranscriptionJobError.timedOut }
            try Task.checkCancellation()
            try await sleep(interval)
        }
    }

    /// One polling attempt, raced against the operation's deadline so an
    /// in-flight request cannot outlive it. Losing the race cancels the
    /// attempt, which cancels the underlying URLSession task.
    private static func attempt<Value: Sendable>(
        _ step: @escaping @Sendable () async throws -> Poll<Value>,
        before deadline: Date
    ) async throws -> Poll<Value> {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw BatchTranscriptionJobError.timedOut }
        return try await withThrowingTaskGroup(of: Poll<Value>.self) { group in
            group.addTask { try await step() }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.nanoseconds(remaining))
                throw BatchTranscriptionJobError.timedOut
            }
            defer { group.cancelAll() }
            guard let outcome = try await group.next() else {
                throw BatchTranscriptionJobError.timedOut
            }
            return outcome
        }
    }

    /// Seconds as nanoseconds, clamped so a very large interval saturates
    /// rather than trapping on the `UInt64` conversion.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        let nanoseconds = (max(0, seconds) * 1_000_000_000).rounded()
        guard nanoseconds.isFinite else { return .max }
        return nanoseconds >= Double(UInt64.max) ? .max : UInt64(nanoseconds)
    }

    /// The default wait between polls, backed by `Task.sleep` so a cancelled
    /// task stops waiting straight away.
    public static let defaultSleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: BatchTranscriptionJob.nanoseconds(seconds))
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

    /// Rejects a non-2xx response as `TranscriptionProviderError.httpError`,
    /// which is the vocabulary the rest of the app already renders: the iOS
    /// routes re-map it to `IOSBatchTranscriptionError.httpError` with the
    /// provider name, and macOS shows the status and body. Authentication (401,
    /// 403) and quota (402, 429) failures therefore reach the user as the
    /// provider's own message rather than being flattened into one string here.
    public static func validate(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard !(200..<300).contains(http.statusCode) else { return }
        throw TranscriptionProviderError.httpError(
            http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    /// `URLError.cancelled` from a cancelled upload is a cancellation, not a
    /// network failure; callers use this so both spellings reach the UI as one.
    public static func mapCancellation(_ error: Error) -> Error {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return CancellationError()
        }
        return error
    }

    /// True when `error` means this client is walking away from a job the
    /// provider has already accepted: cancellation in either spelling, or the
    /// local polling deadline. Those are exactly the cases where a paid job
    /// would otherwise keep running with nobody left to read it, so the client
    /// should make a best-effort cancellation before it returns.
    public static func abandonsAcceptedJob(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return (error as? BatchTranscriptionJobError) == .timedOut
    }

    // MARK: - Credential boundary

    /// True when `url` sits on the same scheme, host and port as `origin`.
    ///
    /// Batch clients carry a reusable account key on every request, so a URL
    /// that arrives inside a provider response — Gladia's `result_url`, or any
    /// redirect target — may only be requested with that key attached when it
    /// is still the provider's own endpoint. Comparison is case-insensitive on
    /// scheme and host and treats an omitted port as the scheme's default.
    public static func isSameOrigin(_ url: URL, as origin: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              let originScheme = origin.scheme?.lowercased(), let originHost = origin.host?.lowercased()
        else { return false }
        guard scheme == originScheme, host == originHost else { return false }
        return (url.port ?? Self.defaultPort(for: scheme)) == (origin.port ?? Self.defaultPort(for: originScheme))
    }

    private static func defaultPort(for scheme: String) -> Int? {
        ["https": 443, "http": 80, "wss": 443, "ws": 80][scheme]
    }

    /// Refuses any redirect that would leave `origin`. Without it a 302 from a
    /// compromised provider response would walk an authenticated request — and
    /// the account key in its headers — onto an attacker's host, because a
    /// custom credential header such as `x-gladia-key` is not one URLSession
    /// strips on a cross-origin hop. Declining the redirect delivers the 3xx
    /// itself, which `validate(_:data:provider:)` then rejects.
    public final class OriginBoundRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let origin: URL

        public init(origin: URL) {
            self.origin = origin
            super.init()
        }

        public func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url, BatchTranscriptionJob.isSameOrigin(url, as: self.origin) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
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
    case jobFailed(String, String)
    case emptyTranscript(String)
    case timedOut
    case invalidPollingSchedule

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let provider):
            return "That model is not a \(provider) file-transcription model."
        case .unsupportedAudioFormat(let provider):
            return "\(provider) needs a WAV, M4A, MP3, MP4, AAC, Ogg, Opus, FLAC, or WebM recording."
        case .jobFailed(let provider, let message):
            return message.isEmpty
                ? "\(provider) could not transcribe the recording."
                : "\(provider) could not transcribe the recording: \(message)"
        case .emptyTranscript(let provider):
            return "\(provider) returned no speech for this recording."
        case .timedOut:
            return "The transcription job did not finish in time."
        case .invalidPollingSchedule:
            return "The transcription job was given an invalid polling interval or timeout."
        }
    }
}
