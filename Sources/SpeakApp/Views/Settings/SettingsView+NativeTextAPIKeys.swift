import SpeakCore
import SwiftUI

extension SettingsView {
  /// The card for a native cleanup provider whose key no speech card already manages.
  func nativeTextAPIKeyCard(for provider: NativeTextProvider) -> some View {
    let stateID = APIKeyFormModel.nativeTextStateID(provider)
    let identifier = provider.credentialIdentifier
    let isStored = isAPIKeyStored(identifier)
    let validationState = apiKeyForm.providerStates[stateID] ?? .idle
    let inFlight = validationState.isInFlight
    return apiKeyCard(APIKeyCardConfiguration(
      title: "\(provider.displayName) (Post-processing)",
      systemImage: "text.badge.checkmark",
      tint: .orange,
      statusIcon: isStored ? "checkmark.seal.fill" : "key.fill",
      statusTint: .orange,
      isStored: isStored,
      descriptionText: "Stored securely in your macOS Keychain. "
        + "Used only for \(provider.displayName) transcript cleanup.",
      keyFieldLabel: "\(provider.displayName) API Key",
      keyBinding: apiKeyForm.providerDraft(for: stateID),
      onSave: { apiKeyForm.saveNativeTextKey(provider, in: environment) },
      onValidate: nil,
      onRemove: isStored ? { apiKeyForm.removeNativeTextKey(provider, in: environment) } : nil,
      isSaveDisabled: inFlight
        || (apiKeyForm.providerDrafts[stateID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      isValidateDisabled: true,
      isRemoveDisabled: inFlight,
      validationState: validationState,
      credentialIdentifier: identifier,
      tooltip: "Manage your \(provider.displayName) API key securely without leaving Speak.",
      saveButtonTitle: isStored ? "Replace Key" : "Save Key",
      saveTooltip: "Securely store your \(provider.displayName) key for native cleanup models.",
      validateButtonTitle: "Check Validity",
      validateTooltip: "The key is checked by the first cleanup request.",
      removeButtonTitle: "Remove Key",
      removeTooltip: "Forget this key from Speak and your Keychain when you no longer use it.",
      link: APIKeyCatalog.keyPageURL(for: identifier),
      linkLabel: "Get API Key",
      guideUses: .postProcessing
    ))
  }
}
