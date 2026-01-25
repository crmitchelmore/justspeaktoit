import StoreKit
import SwiftUI

/// A view presenting tip jar options for supporting development.
struct TipJarView: View {
    @ObservedObject private var store = TipStore.shared

    var body: some View {
        VStack(spacing: 20) {
            headerSection
            productsSection
            stateSection
            Spacer()
            footerSection
        }
        .padding()
        .frame(minWidth: 320, minHeight: 420)
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.fill")
                .font(.system(size: 50))
                .foregroundStyle(.pink)

            Text("Support Development")
                .font(.title2.bold())

            Text("Tips help fund continued development and new features. Thank you for your support!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
    }

    @ViewBuilder
    private var productsSection: some View {
        if store.products.isEmpty {
            ProgressView("Loading...")
                .task { await store.loadProducts() }
        } else {
            VStack(spacing: 12) {
                ForEach(store.products, id: \.id) { product in
                    TipButton(product: product, isPurchasing: store.purchaseState == .purchasing)
                }
            }
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        switch store.purchaseState {
        case .purchased:
            Label("Thank you!", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    store.resetState()
                }
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        default:
            EmptyView()
        }
    }

    private var footerSection: some View {
        Text("Tips are optional and don't unlock additional features.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

private struct TipButton: View {
    let product: Product
    let isPurchasing: Bool

    private var emoji: String {
        switch product.id {
        case "com.justspeaktoit.tip.small": return "☕"
        case "com.justspeaktoit.tip.medium": return "🍔"
        case "com.justspeaktoit.tip.large": return "💪"
        default: return "💝"
        }
    }

    var body: some View {
        Button {
            Task { @MainActor in
                await TipStore.shared.purchase(product)
            }
        } label: {
            HStack {
                Text(emoji)
                    .font(.title2)
                Text(product.displayName)
                Spacer()
                Text(product.displayPrice)
                    .fontWeight(.semibold)
            }
            .padding()
            .background(.fill.tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing)
    }
}

#Preview {
    TipJarView()
}
