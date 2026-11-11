import SpeakCore
import AppKit
import SwiftUI

/// Everything one API-key card shows and the actions its buttons run.
struct APIKeyCardConfiguration {
  let title: String
  let systemImage: String
  let tint: Color
  let statusIcon: String
  let statusTint: Color
  let isStored: Bool
  let descriptionText: String
  let keyFieldLabel: String
  let keyBinding: Binding<String>
  let onSave: () -> Void
  let onValidate: (() -> Void)?
  let onRemove: (() -> Void)?
  let isSaveDisabled: Bool
  let isValidateDisabled: Bool
  let isRemoveDisabled: Bool
  let validationState: APIKeyValidationViewState
  /// Keychain identifier of the credential this card manages, used to look up
  /// the account's balance.
  let credentialIdentifier: String
  /// Whether this is the card that shows the account's balance.
  ///
  /// Two cards can manage the same Keychain item — Deepgram has a
  /// transcription card and a voice-output card, both on `deepgram.apiKey` —
  /// and the identifier cannot tell them apart, so the one that does not own
  /// the account sets this to `false` and the figure appears exactly once.
  var presentsAccountBalance = true
  let tooltip: String
  let saveButtonTitle: String
  let saveTooltip: String
  let validateButtonTitle: String
  let validateTooltip: String
  let removeButtonTitle: String
  let removeTooltip: String
  let link: URL?
  let linkLabel: String?
  var statusLabel = "Status"
  /// The uses this card covers, for its least-privilege key guide.
  let guideUses: APIKeyUses
}

/// A settings card that stores, checks and removes one provider credential.
struct APIKeyCard: View {
  @EnvironmentObject var settings: AppSettings
  let configuration: APIKeyCardConfiguration
  @ObservedObject var balances: ProviderBalanceStore

  var body: some View {
    SettingsCard(title: configuration.title, systemImage: configuration.systemImage, tint: configuration.tint) {
      if settings.visualDensity.isCompact {
        compactAPIKeyCardBody(configuration)
      } else {
        regularAPIKeyCardBody(configuration)
      }
    }
    .speakTooltip(configuration.tooltip)
  }
}

private extension APIKeyCard {
  private func compactAPIKeyCardBody(_ configuration: APIKeyCardConfiguration) -> some View {
    VStack(alignment: .leading, spacing: settings.visualDensity.cardContentSpacing) {
      compactAPIKeyStatus(configuration)

      HStack(spacing: settings.visualDensity.inlineSpacing) {
        SecureField(configuration.keyFieldLabel, text: configuration.keyBinding)
          .textContentType(.password)
          .privacySensitive()
          .textFieldStyle(.roundedBorder)
          .speakTooltip("Paste the key exactly as issued; Speak stores it securely in your Keychain.")

        compactAPIKeySaveButton(configuration)
        compactAPIKeyValidateButton(configuration)
        compactAPIKeyRemoveButton(configuration)
      }

      Text(configuration.descriptionText)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .speakTooltip(configuration.descriptionText)

      APIKeyGuideDisclosure(identifier: configuration.credentialIdentifier, uses: configuration.guideUses)

      providerBalanceView(configuration)

      validationStatusView(for: configuration.validationState)
      validationDebugDetails(for: configuration.validationState)
    }
  }

  /// The account balance beside the key. It never gates the card: a billing
  /// endpoint that fails renders a reason and leaves everything else working.
  @ViewBuilder
  private func providerBalanceView(_ configuration: APIKeyCardConfiguration) -> some View {
    ProviderBalanceView(
      credentialIdentifier: configuration.credentialIdentifier,
      isKeyStored: configuration.isStored,
      presentsAccountBalance: configuration.presentsAccountBalance,
      store: balances
    )
  }

  private func compactAPIKeyStatus(_ configuration: APIKeyCardConfiguration) -> some View {
    HStack(spacing: settings.visualDensity.inlineSpacing) {
      Label(
        configuration.isStored ? "Saved" : "Not set",
        systemImage: configuration.statusIcon
      )
      .font(.caption.weight(.semibold))
      .foregroundStyle(
        configuration.isStored ? configuration.statusTint : Color.secondary
      )

      if let link = configuration.link, let linkLabel = configuration.linkLabel {
        Link(destination: link) {
          Label(linkLabel, systemImage: "arrow.up.forward.square")
            .labelStyle(.iconOnly)
        }
        .speakTooltip("Open \(configuration.title)'s site to manage your API key.")
        .accessibilityLabel(linkLabel)
      }

      Spacer(minLength: 0)
    }
  }

  private func compactAPIKeySaveButton(_ configuration: APIKeyCardConfiguration) -> some View {
    Button(action: configuration.onSave) {
      if configuration.validationState.isInFlight {
        ProgressView()
          .controlSize(.small)
      } else {
        Label(configuration.saveButtonTitle, systemImage: "arrow.down.circle")
          .labelStyle(.iconOnly)
      }
    }
    .disabled(configuration.isSaveDisabled)
    .buttonStyle(.borderedProminent)
    .tint(configuration.tint)
    .speakTooltip(configuration.saveTooltip)
    .accessibilityLabel(configuration.saveButtonTitle)
  }

  @ViewBuilder
  private func compactAPIKeyValidateButton(_ configuration: APIKeyCardConfiguration) -> some View {
    if let onValidate = configuration.onValidate, configuration.isStored {
      Button(action: onValidate) {
        if configuration.validationState.isInFlight {
          ProgressView()
            .controlSize(.small)
        } else {
          Label(configuration.validateButtonTitle, systemImage: "checkmark.shield")
            .labelStyle(.iconOnly)
        }
      }
      .disabled(configuration.isValidateDisabled)
      .buttonStyle(.bordered)
      .speakTooltip(configuration.validateTooltip)
      .accessibilityLabel(configuration.validateButtonTitle)
    }
  }

  @ViewBuilder
  private func compactAPIKeyRemoveButton(_ configuration: APIKeyCardConfiguration) -> some View {
    if let onRemove = configuration.onRemove, configuration.isStored {
      DestructiveConfirmButton(
        dialogTitle: removeKeyDialogTitle(configuration),
        message: removeKeyDialogMessage,
        confirmTitle: configuration.removeButtonTitle,
        triggerRole: .destructive,
        action: onRemove
      ) {
        Label(configuration.removeButtonTitle, systemImage: "trash")
          .labelStyle(.iconOnly)
      }
      .disabled(configuration.isRemoveDisabled)
      .buttonStyle(.bordered)
      .speakTooltip(configuration.removeTooltip)
      .accessibilityLabel(configuration.removeButtonTitle)
    }
  }

  private func regularAPIKeyCardBody(_ configuration: APIKeyCardConfiguration) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 12) {
        Label(configuration.statusLabel, systemImage: configuration.statusIcon)
          .foregroundStyle(
            configuration.isStored ? configuration.statusTint : Color.secondary
          )
          .labelStyle(.titleAndIcon)
        statusBadge(isStored: configuration.isStored, color: configuration.statusTint)
      }

      if let link = configuration.link, let linkLabel = configuration.linkLabel {
        Link(destination: link) {
          Label(linkLabel, systemImage: "arrow.up.forward.square")
            .font(.caption)
        }
        .speakTooltip("Open \(configuration.title)'s site to create or manage your API key.")
      }

      SecureField(configuration.keyFieldLabel, text: configuration.keyBinding)
        .textContentType(.password)
        .privacySensitive()
        .textFieldStyle(.roundedBorder)
        .speakTooltip("Paste the key exactly as issued; Speak stores it securely in your Keychain.")

      Text(configuration.descriptionText)
        .font(.caption)
        .foregroundStyle(.secondary)

      APIKeyGuideDisclosure(identifier: configuration.credentialIdentifier, uses: configuration.guideUses)

      HStack(spacing: 12) {
        regularAPIKeySaveButton(configuration)
        regularAPIKeyValidateButton(configuration)
        regularAPIKeyRemoveButton(configuration)
      }

      providerBalanceView(configuration)

      validationStatusView(for: configuration.validationState)
      validationDebugDetails(for: configuration.validationState)
    }
  }

  private func regularAPIKeySaveButton(_ configuration: APIKeyCardConfiguration) -> some View {
    Button(action: configuration.onSave) {
      if configuration.validationState.isInFlight {
        ProgressView()
          .controlSize(.small)
      } else {
        Label(configuration.saveButtonTitle, systemImage: "arrow.down.circle")
      }
    }
    .disabled(configuration.isSaveDisabled)
    .buttonStyle(.borderedProminent)
    .tint(configuration.tint)
    .speakTooltip(configuration.saveTooltip)
  }

  @ViewBuilder
  private func regularAPIKeyValidateButton(_ configuration: APIKeyCardConfiguration) -> some View {
    if let onValidate = configuration.onValidate, configuration.isStored {
      Button(action: onValidate) {
        if configuration.validationState.isInFlight {
          ProgressView()
            .controlSize(.small)
        } else {
          Label(configuration.validateButtonTitle, systemImage: "checkmark.shield")
        }
      }
      .disabled(configuration.isValidateDisabled)
      .buttonStyle(.bordered)
      .speakTooltip(configuration.validateTooltip)
    }
  }

  @ViewBuilder
  private func regularAPIKeyRemoveButton(_ configuration: APIKeyCardConfiguration) -> some View {
    if let onRemove = configuration.onRemove, configuration.isStored {
      DestructiveConfirmButton(
        configuration.removeButtonTitle,
        dialogTitle: removeKeyDialogTitle(configuration),
        message: removeKeyDialogMessage,
        confirmTitle: configuration.removeButtonTitle,
        triggerRole: .destructive,
        action: onRemove
      )
      .disabled(configuration.isRemoveDisabled)
      .speakTooltip(configuration.removeTooltip)
    }
  }

  private func removeKeyDialogTitle(_ configuration: APIKeyCardConfiguration) -> String {
    "Remove the \(configuration.title) key?"
  }

  private var removeKeyDialogMessage: String {
    "Speak forgets this key and deletes it from your Keychain. "
      + "Features that need it stop working until you paste it again."
  }

  private func statusBadge(isStored: Bool, color: Color) -> some View {
    let text = isStored ? "Saved" : "Not Set"
    let displayColor = isStored ? color : Color.secondary
    return Text(text.uppercased())
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        Capsule()
          .fill(displayColor.opacity(0.15))
      )
      .foregroundStyle(displayColor)
  }

  @ViewBuilder
  private func validationStatusView(
    for state: APIKeyValidationViewState,
    successFallback: String = "Key saved and validated"
  ) -> some View {
    switch state {
    case .idle:
      EmptyView()
    case .validating:
      Text("Validating key…")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .finished(let result):
      switch result.outcome {
      case .success(let message):
        Label(message.isEmpty ? successFallback : message, systemImage: "checkmark.seal")
          .font(.caption)
          .foregroundStyle(.green)
      case .failure(let message):
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private func validationDebugDetails(for state: APIKeyValidationViewState) -> some View {
    if case .finished(let result) = state, let debug = result.debug {
      Divider()
        .padding(.vertical, 4)
      APIKeyValidationDebugDetailsView(debug: debug)
    }
  }
}
