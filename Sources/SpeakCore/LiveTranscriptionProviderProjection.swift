import Foundation

public extension LiveTranscriptionRouting {
    /// Providers the iOS app can currently use, in their first catalogue order.
    /// Privacy and settings surfaces consume this projection so adding an iOS
    /// model cannot leave its cloud processor undisclosed.
    static var iOSSupportedProviders: [LiveTranscriptionProviderID] {
        var seen: Set<LiveTranscriptionProviderID> = []
        return allRoutes.compactMap { route in
            guard route.isSupportedOnIOS, seen.insert(route.provider).inserted else { return nil }
            return route.provider
        }
    }
}
