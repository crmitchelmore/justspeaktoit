import Foundation

/// Device-local store for `CloudSharingConsent`.
///
/// The JSON lives under `CloudSharingConsent.storageKey` and is not an app
/// setting, a sync key or a configuration field, so export, import and
/// automation cannot grant or copy it.
public final class CloudSharingConsentStore: @unchecked Sendable {
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
        let raw = defaults.string(forKey: CloudSharingConsent.storageKey)
        lock.unlock()
        guard let raw else { return CloudSharingConsent() }
        return CloudSharingConsent(jsonString: raw)
    }

    public func replace(_ consent: CloudSharingConsent) {
        lock.lock()
        defaults.set(consent.encodedJSONString(), forKey: CloudSharingConsent.storageKey)
        lock.unlock()
        notificationCenter.post(name: CloudSharingConsent.didChangeNotification, object: self)
    }

    public func grant(_ request: CloudSharingRequest) {
        replace(consent.granting(request))
    }

    public func withdraw(providerID: String) {
        replace(consent.withdrawing(providerID: providerID))
    }

    public func allows(_ request: CloudSharingRequest) -> Bool {
        consent.allows(request)
    }
}
