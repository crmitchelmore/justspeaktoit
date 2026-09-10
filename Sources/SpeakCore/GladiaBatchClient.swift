import Foundation

/// Gladia's asynchronous pre-recorded API: upload the recording to `/v2/upload`,
/// start a job on `/v2/pre-recorded`, then poll the job's `result_url` until it
/// is `done` or `error`.
///
/// Contract: https://docs.gladia.io/api-reference/v2/pre-recorded/init and
/// .../pre-recorded/get (read 2026-09-09). The same `gladia.apiKey` the live
/// Solaria provider stores is used here; Gladia issues one account key for
/// both surfaces, so no extra credential or endpoint is required.
public struct GladiaBatchClient: Sendable {
    public static let catalogID = "gladia/solaria-1"
    public static let providerName = "Gladia"
    static let modelName = "solaria-1"
    public static let defaultBaseURL = URL(string: "https://api.gladia.io")!

    var upload: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    var sleep: @Sendable (TimeInterval) async throws -> Void = BatchTranscriptionJob.defaultSleep
    var pollInterval: TimeInterval = 2
    var timeout: TimeInterval = 900
    let baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = GladiaBatchClient.defaultBaseURL) {
        self.baseURL = baseURL
        // Every request below carries `x-gladia-key`, which URLSession does not
        // strip on a cross-origin redirect the way it does `Authorization`.
        // The guard keeps the key inside the Gladia endpoint boundary.
        let redirects = BatchTranscriptionJob.OriginBoundRedirects(origin: baseURL)
        self.upload = { request, file in
            try await session.upload(for: request, fromFile: file, delegate: redirects)
        }
        self.send = { request in try await session.data(for: request, delegate: redirects) }
    }

    public func transcribeFile(
        at url: URL,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> TranscriptionResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        guard model.trimmingCharacters(in: .whitespacesAndNewlines) == Self.catalogID else {
            throw BatchTranscriptionJobError.unsupportedModel(Self.providerName)
        }
        try Task.checkCancellation()
        let audioURL = try await self.uploadRecording(at: url, apiKey: key)
        let job = try await self.startJob(audioURL: audioURL, apiKey: key, language: language)
        // From here Gladia has accepted a job that will consume credit until it
        // finishes, so every path that abandons it must try to cancel it --
        // including a cancellation observed the instant the create response
        // lands, which is why the check below sits inside the `do`.
        do {
            try Task.checkCancellation()
            return try await self.awaitTranscript(job: job, apiKey: key)
        } catch {
            let abandonment = BatchTranscriptionJob.mapCancellation(error)
            if BatchTranscriptionJob.abandonsAcceptedJob(abandonment) {
                await self.cancelJob(job, apiKey: key)
            }
            throw abandonment
        }
    }

    // MARK: - Steps

    /// Step 1. Gladia takes the bytes on `/v2/upload` and answers with the
    /// `audio_url` the job then references.
    private func uploadRecording(at url: URL, apiKey: String) async throws -> String {
        guard let mimeType = BatchTranscriptionJob.mimeType(for: url) else {
            throw BatchTranscriptionJobError.unsupportedAudioFormat(Self.providerName)
        }
        let boundary = "Gladia-\(UUID().uuidString)"
        var request = URLRequest(url: self.baseURL.appendingPathComponent("v2/upload"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let file = try BatchTranscriptionJob.writeMultipart(
            fields: [],
            file: .init(
                field: "audio", filename: "recording.\(url.pathExtension.lowercased())",
                mimeType: mimeType, source: url),
            boundary: boundary)
        defer { BatchTranscriptionJob.discard(file) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.upload(request, file)
        } catch {
            throw BatchTranscriptionJob.mapCancellation(error)
        }
        try Task.checkCancellation()
        try BatchTranscriptionJob.validate(response, data: data, provider: Self.providerName)
        return try Self.decodeUpload(data)
    }

    /// Step 2. Start the job. An empty `languages` array is Gladia's documented
    /// way to ask for detection, so "Automatic" stays automatic.
    private func startJob(audioURL: String, apiKey: String, language: String?) async throws -> Job {
        var request = URLRequest(url: self.baseURL.appendingPathComponent("v2/pre-recorded"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(audioURL: audioURL, language: language))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.send(request)
        } catch {
            throw BatchTranscriptionJob.mapCancellation(error)
        }
        // No cancellation check here: once the response is in hand the job id
        // must reach the caller, or the created job can never be cancelled.
        try BatchTranscriptionJob.validate(response, data: data, provider: Self.providerName)
        return try Self.decodeJob(data, baseURL: self.baseURL)
    }

    /// Step 3. Poll the job. `queued` and `processing` are the running states;
    /// `done` and `error` are terminal.
    private func awaitTranscript(job: Job, apiKey: String) async throws -> TranscriptionResult {
        var request = URLRequest(url: job.resultURL)
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        let poll = request
        let payload = try await BatchTranscriptionJob.poll(
            interval: self.pollInterval, timeout: self.timeout, sleep: self.sleep
        ) {
            let (data, response) = try await self.send(poll)
            try BatchTranscriptionJob.validate(response, data: data, provider: Self.providerName)
            return try Self.decodeStatus(data)
        }
        return try Self.decodeTranscript(payload)
    }

    /// Best effort: a cancelled dictation should not leave Gladia billing for a
    /// job nobody will read. A failure here is deliberately swallowed.
    ///
    /// The request runs detached because the usual reason to be here is that
    /// this task is already cancelled, and URLSession fails a request started
    /// on a cancelled task immediately -- the cleanup would never leave the
    /// device.
    private func cancelJob(_ job: Job, apiKey: String) async {
        guard let id = job.id else { return }
        var request = URLRequest(url: self.baseURL.appendingPathComponent("v2/pre-recorded/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-gladia-key")
        let send = self.send
        let cancelled = request
        _ = await Task.detached { _ = try? await send(cancelled) }.value
    }

    // MARK: - Wire format

    struct Job: Equatable, Sendable {
        let id: String?
        let resultURL: URL
    }

    static func requestBody(audioURL: String, language: String?) -> [String: Any] {
        var body: [String: Any] = ["audio_url": audioURL, "model": Self.modelName]
        let languages = BatchTranscriptionJob.languageCode(from: language).map { [$0] } ?? []
        body["language_config"] = ["languages": languages, "code_switching": languages.isEmpty]
        return body
    }

    // `convertFromSnakeCase` maps `audio_url` to `audioUrl`, so the wire types
    // below spell it that way rather than `audioURL`.
    static func decodeUpload(_ data: Data) throws -> String {
        struct Response: Decodable { let audioUrl: String }
        guard let response = try? Self.decoder.decode(Response.self, from: data),
              !response.audioUrl.isEmpty else {
            throw TranscriptionProviderError.invalidResponse
        }
        return response.audioUrl
    }

    /// The job response's `result_url` is polled with `x-gladia-key` attached,
    /// so it is only honoured while it stays on the configured Gladia origin.
    /// A `result_url` pointing anywhere else is discarded rather than trusted:
    /// the documented status endpoint is derived from the job id instead, and
    /// a response that offers neither is an invalid response. Gladia's own
    /// `result_url` is `<baseURL>/v2/pre-recorded/{id}`, so this costs nothing
    /// in normal operation and denies a compromised or spoofed job response the
    /// ability to collect the account key.
    static func decodeJob(_ data: Data, baseURL: URL) throws -> Job {
        struct Response: Decodable {
            let id: String?
            let resultUrl: String?
        }
        guard let response = try? Self.decoder.decode(Response.self, from: data) else {
            throw TranscriptionProviderError.invalidResponse
        }
        if let resultUrl = response.resultUrl, let url = URL(string: resultUrl),
           BatchTranscriptionJob.isSameOrigin(url, as: baseURL) {
            return Job(id: response.id, resultURL: url)
        }
        guard let id = response.id else { throw TranscriptionProviderError.invalidResponse }
        return Job(id: id, resultURL: baseURL.appendingPathComponent("v2/pre-recorded/\(id)"))
    }

    /// `queued`/`processing` keep polling; `error` fails now rather than after
    /// the timeout; anything unrecognised is treated as still running so a new
    /// intermediate state cannot abort a job that is going to succeed.
    static func decodeStatus(_ data: Data) throws -> BatchTranscriptionJob.Poll<Data> {
        struct Response: Decodable {
            let status: String
            let errorCode: Int?
        }
        guard let response = try? Self.decoder.decode(Response.self, from: data) else {
            throw TranscriptionProviderError.invalidResponse
        }
        switch response.status {
        case "done":
            return .finished(data)
        case "error":
            let code = response.errorCode.map { "HTTP \($0)" } ?? ""
            throw BatchTranscriptionJobError.jobFailed(Self.providerName, code)
        default:
            return .pending
        }
    }

    static func decodeTranscript(_ data: Data) throws -> TranscriptionResult {
        struct Utterance: Decodable {
            let start: Double?
            let end: Double?
            let text: String
            let confidence: Double?
        }
        struct Transcription: Decodable {
            let fullTranscript: String?
            let utterances: [Utterance]?
        }
        struct Metadata: Decodable { let audioDuration: Double? }
        struct Result: Decodable {
            let transcription: Transcription?
            let metadata: Metadata?
        }
        struct Response: Decodable { let result: Result? }

        guard let result = (try? Self.decoder.decode(Response.self, from: data))?.result,
              let transcription = result.transcription else {
            throw TranscriptionProviderError.invalidResponse
        }
        let utterances = transcription.utterances ?? []
        let text = transcription.fullTranscript
            ?? utterances.map(\.text).joined(separator: " ")
        let segments = utterances.map {
            TranscriptionSegment(startTime: $0.start ?? 0, endTime: $0.end ?? 0, text: $0.text)
        }
        let confidences = utterances.compactMap(\.confidence)
        let duration = result.metadata?.audioDuration ?? utterances.compactMap(\.end).max() ?? 0
        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            duration: duration,
            modelIdentifier: Self.catalogID,
            cost: nil,
            rawPayload: String(data: data, encoding: .utf8),
            debugInfo: nil
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
