import StoreKit

/// Shared transaction filtering and server verification for both Apple apps.
public enum PaidStoreKitSync {
    public static func entitlement(
        for result: VerificationResult<Transaction>,
        session: PaidAccessSession,
        client: any PaidAccessClienting
    ) async throws -> PaidEntitlement? {
        guard case .verified(let transaction) = result,
              PaidSubscriptionTerm.productIDs.contains(transaction.productID) else { return nil }
        return try await client.syncStoreKitTransaction(
            session: session, signedTransaction: result.jwsRepresentation, signedRenewalInfo: nil
        )
    }
}
