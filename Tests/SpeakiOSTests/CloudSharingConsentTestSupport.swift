#if os(iOS)
import SpeakCore

/// iOS asks before the first upload to each cloud provider (#1805), and
/// refuses until the user allows it. Tests that drive upload paths grant every
/// catalogued provider first, as a user who allowed them would, and withdraw
/// afterwards so the shared store is left as they found it.
enum CloudSharingConsentTestSupport {
    static func grantAll(store: CloudSharingConsentStore = .shared) {
        store.grant(CloudSharingProviderCatalogue.all.map {
            CloudSharingRequest(provider: $0, kinds: CloudSharedDataKind.allCases)
        })
    }

    static func withdrawAll(store: CloudSharingConsentStore = .shared) {
        store.withdrawAll()
    }
}
#endif
