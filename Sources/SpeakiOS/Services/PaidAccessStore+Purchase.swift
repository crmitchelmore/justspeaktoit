#if os(iOS)
import Foundation
import SpeakCore
import StoreKit
import UIKit

/// StoreKit purchase, restore and transaction sync for ``PaidAccessStore``.
///
/// Split from the main store file only for length; this is the same type. The
/// division is deliberate though: everything that talks to StoreKit lives here,
/// and everything that talks to our own server lives in `PaidAccessStore.swift`.
extension PaidAccessStore {

    public func loadProducts() async {
        let loaded = try? await Product.products(for: Self.subscriptionProductIDs)
        self.products = (loaded ?? []).sorted { $0.price < $1.price }
    }

    /// The loaded StoreKit product for a term, if the App Store returned it.
    public func product(for term: PaidSubscriptionTerm) -> Product? {
        self.products.first { $0.id == term.productID }
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
            self.lastError = "Subscriptions are not available in the iOS app yet."
            return
        }
        let term = term ?? self.selectedTerm
        self.isBusy = true
        self.lastError = nil
        defer { self.isBusy = false }

        guard let session = await self.currentSession() else {
            self.lastError = PaidAccessError.notSignedIn.errorDescription
            return
        }
        if self.products.isEmpty {
            await self.loadProducts()
        }
        // Matched by product id, never by position.
        guard let product = self.product(for: term) else {
            self.lastError = "The \(term.displayName.lowercased()) subscription is not available in this build yet."
            return
        }

        // Bind the purchase to this account before it happens. The server rejects
        // a signed transaction whose `appAccountToken` is not the caller's, so a
        // purchase made without one produces a receipt nobody can redeem.
        guard let accountToken = session.storeKitAccountToken else {
            self.lastError = """
                This account cannot be linked to an App Store purchase. \
                Sign out, sign back in and try again.
                """
            return
        }

        do {
            let result = try await product.purchase(options: [.appAccountToken(accountToken)])
            if case .success(let verification) = result {
                if await self.syncIfSubscription(verification, session: session),
                   case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        } catch {
            self.lastError = "The purchase could not be completed."
        }
    }

    public func restorePurchases() async {
        self.isBusy = true
        defer { self.isBusy = false }

        guard let session = await self.currentSession() else {
            self.lastError = PaidAccessError.notSignedIn.errorDescription
            return
        }
        for await result in Transaction.currentEntitlements {
            await self.syncIfSubscription(result, session: session)
        }
        await self.refreshEntitlement()
    }

    /// Opens Apple's subscription management. App Store builds must never send
    /// the user to an external payment page.
    public func manageSubscription() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let session = await self.currentSession() else { return }
        if await self.syncIfSubscription(result, session: session),
           case .verified(let transaction) = result {
            await transaction.finish()
        }
        await self.refreshEntitlement()
    }

    func syncIfSubscription(
        _ result: VerificationResult<Transaction>,
        session: PaidAccessSession
    ) async -> Bool {
        guard case .verified(let transaction) = result else { return false }
        guard Self.subscriptionProductIDs.contains(transaction.productID) else { return false }

        do {
            // The server verifies the signature again; the device's own
            // verification is never sufficient on its own.
            self.entitlement = try await self.client.syncStoreKitTransaction(
                session: session,
                signedTransaction: result.jwsRepresentation,
                signedRenewalInfo: nil
            )
            return true
        } catch {
            self.lastError = (error as? PaidAccessError)?.errorDescription
                ?? "Could not confirm the subscription."
            return false
        }
    }
}
#endif
