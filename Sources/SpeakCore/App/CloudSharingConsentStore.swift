import Foundation

/// The device's `CloudSharingConsent`, stored as JSON in user defaults under
/// `defaultsKey`. Android stores the same JSON under the same key (exported
/// through `cloud_catalog.json`).
public final class CloudSharingConsentStore: @unchecked Sendable {
    public static let defaultsKey = "cloudSharingConsent"
    /// Posted after every change; the object is the store.
    public static let didChangeNotification = Notification.Name("CloudSharingConsentDidChange")
    public static let shared = CloudSharingConsentStore()

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    public var consent: CloudSharingConsent {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    public func missing(_ requests: [CloudSharingRequest]) -> [CloudSharingRequest] {
        consent.missing(requests)
    }

    public func grant(_ requests: [CloudSharingRequest]) {
        update { $0.grant(requests) }
    }

    public func withdraw(providerID: String) {
        update { $0.withdraw(providerID: providerID) }
    }

    public func withdrawAll() {
        update { $0.withdrawAll() }
    }

    private func update(_ change: (inout CloudSharingConsent) -> Void) {
        lock.lock()
        var value = load()
        change(&value)
        if let data = try? JSONEncoder.sortedKeys.encode(value), let json = String(bytes: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.defaultsKey)
        }
        lock.unlock()
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }

    private func load() -> CloudSharingConsent {
        guard let json = defaults.string(forKey: Self.defaultsKey),
              let value = try? JSONDecoder().decode(CloudSharingConsent.self, from: Data(json.utf8))
        else { return CloudSharingConsent() }
        return value
    }
}

private extension JSONEncoder {
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

// MARK: - Error

/// Thrown, or reported, when a send needs consent the user has not given yet.
/// Nothing was uploaded and no recording was discarded.
public struct CloudSharingConsentRequiredError: LocalizedError, Equatable, Sendable {
    public let requests: [CloudSharingRequest]

    public init(requests: [CloudSharingRequest]) {
        self.requests = requests
    }

    public var errorDescription: String? { CloudSharingConsent.blockedMessage(for: requests) }
}
