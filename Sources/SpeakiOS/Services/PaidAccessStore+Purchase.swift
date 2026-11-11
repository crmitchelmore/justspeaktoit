#if os(iOS)
import Foundation
import SpeakCore
import StoreKit
import UIKit

/// The iOS purchase surface of ``PaidAccessStore``: the feature gate and
/// Apple's subscription management. The StoreKit flow itself is SpeakCore's
/// `PaidAccessFlow`, shared with macOS.
extension PaidAccessStore {

    public func loadProducts() async {
        await self.flow.loadProducts()
    }

    /// The loaded StoreKit product for a term, if the App Store returned it.
    public func product(for term: PaidSubscriptionTerm) -> Product? {
        self.flow.product(for: term)
    }

    /// Buys the named term.
    ///
    /// - Parameter term: Which subscription to buy. Defaults to the user's
    ///   current choice rather than to whichever product loaded first.
    public func purchase(term: PaidSubscriptionTerm? = nil) async {
        // Refuses while iOS paid routing is unwired: see `PaidAccessFeature`.
        // The UI hides the purchase controls too; this is the backstop that
        // makes the guarantee independent of any view.
        guard PaidAccessFeature.isAvailableOnIOS else {
            self.flow.report("Subscriptions are not available in the iOS app yet.")
            return
        }
        let term = term ?? self.selectedTerm
        await self.flow.withSignedInOperation(clearingError: true) { session, generation in
            await self.flow.purchaseThroughStoreKit(term: term, session: session, generation: generation)
        }
    }

    public func restorePurchases() async {
        await self.flow.withSignedInOperation(clearingError: false) { session, generation in
            await self.flow.restoreStoreKitPurchases(session: session, generation: generation)
        }
    }

    /// Opens Apple's subscription management. App Store builds must never send
    /// the user to an external payment page.
    public func manageSubscription() {
        guard self.entitlement.provider == .storeKit else {
            self.flow.report(
                self.entitlement.provider == .stripe
                    ? "This subscription was purchased on the website. Manage it in your Just Speak to It web account."
                    : "This access was granted manually and has no subscription to manage."
            )
            return
        }
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }
}
#endif
