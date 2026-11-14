import Foundation

// MARK: - Device Identity

/// Provides consistent device identification.
public struct DeviceIdentity {
    static let deviceIdDefaultsKey = "speakDeviceId"

    public static var deviceId: String {
        #if os(iOS)
        return mobileDeviceId(
            store: KeychainDeviceIdentityStore(),
            defaults: .standard,
            // Prefer identifierForVendor: stable while any app from the same
            // vendor remains installed, unlike a random UUID. Either way the
            // value is captured once and then served from the Keychain.
            makeDeviceId: {
                ReleaseTrain.current.namespace(UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)
            }
        )
        #else
        // On macOS, use hardware UUID
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let serialNumber = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            return ReleaseTrain.current.namespace(serialNumber)
        }
        return UUID().uuidString
        #endif
    }

    /// Resolves the mobile device ID, most durable source first:
    ///
    /// 1. Keychain — survives app deletion/reinstall.
    /// 2. UserDefaults — the pre-Keychain location; migrated into the Keychain
    ///    on first read so existing pairings keep their identity.
    /// 3. Freshly generated — persisted to the Keychain and mirrored to
    ///    UserDefaults (rollback to older builds keeps the same ID, and the
    ///    mirror is the fallback if the Keychain write failed).
    ///
    /// Platform-neutral (the iOS-only part is generating the default ID above)
    /// so tests can inject every collaborator.
    static func mobileDeviceId(
        store: any DeviceIdentityStoring,
        defaults: UserDefaults,
        makeDeviceId: () -> String
    ) -> String {
        if let id = store.loadDeviceId() {
            return id
        }
        if let legacy = defaults.string(forKey: deviceIdDefaultsKey) {
            store.storeDeviceId(legacy)
            return legacy
        }
        let id = makeDeviceId()
        store.storeDeviceId(id)
        defaults.set(id, forKey: deviceIdDefaultsKey)
        return id
    }

    public static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}

#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif
