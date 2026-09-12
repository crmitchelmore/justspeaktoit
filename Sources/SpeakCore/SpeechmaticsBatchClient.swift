import Foundation

/// Speechmatics' asynchronous Jobs API: `POST /v2/jobs` with the recording and a
/// transcription config, poll `GET /v2/jobs/{id}` until the job leaves
/// `running`, then read `GET /v2/jobs/{id}/transcript?format=json-v2`.
///
/// Contract: https://docs.speechmatics.com/speech-to-text/batch (read
/// 2026-09-09). The same `speechmatics.apiKey` the live provider stores is used
/// here, on the same `eu1` host the key validator already probes; Speechmatics
/// issues one account key covering realtime and batch, so no extra credential
/// is required. An account provisioned in another region needs the host
/// changed, which is why `baseURL` is injectable.
public struct SpeechmaticsBatchClient: Sendable {
    public static let providerName = "Speechmatics"
    public static let enhancedCatalogID = "speechmatics/enhanced"
    public static let standardCatalogID = "speechmatics/standard"
    public static let catalogIDs: Set<String> = [enhancedCatalogID, standardCatalogID]
    public static let defaultBaseURL = URL(string: "https://eu1.asr.api.speechmatics.com")!

    var upload: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    var sleep: @Sendable (TimeInterval) async throws -> Void = BatchTranscriptionJob.defaultSleep
    var pollInterval: TimeInterval = 2
    var timeout: TimeInterval = 900
    let baseURL: URL

    public init(session: URLSession = .shared, baseURL: URL = SpeechmaticsBatchClient.defaultBaseURL) {
        self.baseURL = baseURL
        // The bearer key must not follow a redirect off the Speechmatics
        // origin; declining the hop delivers the 3xx, which `validate` rejects.
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
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.catalogIDs.contains(modelID) else {
            throw BatchTranscriptionJobError.unsupportedModel(Self.providerName)
        }
        try Task.checkCancellation()
        let jobID = try await self.createJob(at: url, apiKey: key, model: modelID, language: language)
        // Speechmatics has accepted a job that bills until it finishes, so
        // every abandonment from here -- including a cancellation observed the
        // instant the create response lands -- must try to delete it.
        do {
            try Task.checkCancellation()
            try await self.awaitCompletion(jobID: jobID, apiKey: key)
            return try await self.fetchTranscript(jobID: jobID, apiKey: key, model: modelID)
        } catch {
            let abandonment = BatchTranscriptionJob.mapCancellation(error)
            if BatchTranscriptionJob.abandonsAcceptedJob(abandonment) {
                await self.deleteJob(jobID, apiKey: key)
            }
            throw abandonment
        }
    }

    // MARK: - Steps

    /// Step 1. One multipart request carries both the JSON config and the
    /// recording; Speechmatics answers with the job id.
    private func createJob(at url: URL, apiKey: String, model: String, language: String?) async throws -> String {
        guard let mimeType = BatchTranscriptionJob.mimeType(for: url) else {
            throw BatchTranscriptionJobError.unsupportedAudioFormat(Self.providerName)
        }
        let boundary = "Speechmatics-\(UUID().uuidString)"
        var request = URLRequest(url: self.baseURL.appendingPathComponent("v2/jobs"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let file = try BatchTranscriptionJob.writeMultipart(
            fields: [(name: "config", value: try Self.configJSON(model: model, language: language))],
            file: .init(
                field: "data_file", filename: "recording.\(url.pathExtension.lowercased())",
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
        // No cancellation check here: once the response is in hand the job id
        // must reach the caller, or the created job can never be deleted.
        try BatchTranscriptionJob.validate(response, data: data, provider: Self.providerName)
        return try Self.decodeJobID(data)
    }

    /// Step 2. `running` keeps polling; `done` proceeds; `rejected`, `deleted`
    /// and `expired` are terminal failures rather than a wait for the timeout.
    private func awaitCompletion(jobID: String, apiKey: String) async throws {
        var request = URLRequest(url: self.baseURL.appendingPathComponent("v2/jobs/\(jobID)"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let poll = request
        _ = try await BatchTranscriptionJob.poll(
            interval: self.pollInterval, timeout: self.timeout, sleep: self.sleep
        ) {
            let (data, response) = try await self.send(poll)
            try BatchTranscriptionJob.validate(response, data: data, provider: Self.providerName)
            return try Self.decodeStatus(data)
        }
    }

    /// Step 3. The finished transcript, in the documented `json-v2` shape.
    private func fetchTranscript(jobID: String, apiKey: String, model: String) async throws -> TranscriptionResult {
        var components = URLComponents(
            url: self.baseURL.appendingPathComponent("v2/jobs/\(jobID)/transcript"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "format", value: "json-v2")]
        guard let url = components?.url else { throw TranscriptionProviderError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.send(request)
        } catch {
            throw BatchTranscriptionJob.mapCancellation(error)
        }
        try Task.checkCancellation()
        try BatchTranscriptionJob.validate(response, data: data, provider: Self.providerName)
        return try Self.decodeTranscript(data, model: model)
    }

    /// Best effort: a cancelled dictation should not leave a job running that
    /// nobody will read. A failure here is deliberately swallowed.
    ///
    /// The request runs detached because the usual reason to be here is that
    /// this task is already cancelled, and URLSession fails a request started
    /// on a cancelled task immediately.
    private func deleteJob(_ jobID: String, apiKey: String) async {
        var components = URLComponents(
            url: self.baseURL.appendingPathComponent("v2/jobs/\(jobID)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "force", value: "true")]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let send = self.send
        let deletion = request
        _ = await Task.detached { _ = try? await send(deletion) }.value
    }

    // MARK: - Wire format

    /// `operating_point` selects the quality tier. Speechmatics documents
    /// `auto` as the language-identification value, which is what "Automatic"
    /// in the picker maps to.
    static func configJSON(model: String, language: String?) throws -> String {
        let tier = model == Self.standardCatalogID ? "standard" : "enhanced"
        let config: [String: Any] = [
            "type": "transcription",
            "transcription_config": [
                "language": BatchTranscriptionJob.languageCode(from: language) ?? "auto",
                "operating_point": tier
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: config)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TranscriptionProviderError.invalidResponse
        }
        return json
    }

    static func decodeJobID(_ data: Data) throws -> String {
        struct Response: Decodable { let id: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.id.isEmpty else {
            throw TranscriptionProviderError.invalidResponse
        }
        return response.id
    }

    static func decodeStatus(_ data: Data) throws -> BatchTranscriptionJob.Poll<String> {
        struct Job: Decodable {
            let status: String
            let errors: [JobError]?
        }
        struct JobError: Decodable { let message: String? }
        struct Response: Decodable { let job: Job }
        guard let job = (try? JSONDecoder().decode(Response.self, from: data))?.job else {
            throw TranscriptionProviderError.invalidResponse
        }
        switch job.status {
        case "done":
            return .finished(job.status)
        case "rejected", "deleted", "expired":
            let message = job.errors?.compactMap(\.message).joined(separator: "; ") ?? ""
            throw BatchTranscriptionJobError.jobFailed(
                Self.providerName, message.isEmpty ? job.status : message)
        default:
            return .pending
        }
    }

    /// json-v2 is a flat item list. Punctuation carries `attaches_to`, so words
    /// are joined with spaces and punctuation is appended to the word it
    /// attaches to; only `word` items become timed segments.
    ///
    /// Both attachment directions are honoured: `previous` punctuation (a full
    /// stop, a closing bracket) follows its word with no space, and `next`
    /// punctuation (an opening bracket or quote) takes the space *before* it
    /// and suppresses the one that would otherwise follow, so an opening
    /// parenthesis reads `Hello (world` rather than `Hello ( world`.
    static func decodeTranscript(_ data: Data, model: String) throws -> TranscriptionResult {
        struct Alternative: Decodable {
            let content: String
            let confidence: Double?
        }
        struct Item: Decodable {
            let type: String?
            let startTime: Double?
            let endTime: Double?
            let attachesTo: String?
            let alternatives: [Alternative]?
        }
        struct Job: Decodable { let duration: Double? }
        struct Response: Decodable {
            let job: Job?
            let results: [Item]?
        }
        guard let response = try? Self.decoder.decode(Response.self, from: data), let items = response.results else {
            throw TranscriptionProviderError.invalidResponse
        }

        var text = ""
        var segments: [TranscriptionSegment] = []
        var confidences: [Double] = []
        var attachesToFollowing = false
        for item in items {
            guard let alternative = item.alternatives?.first else { continue }
            let isPunctuation = item.type == "punctuation"
            if isPunctuation, item.attachesTo != "next" {
                text += alternative.content
                continue
            }
            if !text.isEmpty, !attachesToFollowing { text += " " }
            text += alternative.content
            attachesToFollowing = isPunctuation
            if !isPunctuation {
                segments.append(TranscriptionSegment(
                    startTime: item.startTime ?? 0, endTime: item.endTime ?? 0, text: alternative.content))
                if let confidence = alternative.confidence { confidences.append(confidence) }
            }
        }

        return TranscriptionResult(
            text: text,
            segments: segments,
            confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count),
            duration: response.job?.duration ?? segments.map(\.endTime).max() ?? 0,
            modelIdentifier: model,
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
