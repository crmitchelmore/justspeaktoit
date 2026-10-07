import Foundation

/// Plain-language copy for where API keys and History go once they leave the
/// recording workflow, shared by the iOS Privacy screen.
///
/// Each sentence describes one mechanism the code actually uses, so a reader
/// can tell them apart:
/// - provider requests carry the configured key to authenticate;
/// - Encrypted API-Key Sync (`CloudKitKeySync`) is opt-in and writes only
///   passphrase-encrypted ciphertext to the private CloudKit database;
/// - History (`HistorySyncEngine`) syncs raw and cleaned-up transcript text to
///   the private CloudKit database while the per-device iCloud History Sync
///   switch is on (the default) and the iCloud account is available. Off stops
///   every upload, download and delete.
///
/// The base Keychain item is deliberately not iCloud Keychain synchronizable, so
/// none of this copy may describe keys as syncing through iCloud Keychain.
public enum PrivacyStorageDisclosure {
    /// Where keys live and why they are sent to a provider.
    public static let apiKeyStorage =
        "API keys are stored in this device's Keychain. When you use a cloud provider, "
        + "its key is sent to that provider with each request to authenticate it."

    /// The opt-in, passphrase-encrypted key sync. Only the identifiers in
    /// `CloudKitKeySync.syncableIdentifiers` sync, hence "supported keys".
    public static let apiKeySync =
        "If you turn on Encrypted API-Key Sync, supported keys are encrypted on this device with your "
        + "sync passphrase before they are saved to your private CloudKit database. They cannot be read "
        + "without that passphrase, which is never uploaded."

    /// History sync, including transcript text, and the switch that stops it.
    public static let historySync =
        "History, including transcript text, syncs automatically to your private CloudKit database while "
        + "iCloud History Sync is on and this device is signed in to iCloud. It is on by default; turn it "
        + "off in Settings › Sync to keep History on this device."

    /// Shown in place of sync status while iCloud History Sync is off.
    public static let historySyncOff =
        "History stays on this device. Anything already in iCloud stays there, and deleting History here "
        + "does not remove it from iCloud. Turning sync back on uploads History saved while it was off."

    /// Short right-hand value for the History row of a network-activity list.
    public static let historySyncCondition = "When signed in to iCloud"

    /// Short right-hand value for the API-key sync row of a network-activity list.
    public static let apiKeySyncCondition = "Only if turned on"
}
