import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Gemini Files API lifecycle for a recording too large to send inline:
/// a resumable upload, then polling until the file is ACTIVE within one
/// processing budget. Never logs audio or the API key.
struct GeminiFilesAPI: Sendable {
    let session: URLSession
    let pollInterval: TimeInterval
    let pollTimeout: TimeInterval
    let uploadRecording: @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

    /// Resumable upload used when the recording is too large to inline. Returns
    /// the `file.uri` the Interactions request references.
    func upload(
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
        let (uploadBody, uploadResponse) = try await self.uploadRecording(upload, url)
        // The private snapshot is no longer needed once transfer completes.
        // Release its disk space before provider processing and transcription.
        try? FileManager.default.removeItem(at: url)
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

        let timeout = try Self.processingBudget(for: self.pollTimeout)
        let interval = self.pollInterval.isFinite ? max(0.01, self.pollInterval) : 1
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        // Race the entire operation, including an in-flight URLSession request,
        // against one monotonic deadline. Cancelling the losing child cancels I/O.
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await clock.sleep(until: deadline)
                throw Self.processingTimeout
            }
            group.addTask {
                try await self.pollUntilActive(
                    at: statusURL, apiKey: apiKey, uri: uri,
                    // Bound before constructing Duration: even a finite Double
                    // can overflow its integer representation and trap.
                    interval: min(interval, max(0.01, timeout)), deadline: deadline, clock: clock
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Self.processingTimeout }
            return result
        }
    }

    /// Preserve finite multi-day budgets. A nonfinite value falls back to the
    /// default budget; a finite value too large for a clock duration is rejected
    /// explicitly rather than silently replacing the configured deadline.
    static func processingBudget(for timeout: TimeInterval) throws -> TimeInterval {
        guard timeout.isFinite else { return 60 }
        guard timeout < Double(Int64.max) / 4 else {
            throw GeminiBatchError.uploadFailed("The file processing timeout is too large for the system clock.")
        }
        return max(0, timeout)
    }

    private static var processingTimeout: GeminiBatchError {
        .uploadFailed("The uploaded recording was still processing when the time limit was reached.")
    }

    // One loop owns the positive cadence and checks the same deadline around I/O.
    // swiftlint:disable:next function_parameter_count
    private func pollUntilActive(
        at url: URL, apiKey: String, uri: String, interval: TimeInterval,
        deadline: ContinuousClock.Instant, clock: ContinuousClock
    ) async throws -> String {
        while true {
            try Task.checkCancellation()
            let nextPoll = clock.now.advanced(by: .seconds(interval))
            guard nextPoll < deadline else {
                try await clock.sleep(until: deadline)
                throw Self.processingTimeout
            }
            try await clock.sleep(until: nextPoll)
            guard clock.now < deadline else { throw Self.processingTimeout }
            // A definitive answer that lands as the deadline passes is still an
            // answer; only an inconclusive one is subject to the budget.
            switch try await self.fileState(at: url, apiKey: apiKey)?.uppercased() {
            case "ACTIVE": return uri
            case "FAILED":
                throw GeminiBatchError.uploadFailed("Google could not process the uploaded recording.")
            default: continue
            }
        }
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
}
