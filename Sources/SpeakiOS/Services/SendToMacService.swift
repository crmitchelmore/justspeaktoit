#if os(iOS)
import SpeakCore

/// The app-wide Send to Mac sender. Its pairing lives in its own Keychain item.
@MainActor
public enum SendToMacService {
    public static let shared = SendToMacSender(store: KeychainSendToMacPairingStore())
}
#endif
