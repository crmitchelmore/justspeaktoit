import Foundation

/// Streams bounded chunks to an owned file, with a wall-clock deadline in addition to the request timeout.
enum OpenRouterAudioDownload {
    static func perform(
        request: URLRequest,
        session: URLSession,
        destination: URL,
        limit: Int,
        speech: Bool
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await stream(request, session: session, destination: destination, limit: limit, speech: speech)
                return destination
            }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                throw OpenRouterAudioError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw OpenRouterAudioError.invalidResponse }
            return result
        }
    }

    private static func stream(
        _ request: URLRequest,
        session: URLSession,
        destination: URL,
        limit: Int,
        speech: Bool
    ) async throws {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request, delegate: OpenRouterAudioRedirectPolicy())
        let task = bytes.task
        defer { task.cancel() }
        try validate(response, limit: limit, speech: speech)
        guard FileManager.default.createFile(
            atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw OpenRouterAudioError.transportFailure }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try await withTaskCancellationHandler {
            var buffer = Data()
            var count = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                guard count < limit else { throw OpenRouterAudioError.responseTooLarge }
                buffer.append(byte)
                count += 1
                if buffer.count == 32 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            guard count > 0 else { throw OpenRouterAudioError.invalidResponse }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        } onCancel: {
            task.cancel()
        }
    }

    private static func validate(_ response: URLResponse, limit: Int, speech: Bool) throws {
        guard let response = response as? HTTPURLResponse else { throw OpenRouterAudioError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            // Never retain or surface provider bodies: they can contain request text or credentials.
            throw OpenRouterAudioError.httpStatus(response.statusCode)
        }
        guard response.expectedContentLength <= Int64(limit) else { throw OpenRouterAudioError.responseTooLarge }
        let contentType = response.mimeType?.lowercased() ?? ""
        // OpenRouter documents audio/mpeg for the explicitly requested MP3 format.
        let expected = speech ? "audio/mpeg" : "application/json"
        guard contentType == expected else { throw OpenRouterAudioError.invalidResponse }
    }
}

/// Audio payloads and bearer keys must not be forwarded through redirects.
final class OpenRouterAudioRedirectPolicy: NSObject, URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }
}
