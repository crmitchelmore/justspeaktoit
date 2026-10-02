import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Soniox asynchronous file transcription, shared by native desktop adapters.
public struct SonioxBatchClient: TranscriptionProvider {
    public let metadata = TranscriptionProviderMetadata(
        id: "soniox",
        displayName: "Soniox",
        systemImage: "waveform.badge.magnifyingglass",
        tintColor: "indigo",
        website: "https://soniox.com"
    )

    private let session: URLSession
    private let baseURL = URL(string: "https://api.soniox.com/v1")!
    private let pollingDelay: Duration
    private let maximumPollingAttempts: Int
    private let multipartStaging: SharedMultipartUploadStaging
    private let reportCleanupFailure: @Sendable (String) -> Void
    var cleanupTimeout: TimeInterval = 10

    public init(
        session: URLSession = .shared,
        pollingDelay: Duration = .seconds(2),
        maximumPollingAttempts: Int = 90,
        multipartStaging: SharedMultipartUploadStaging,
        reportCleanupFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.session = session
        self.pollingDelay = pollingDelay
        self.maximumPollingAttempts = maximumPollingAttempts
        self.multipartStaging = multipartStaging
        self.reportCleanupFailure = reportCleanupFailure
    }

    public func transcribeFile(
        at url: URL, apiKey: String, model: String, language: String?
    ) async throws -> TranscriptionResult {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportedModels().contains(where: { $0.id == model }) else {
            throw SonioxBatchError.unsupportedModel
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranscriptionProviderError.apiKeyMissing }
        try Task.checkCancellation()
        let file: SonioxFile
        do { file = try await self.uploadFile(at: url, apiKey: key) } catch {
            throw BatchTranscriptionJob.mapCancellation(error)
        }
        var transcriptionID: String?
        let result: TranscriptionResult
        do {
            // Keep every acknowledged ID before observing cancellation, so
            // a cancelled task can still delete resources the server accepted.
            try Task.checkCancellation()
            let transcription = try await self.createTranscription(
                fileID: file.id, apiKey: key, model: model, language: language
            )
            transcriptionID = transcription.id
            try Task.checkCancellation()
            let completed = try await self.waitForCompletion(id: transcription.id, apiKey: key)
            let transcript = try await self.fetchTranscript(id: transcription.id, apiKey: key)
            result = self.buildTranscriptionResult(transcript: transcript, transcription: completed, model: model)
            try Task.checkCancellation()
        } catch {
            await self.cleanupRemoteResources(transcriptionID: transcriptionID, fileID: file.id, apiKey: key)
            throw BatchTranscriptionJob.mapCancellation(error)
        }
        await self.cleanupRemoteResources(transcriptionID: transcriptionID, fileID: file.id, apiKey: key)
        try Task.checkCancellation()
        return result
    }

    public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(message: "Empty API key")
        }
        // Lightweight validation: hit the temporary-key endpoint with a tiny duration.
        guard let url = URL(string: "https://api.soniox.com/v1/auth/temporary-api-key") else {
            return .failure(message: "Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"usage_type":"transcribe_websocket","expires_in_seconds":60}"#.utf8)

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(message: "Non-HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .success(message: "Soniox API key validated")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return .failure(message: "Soniox rejected the key (HTTP \(http.statusCode))")
            }
            return .failure(message: "HTTP \(http.statusCode) while validating key")
        } catch {
            return .failure(message: "Validation failed: \(error.localizedDescription)")
        }
    }

    public func requiresAPIKey(for model: String) -> Bool { true }

    public func supportedModels() -> [ModelCatalog.Option] {
        ModelCatalog.batchTranscriptionOptions(forProvider: metadata.id)
    }

    private func uploadFile(at url: URL, apiKey: String) async throws -> SonioxFile {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("files"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let uploadBodyURL = try self.multipartStaging.writeMultipart(
            sourceURL: url, providerID: metadata.id, boundary: boundary, fields: [], mimeType: self.mimeType(for: url)
        )
        defer { self.multipartStaging.removeUploadBodyFile(at: uploadBodyURL) }

        let data = try await self.upload(request, fromFile: uploadBodyURL)
        return try JSONDecoder().decode(SonioxFile.self, from: data)
    }

    private func createTranscription(
        fileID: String,
        apiKey: String,
        model: String,
        language: String?
    ) async throws -> SonioxFile {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = SonioxCreateTranscriptionPayload(
            model: self.extractModelName(from: model),
            fileID: fileID,
            languageHints: language.map { [$0.localeLanguageCode] },
            enableSpeakerDiarization: true,
            enableLanguageIdentification: true
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let data = try await self.send(request, expectedStatusCodes: 200..<300)
        // The create response only needs its ID. A missing/noncanonical status
        // must not prevent cleanup of a job that was already accepted.
        return try JSONDecoder().decode(SonioxFile.self, from: data)
    }

    private func waitForCompletion(id: String, apiKey: String) async throws -> SonioxTranscription {
        guard maximumPollingAttempts > 0 else { throw SonioxBatchError.transcriptionTimedOut }
        for _ in 0..<maximumPollingAttempts {
            try Task.checkCancellation()
            let transcription = try await self.fetchTranscription(id: id, apiKey: apiKey)
            switch transcription.status {
            case "completed":
                return transcription
            case "error":
                throw SonioxBatchError.transcriptionFailed(
                    transcription.errorMessage ?? transcription.errorType ?? "Unknown error"
                )
            default:
                try await Task.sleep(for: pollingDelay)
            }
        }
        throw SonioxBatchError.transcriptionTimedOut
    }

    private func fetchTranscription(id: String, apiKey: String) async throws -> SonioxTranscription {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcriptions/\(id)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await self.send(request)
        return try JSONDecoder().decode(SonioxTranscription.self, from: data)
    }

    private func fetchTranscript(id: String, apiKey: String) async throws -> SonioxTranscript {
        var request = URLRequest(url: baseURL.appendingPathComponent("transcriptions/\(id)/transcript"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await self.send(request)
        return try JSONDecoder().decode(SonioxTranscript.self, from: data)
    }

    private func cleanupRemoteResources(transcriptionID: String?, fileID: String, apiKey: String) async {
        // Detached cleanup survives cancellation of the recording. Every known
        // resource gets its own bounded attempt; a failed job DELETE must not
        // prevent the uploaded recording's DELETE.
        await Task.detached {
            let paths = transcriptionID.map { ["transcriptions/\($0)", "files/\(fileID)"] } ?? ["files/\(fileID)"]
            for path in paths {
                var request = URLRequest(url: self.baseURL.appendingPathComponent(path))
                request.httpMethod = "DELETE"
                request.timeoutInterval = self.cleanupTimeout
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let deletion = request
                do {
                    let _: Void = try await BatchTranscriptionJob.poll(
                        interval: 0, timeout: self.cleanupTimeout, sleep: BatchTranscriptionJob.defaultSleep
                    ) {
                        _ = try await self.send(deletion)
                        return .finished(())
                    }
                } catch { self.reportCleanupFailure(error.localizedDescription) }
            }
        }.value
    }

    private func send(
        _ request: URLRequest,
        expectedStatusCodes: Range<Int> = 200..<300
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard expectedStatusCodes.contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw TranscriptionProviderError.httpError(http.statusCode, body)
        }
        return data
    }

    private func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> Data {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no-body>"
            throw TranscriptionProviderError.httpError(http.statusCode, body)
        }
        return data
    }

    private func mimeType(for url: URL) -> String {
        let mimeTypes = [
            "aac": "audio/aac",
            "aiff": "audio/aiff",
            "aif": "audio/aiff",
            "flac": "audio/flac",
            "mov": "video/quicktime",
            "mp3": "audio/mpeg",
            "mp4": "audio/mp4",
            "m4a": "audio/mp4",
            "ogg": "audio/ogg",
            "opus": "audio/opus",
            "wav": "audio/wav",
            "webm": "audio/webm"
        ]
        return mimeTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }

    private func extractModelName(from model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}
