import Foundation

enum OpenRouterAudioCatalogError: Error, LocalizedError {
    case invalidResponse
    case payloadTooLarge
    case timedOut
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenRouter returned an unreadable audio model catalogue."
        case .payloadTooLarge: "OpenRouter's audio model catalogue exceeded the download limit."
        case .timedOut: "OpenRouter audio model discovery timed out. Try again."
        case let .httpStatus(status): "OpenRouter could not load audio models (HTTP \(status))."
        }
    }
}

/// Only explicitly decoded model metadata is persisted, never requests, headers, keys, or error bodies.
struct OpenRouterAudioCatalogSnapshot: Codable {
    let version: Int
    let updatedAt: Date
    let models: [OpenRouterAudioModel]

    static let maximumBytes = 4 * 1_024 * 1_024

    static func read(from url: URL?, now: Date) -> Self? {
        guard let url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= maximumBytes,
              let data = try? Data(contentsOf: url), data.count <= maximumBytes,
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.version == 1,
              snapshot.updatedAt <= now,
              snapshot.models.allSatisfy({ $0.capability != nil }) else { return nil }
        return snapshot
    }

    func write(to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self), data.count <= Self.maximumBytes else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // The successfully fetched catalogue remains usable if disk persistence is unavailable.
        }
    }
}
