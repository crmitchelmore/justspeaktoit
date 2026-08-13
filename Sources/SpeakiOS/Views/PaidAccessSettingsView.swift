#if os(iOS)
import SpeakCore
import StoreKit
import SwiftUI

/// Subscription screen for iOS.
///
/// The copy leads with the fact that on-device models and personal API keys
/// remain available, work without an account, and are often free or cheaper.
/// The subscription buys convenience — not results that are otherwise
/// unavailable — and the settings screen says so before it offers to charge.
public struct PaidAccessSettingsView: View {

    @ObservedObject private var store = PaidAccessStore.shared

    public init() {}

    public var body: some View {
        Form {
            Section {
                Text(
                    "A subscription runs transcription and cleanup through our account "
                        + "and picks the best model for each task, so there are no API keys to set up."
                )
                .font(.callout)

                Text(
                    "You never have to subscribe. On-device transcription is free and needs no "
                        + "account, and your own API keys keep working exactly as they do now — "
                        + "often for less than a subscription costs."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Paid access")
            }

            if !PaidAccessFeature.isAvailableOnIOS {
                self.unavailableSection
            }

            if self.store.isSignedIn {
                self.accountSection
                if PaidAccessFeature.isAvailableOnIOS {
                    self.routingSection
                }
            } else if PaidAccessFeature.isAvailableOnIOS {
                self.signedOutSection
            }

            if let message = self.store.lastError {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await self.store.loadProducts()
            await self.store.refreshEntitlement()
        }
    }

    // MARK: - Sections

    /// Shown instead of the purchase flow while iOS paid routing is unwired.
    /// The app must not take money for routing it does not perform.
    @ViewBuilder
    private var unavailableSection: some View {
        Section {
            Label(
                "Subscriptions are not available in the iOS app yet. "
                    + "Transcription and cleanup on iPhone use on-device models "
                    + "or your own API keys.",
                systemImage: "info.circle"
            )
            .font(.caption)
        }
    }

    private static func termLabel(_ term: PaidSubscriptionTerm, price: String?) -> String {
        guard let price else { return term.displayName }
        return "\(term.displayName) — \(price)"
    }

    @ViewBuilder
    private var signedOutSection: some View {
        Section {
            Button {
                Task { await self.store.signIn() }
            } label: {
                Label("Sign in with Apple", systemImage: "apple.logo")
            }
            .disabled(self.store.isBusy)
        } footer: {
            Text("The same Apple account works on your iPhone and your Mac.")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Status") {
            LabeledContent("Subscription", value: self.store.entitlement.status.displayName)

            if let renewal = self.store.entitlement.currentPeriodEnd {
                LabeledContent(
                    self.store.entitlement.cancelAtPeriodEnd ? "Access ends" : "Renews",
                    value: renewal.formatted(date: .abbreviated, time: .omitted)
                )
            }

            if let usage = self.store.entitlement.usage, usage.audioSecondsLimit > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: usage.audioFractionUsed)
                    Text(
                        "\(usage.audioSecondsUsed / 60) of \(usage.audioSecondsLimit / 60) "
                            + "included minutes used this month"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // Buying is switched off while iOS paid routing is unwired — see
            // `PaidAccessFeature`. Managing and restoring an existing
            // subscription stay available, because a subscriber who bought on a
            // Mac still needs a way to see and cancel it.
            if self.store.entitlement.isActive() {
                Button(self.store.billingChannel.manageActionTitle) {
                    self.store.manageSubscription()
                }
            } else if PaidAccessFeature.isAvailableOnIOS {
                Picker("Billing", selection: self.$store.selectedTerm) {
                    ForEach(PaidSubscriptionTerm.allCases) { term in
                        Text(Self.termLabel(term, price: self.store.product(for: term)?.displayPrice))
                            .tag(term)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("paidAccessTermPicker")

                Button(self.store.billingChannel.purchaseActionTitle) {
                    Task { await self.store.purchase() }
                }
                .disabled(self.store.isBusy)
            }

            Button("Restore purchases") {
                Task { await self.store.restorePurchases() }
            }
            .disabled(self.store.isBusy)

            Button("Sign out", role: .destructive) {
                Task { await self.store.signOut() }
            }
            .disabled(self.store.isBusy)
        }
    }

    @ViewBuilder
    private var routingSection: some View {
        Section {
            Toggle(isOn: self.$store.paidRoutingEnabled) {
                Text("Use my subscription")
            }
            .disabled(!self.store.entitlement.isActive())

            Toggle(isOn: self.$store.simpleModelChoices) {
                Text("Simple model choices")
            }

            if self.store.isPaidRoutingActive {
                // Live transcription is published by the server but not used by
                // any client, so it is never advertised here.
                ForEach(self.store.policy.clientSupportedRoutes, id: \.operation) { route in
                    LabeledContent(route.operation.displayName, value: route.displayName)
                        .font(.caption)
                }
            }
        } header: {
            Text("Routing")
        } footer: {
            Text(self.store.simpleModelChoicesPolicy.explanation)
        }
    }
}

#Preview {
    NavigationStack {
        PaidAccessSettingsView()
    }
}
#endif
