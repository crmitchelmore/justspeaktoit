import Foundation
import SpeakCore

/// A desktop computer's `CloudSharingConsent`, kept in its own file beside the
/// settings so a settings export, migration archive, iCloud sync or
/// configuration import never carries one person's consent to another
/// computer. The JSON is the one macOS, iOS and Android store, so the
/// persistence format has a single definition in `CloudSharingConsent`.
///
/// A missing or unreadable file means nothing was allowed: consent fails closed.
public final class DesktopCloudSharingConsentStore: @unchecked Sendable {
    public static let fileName = "cloud-sharing-consent.json"

    /// Replaces the file atomically; hosts pass their settings writer.
    public typealias Writer = @Sendable (_ data: Data, _ url: URL) throws -> Void

    private let url: URL
    private let write: Writer
    private let lock = NSLock()
    private var loaded: CloudSharingConsent?

    public init(directory: URL, write: @escaping Writer) {
        url = directory.appendingPathComponent(Self.fileName)
        self.write = write
    }

    public var consent: CloudSharingConsent {
        lock.lock()
        defer { lock.unlock() }
        return current()
    }

    public func missing(_ requests: [CloudSharingRequest]) -> [CloudSharingRequest] {
        consent.missing(requests)
    }

    /// Persists the grant before returning, so a send never relies on consent
    /// that was not saved.
    public func grant(_ requests: [CloudSharingRequest]) throws {
        try update { $0.grant(requests) }
    }

    public func withdraw(providerID: String) throws {
        try update { $0.withdraw(providerID: providerID) }
    }

    public func withdrawAll() throws {
        try update { $0.withdrawAll() }
    }

    private func update(_ change: (inout CloudSharingConsent) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var value = current()
        change(&value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(value), url)
        loaded = value
    }

    private func current() -> CloudSharingConsent {
        if let loaded { return loaded }
        let value = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(CloudSharingConsent.self, from: $0) } ?? CloudSharingConsent()
        loaded = value
        return value
    }
}
