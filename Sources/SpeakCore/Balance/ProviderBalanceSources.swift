import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The balance transports every platform shares.
///
/// Only providers with a documented balance contract get a transport;
/// everything else is a billing link, decided by `ProviderBalanceDirectory`.
/// macOS and iOS read this through `ProviderBalanceStore.defaultSources`, and
/// Windows and Linux through the desktop host, so a new transport appears on
/// every Swift platform at once.
public enum ProviderBalanceSources {
    public static func defaults(session: URLSession = .shared) -> [any ProviderBalanceSource] {
        [
            DeepgramBalanceClient(session: session),
            RevAIBalanceClient(session: session),
            ElevenLabsBalanceClient(session: session),
            OpenRouterBalanceClient(session: session)
        ]
    }

    /// Account identifiers that have a transport, in display order.
    public static var accountIDs: [String] {
        defaults().map(\.accountID)
    }
}
