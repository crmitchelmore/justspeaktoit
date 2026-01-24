import StoreKit

/// Manages in-app purchase tip products using StoreKit 2.
@MainActor
public final class TipStore: ObservableObject {

    public static let shared = TipStore()

    @Published public private(set) var products: [Product] = []
    @Published public private(set) var purchaseState: PurchaseState = .ready

    public enum PurchaseState: Equatable {
        case ready
        case purchasing
        case purchased
        case failed(String)

        public static func == (lhs: PurchaseState, rhs: PurchaseState) -> Bool {
            switch (lhs, rhs) {
            case (.ready, .ready), (.purchasing, .purchasing), (.purchased, .purchased):
                return true
            case let (.failed(l), .failed(r)):
                return l == r
            default:
                return false
            }
        }
    }

    private let productIDs = [
        "com.justspeaktoit.tip.small",
        "com.justspeaktoit.tip.medium",
        "com.justspeaktoit.tip.large"
    ]

    private init() {}

    /// Loads available tip products from the App Store.
    public func loadProducts() async {
        do {
            products = try await Product.products(for: productIDs)
                .sorted { $0.price < $1.price }
        } catch {
            print("Failed to load tip products: \(error)")
        }
    }

    /// Initiates a purchase for the given product.
    public func purchase(_ product: Product) async {
        purchaseState = .purchasing

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    purchaseState = .purchased
                case .unverified:
                    purchaseState = .failed("Transaction could not be verified")
                }
            case .userCancelled:
                purchaseState = .ready
            case .pending:
                purchaseState = .ready
            @unknown default:
                purchaseState = .ready
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    /// Resets the purchase state back to ready.
    public func resetState() {
        purchaseState = .ready
    }
}
