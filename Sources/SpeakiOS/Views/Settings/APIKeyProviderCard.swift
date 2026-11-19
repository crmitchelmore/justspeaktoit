#if os(iOS)
import SpeakCore
import SwiftUI

/// One provider's card on the API Keys screen: its key field, the clear
/// action for a stored key, the key guide and the account balance.
struct APIKeyProviderCard: View {
    let entry: APIKeyListEntry
    @Binding var draft: String
    let balances: ProviderBalanceStore
    let onClearStoredKey: () -> Void

    var body: some View {
        let presentation = APIKeyProviderPresentation(entryID: entry.id)
        Section {
            SecureField("API Key", text: $draft)
                .textContentType(.password)
                .autocorrectionDisabled()

            if entry.isStored && draft.isEmpty {
                Button("Clear Stored Key", role: .destructive) {
                    onClearStoredKey()
                }
            }

            APIKeyGuideDisclosure(
                identifier: APIKeysView.credentialIdentifier(for: entry.id), uses: APIKeysView.guideUses(for: entry)
            )

            // Purely informational: a billing endpoint that fails changes this
            // line and nothing else on the screen.
            ProviderBalanceView(
                credentialIdentifier: APIKeysView.credentialIdentifier(for: entry.id),
                isKeyStored: entry.isStored,
                store: balances
            )
        } header: {
            HStack {
                Label(presentation.title, systemImage: presentation.systemImage)
                Spacer()
                Text(entry.hasError ? "Error" : entry.isStored ? "Set" : "Unset")
                    .font(.caption)
                    .foregroundStyle(entry.hasError ? .red : entry.isStored ? .green : .secondary)
            }
        } footer: {
            Text(presentation.help)
                .font(.caption)
        }
    }
}
#endif
