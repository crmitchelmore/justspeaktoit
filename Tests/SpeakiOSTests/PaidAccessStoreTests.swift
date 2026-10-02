#if os(iOS)
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// iOS paid-access policy cover.
///
/// The important assertions are that iOS always transacts through StoreKit, and
/// that a device with no subscription keeps every model picker and every
/// bring-your-own-key path exactly as before.
@MainActor
final class PaidAccessStoreTests: XCTestCase {

    // MARK: - Billing channel

    func testIOSBuilds_alwaysUseStoreKit() {
        // iOS only ever ships through the App Store, so the Stripe path must be
        // unreachable here regardless of what the server would allow.
        XCTAssertEqual(DistributionChannel.current, .appStore)
        XCTAssertEqual(PaidAccessStore.shared.billingChannel, .storeKit)
        XCTAssertFalse(PaidAccessStore.shared.billingChannel.opensExternalBrowser)
    }

    func testStoreKitProductIdentifiers_matchTheSubscriptionGroup() {
        XCTAssertEqual(
            PaidAccessStore.subscriptionProductIDs,
            ["com.justspeaktoit.paid.monthly", "com.justspeaktoit.paid.yearly"]
        )
    }

    // MARK: - Defaults

    func testFreshInstall_isUnentitledAndRoutesLocally() {
        let store = PaidAccessStore.shared
        XCTAssertEqual(store.entitlement.status, .none)
        XCTAssertFalse(store.entitlement.allowsPaidRouting())
        XCTAssertFalse(store.isPaidRoutingActive)
    }

    func testUnentitledDevice_keepsItsModelPickers() {
        let store = PaidAccessStore.shared
        let previous = store.simpleModelChoices
        defer { store.simpleModelChoices = previous }

        store.simpleModelChoices = true
        XCTAssertFalse(
            store.simpleModelChoicesPolicy.hidesModelSelection,
            "Without paid routing the pickers must stay, or the user has no way to transcribe"
        )
    }

    func testUnentitledDevice_routerFallsBackToTheUsersOwnModel() throws {
        let router = PaidAccessRouter(
            entitlement: .unentitled,
            policy: .unknown,
            isPaidRoutingPreferred: true
        )
        let decision = try router.decide(
            for: .batchTranscription,
            configuredModel: "openai/whisper-1"
        )
        XCTAssertEqual(decision, .bringYourOwnKey(model: "openai/whisper-1"))
    }

    // MARK: - Nonce

    func testSignInNonce_isUniqueUrlSafeAndHashedForApple() {
        let first = PaidAccessStore.makeRawNonce()
        let second = PaidAccessStore.makeRawNonce()

        XCTAssertNotEqual(first, second)
        XCTAssertNil(first.range(of: "[^A-Za-z0-9_-]", options: .regularExpression))
        XCTAssertEqual(
            PaidAccessStore.sha256Hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
#endif
