import AppKit
import SpeakCore
import SwiftUI

extension SettingsView {

  /// Paid Access card, shown at the top of the API Keys screen.
  ///
  /// Placement is deliberate: this is exactly where someone lands when they are
  /// tired of managing keys, which is the problem the subscription solves. The
  /// copy leads with the fact that on-device models and personal API keys stay
  /// available and are often free or cheaper — the subscription buys
  /// convenience, not results you cannot otherwise get.
  @ViewBuilder
  var paidAccessCard: some View {
    SettingsCard(
      title: "Subscription",
      systemImage: "creditcard",
      tint: Color.brandAccentDeep
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "Prefer not to manage API keys? A subscription runs transcription and "
            + "cleanup through our account and picks the best model for each task."
        )
        .font(.callout)

        Text(
          "You never have to. On-device models run free with no account at all, "
            + "and your own API keys keep working exactly as they do now — often "
            + "for less than a subscription costs. This is a convenience, not an upgrade."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Divider()

        if paidAccess.isSignedIn {
          paidAccessAccountSection
        } else {
          paidAccessSignedOutSection
        }

        if let message = paidAccess.lastError {
          Text(message)
            .font(.caption)
            .foregroundStyle(Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .speakTooltip("Subscribe to skip API key setup, or keep using your own keys and local models for free.")
    .task {
      await paidAccess.loadProducts()
      await paidAccess.refreshEntitlement()
    }
  }

  // MARK: - Signed out

  @ViewBuilder
  private var paidAccessSignedOutSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Sign in with Apple to start or restore a subscription. The same Apple account works on your Mac and iPhone.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Button {
        Task { await paidAccess.signIn() }
      } label: {
        Label("Sign in with Apple", systemImage: "apple.logo")
      }
      .buttonStyle(.borderedProminent)
      .disabled(paidAccess.isBusy)
    }
  }

  // MARK: - Signed in

  @ViewBuilder
  private var paidAccessAccountSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Status")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text(paidAccess.entitlement.status.displayName)
          .font(.callout.weight(.medium))
      }

      if let renewal = paidAccess.entitlement.currentPeriodEnd {
        HStack {
          Text(paidAccess.entitlement.cancelAtPeriodEnd ? "Access ends" : "Renews")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer()
          Text(renewal.formatted(date: .abbreviated, time: .omitted))
            .font(.callout)
        }
      }

      if let usage = paidAccess.entitlement.usage, usage.audioSecondsLimit > 0 {
        VStack(alignment: .leading, spacing: 4) {
          Text("Included dictation used this month")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ProgressView(value: usage.audioFractionUsed)
          Text(Self.usageSummary(for: usage))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      paidAccessRoutingControls
      paidAccessActionButtons
    }
  }

  @ViewBuilder
  private var paidAccessRoutingControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: settingsBinding(\AppSettings.paidAccessRoutingEnabled)) {
        Text("Use my subscription for transcription and cleanup")
      }
      .toggleStyle(.switch)
      .disabled(!paidAccess.entitlement.isActive())

      Toggle(isOn: settingsBinding(\AppSettings.simpleModelChoices)) {
        Text("Simple model choices")
      }
      .toggleStyle(.switch)

      Text(paidAccess.simpleModelChoicesPolicy.explanation)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if paidAccess.isPaidRoutingActive, !paidAccess.policy.routes.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Models in use")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(paidAccess.policy.routes, id: \.model) { route in
            HStack {
              Text(route.operation.displayName)
                .font(.caption)
              Spacer()
              Text(route.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var paidAccessActionButtons: some View {
    HStack(spacing: 10) {
      if paidAccess.entitlement.isActive() {
        Button(paidAccess.billingChannel.manageActionTitle) {
          Task { await paidAccess.manageSubscription() }
        }
        .disabled(paidAccess.isBusy)
      } else {
        Button(paidAccess.billingChannel.purchaseActionTitle) {
          Task { await paidAccess.purchase() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(paidAccess.isBusy)
      }

      if paidAccess.billingChannel == .storeKit {
        Button("Restore purchases") {
          Task { await paidAccess.restorePurchases() }
        }
        .disabled(paidAccess.isBusy)
      }

      Spacer()

      Button("Sign out") {
        Task { await paidAccess.signOut() }
      }
      .disabled(paidAccess.isBusy)
    }
  }

  private static func usageSummary(for usage: PaidUsageSnapshot) -> String {
    let used = Int(usage.audioSecondsUsed / 60)
    let limit = Int(usage.audioSecondsLimit / 60)
    return "\(used) of \(limit) minutes"
  }

  // MARK: - Model-picker visibility

  /// Whether model pickers should be hidden because the user asked for simple
  /// model choices and paid routing is actually available.
  var hidesModelSelection: Bool {
    paidAccess.simpleModelChoicesPolicy.hidesModelSelection
  }

  /// Shown in place of the hidden pickers so the screen never looks broken and
  /// the way back to manual control stays obvious.
  @ViewBuilder
  var simpleModelChoicesNotice: some View {
    SettingsCard(
      title: "Models chosen for you",
      systemImage: "sparkles",
      tint: Color.brandAccentDeep
    ) {
      VStack(alignment: .leading, spacing: 8) {
        Text(paidAccess.simpleModelChoicesPolicy.explanation)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)

        ForEach(paidAccess.policy.routes, id: \.model) { route in
          HStack {
            Text(route.operation.displayName)
              .font(.caption)
            Spacer()
            Text(route.displayName)
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
          }
        }

        Toggle(isOn: settingsBinding(\AppSettings.simpleModelChoices)) {
          Text("Simple model choices")
        }
        .toggleStyle(.switch)
      }
    }
  }
}
