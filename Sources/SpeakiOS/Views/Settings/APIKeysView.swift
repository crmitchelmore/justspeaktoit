#if os(iOS)
import SpeakCore
import SwiftUI

/// The API Keys screen: the provider list, its search, filter and sort, and
/// the Save flow. Each provider is an `APIKeyProviderCard`; checking and
/// storing a key belongs to `APIKeyCredentialWriter`.
struct APIKeysView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var drafts = APIKeyDrafts()
    @State private var isValidating = false
    @State private var validationMessage: String?
    @State private var showingValidation = false
    @State private var searchText = ""
    @State private var statusFilter: APIKeyStatusFilter = .all
    @State private var sortOrder: APIKeySortOrder = .name
    /// Entries whose last save was rejected by the provider's check, for the
    /// Errors filter. Cleared when the key is saved or cleared.
    @State private var failedEntryIDs: Set<String> = []
    /// Account balances shown beside the saved keys, deduplicated per account
    /// by `ProviderBalanceDirectory`.
    @StateObject private var balances = ProviderBalanceStore()

    private var allEntries: [APIKeyListEntry] {
        Self.entries(for: settings, failedEntryIDs: failedEntryIDs)
    }

    static func entries(for settings: AppSettings, failedEntryIDs: Set<String> = []) -> [APIKeyListEntry] {
        APIKeyListEntries.all(for: settings, failedEntryIDs: failedEntryIDs)
    }

    private var visibleEntries: [APIKeyListEntry] {
        APIKeyListQuery.apply(
            to: allEntries,
            searchText: searchText,
            status: statusFilter,
            sortOrder: sortOrder
        )
    }

    var body: some View {
        Form {
            Section("Alibaba workspace for new keys") { AlibabaSpeechConfigurationFields() }
            Section("StepFun region for new keys") { StepFunRegionField() }
            Section("Azure Speech resource") { AzureSpeechEndpointField() }
            if visibleEntries.isEmpty {
                let empty = APIKeyListQuery.emptyState(status: statusFilter, searchText: searchText)
                ContentUnavailableView(empty.title, systemImage: empty.systemImage, description: Text(empty.message))
                    .accessibilityIdentifier("apiKeysEmptyState")
            } else {
                ForEach(visibleEntries) { entry in
                    APIKeyProviderCard(
                        entry: entry, draft: draftBinding(for: entry.id), balances: balances
                    ) {
                        clearStoredKey(for: entry.id)
                    }
                }
            }
        }
        .environment(\.defaultMinListRowHeight, settings.visualDensity.minimumListRowHeight)
        .listSectionSpacing(settings.visualDensity.listSectionSpacing)
        .navigationTitle("API Keys")
        .navigationBarTitleDisplayMode(
            settings.visualDensity.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize)
                ? .inline
                : .automatic
        )
        .controlSize(settings.visualDensity.isCompact ? .small : .regular)
        .searchable(text: $searchText, prompt: "Provider or use")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Status", selection: $statusFilter) {
                        ForEach(APIKeyStatusFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    .accessibilityIdentifier("apiKeysStatusFilter")
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(APIKeySortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                } label: {
                    Label("Filter and Sort", systemImage: statusFilter == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            saveAction
        }
        .alert("Validation", isPresented: $showingValidation) {
            Button("OK") {}
        } message: {
            Text(validationMessage ?? "Keys saved")
        }
        .task {
            let storage = AppSettings.canonicalCredentialStorage
            balances.configure { identifier in
                try? await storage.secret(identifier: identifier)
            }
            balances.refreshAll(storedCredentialIdentifiers: storedCredentialIdentifiers)
        }
        .onDisappear { balances.cancelAll() }
    }

    /// Native search replaces navigation-bar actions while a query is active.
    /// Keep the same save operation reachable above the keyboard when editing
    /// a filtered provider, without clearing the query or the entered drafts.
    private var saveAction: some View {
        HStack {
            if isValidating {
                ProgressView("Saving keys")
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                Button {
                    saveKeys()
                } label: {
                    Text("Save")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!self.drafts.hasUnsavedKey)
                .accessibilityIdentifier("apiKeysSaveButton")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func draftBinding(for id: String) -> Binding<String> {
        Binding(
            get: { self.drafts[id] },
            set: { self.drafts[id] = $0 }
        )
    }

    /// The Keychain identifier an entry's key is stored under, which is also
    /// the one `ProviderBalanceDirectory` resolves accounts by. Azure's is not
    /// `<entry id>.apiKey`.
    static func credentialIdentifier(for id: String) -> String {
        ProviderCredentialCatalogue.apiKeyIdentifier(for: id)
    }

    /// The uses this screen lists for an entry, so its key guide names only
    /// the permissions those features need.
    static func guideUses(for entry: APIKeyListEntry) -> APIKeyUses {
        // The OpenRouter key also backs OpenRouter Audio transcription and speech.
        if entry.id == "openrouter" { return [.transcription, .postProcessing, .voiceOutput] }
        var uses: APIKeyUses = []
        if entry.category.contains("Transcription") { uses.insert(.transcription) }
        if entry.category.contains("Post-processing") { uses.insert(.postProcessing) }
        if entry.category.contains("Voice Output") { uses.insert(.voiceOutput) }
        return uses
    }

    private var storedCredentialIdentifiers: Set<String> {
        Set(allEntries.filter(\.isStored).map { Self.credentialIdentifier(for: $0.id) })
    }

    /// Forgets every rendered balance and re-reads the accounts whose key is
    /// still stored.
    ///
    /// Saving or clearing a key replaces the credential a figure was read
    /// with, so the figure on screen can belong to an account the user is no
    /// longer using; invalidating first also stops a request already in flight
    /// from repopulating the entry with the previous account's balance.
    private func reloadBalancesAfterCredentialChange() {
        balances.reloadAfterCredentialChange(
            storedCredentialIdentifiers: storedCredentialIdentifiers
        )
    }

    private var writer: APIKeyCredentialWriter {
        APIKeyCredentialWriter(settings: settings)
    }

    private func clearStoredKey(for id: String) {
        writer.store("", for: id)
        failedEntryIDs.remove(id)
        reloadBalancesAfterCredentialChange()
    }

    /// Saves what was entered when Save was pressed.
    ///
    /// Validation waits on the network while the fields stay editable, so the
    /// submitted values are captured first: a key that passes is saved as it
    /// was checked, never as a later edit, and its field is cleared only if it
    /// still holds the submitted value.
    private func saveKeys() {
        let submission = self.drafts.submission()
        let order = self.allEntries.map(\.id)
        // Region-bound credentials read their new-key drafts when Save is pressed.
        var taggedCredentials: [String: Result<String, Error>] = [:]
        if let key = submission["alibaba"] {
            taggedCredentials["alibaba"] = Result { try AlibabaSpeechConfiguration.credentialsForSaving(key) }
        }
        if let key = submission["stepfun"] {
            taggedCredentials["stepfun"] = Result { try StepFunCredential.credentialsForSaving(key) }
        }
        Task {
            isValidating = true
            var messages: [String] = []
            for id in order {
                guard let key = submission[id] else { continue }
                let credential: String?
                if let tagged = taggedCredentials[id] {
                    switch tagged {
                    case .success(let value): credential = value
                    case .failure(let error):
                        failedEntryIDs.insert(id)
                        messages.append(error.localizedDescription)
                        continue
                    }
                } else { credential = nil }
                let message = await self.save(key, for: id, credential: credential)
                messages.append(message)
            }
            isValidating = false
            validationMessage = messages.joined(separator: "\n")
            showingValidation = true
            reloadBalancesAfterCredentialChange()
        }
    }

    /// Validates `key` where the provider has a cheap probe, stores it, and
    /// returns its line for the Validation alert.
    private func save(_ key: String, for id: String, credential: String? = nil) async -> String {
        let savedValue = credential ?? key
        if let failure = await writer.validationFailure(of: savedValue, for: id) {
            failedEntryIDs.insert(id)
            return failure
        }
        failedEntryIDs.remove(id)
        writer.store(savedValue, for: id)
        self.drafts.clear(id, ifStill: key)
        if id == "deepgram" {
            // Auto-select Deepgram as the provider now that there is a key.
            settings.reconfigureDefaultProvider()
        }
        return APIKeyCredentialWriter.savedMessage(for: id, title: APIKeyProviderPresentation(entryID: id).title)
    }
}
#endif
