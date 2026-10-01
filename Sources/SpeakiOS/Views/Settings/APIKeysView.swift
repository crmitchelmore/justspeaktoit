#if os(iOS)
import SpeakCore
import SwiftUI
import os.log

// swiftlint:disable file_length

private let apiKeysLogger = SpeakLogger.logger(category: "APIKeys")

// MARK: - API Key Drafts

/// The keys typed on the API Keys screen, keyed by entry id.
///
/// Every field reads and writes here, so whether Save has anything to save
/// covers each editable key, including a provider added later.
struct APIKeyDrafts: Equatable {
    private var values: [String: String] = [:]

    subscript(id: String) -> String {
        get { self.values[id] ?? "" }
        set { self.values[id] = newValue }
    }

    var hasUnsavedKey: Bool {
        self.values.values.contains { !$0.isEmpty }
    }

    /// The non-empty drafts at the moment Save is pressed.
    func submission() -> [String: String] {
        self.values.filter { !$0.value.isEmpty }
    }

    /// Clears a saved draft, unless the user has edited it since submitting.
    mutating func clear(_ id: String, ifStill submitted: String) {
        guard self.values[id] == submitted else { return }
        self.values[id] = nil
    }
}

// MARK: - API Keys View

// swiftlint:disable:next type_body_length
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
    /// Account balances shown beside the saved keys, deduplicated per account
    /// by `ProviderBalanceDirectory`.
    @StateObject private var balances = ProviderBalanceStore()

    private struct KeyPresentation {
        let title: String
        let systemImage: String
        let help: String
    }

    private var allEntries: [APIKeyListEntry] {
        Self.entries(for: settings)
    }

    static func entries(for settings: AppSettings) -> [APIKeyListEntry] {
        coreEntries(for: settings) + streamingProviderEntries(for: settings)
    }

    private static func coreEntries(for settings: AppSettings) -> [APIKeyListEntry] {
        [
            APIKeyListEntry(
                id: "deepgram", title: "Deepgram", category: "Transcription", isStored: settings.hasDeepgramKey
            ),
            APIKeyListEntry(
                id: "elevenlabs", title: "ElevenLabs", category: "Transcription & Voice Output",
                isStored: settings.hasElevenLabsKey
            ),
            APIKeyListEntry(
                id: "openrouter", title: "OpenRouter", category: "Post-processing", isStored: settings.hasOpenRouterKey
            ),
            APIKeyListEntry(
                id: "openai", title: "OpenAI", category: "Transcription", isStored: settings.hasOpenAIKey
            ),
            APIKeyListEntry(
                id: "cartesia", title: "Cartesia", category: "Transcription", isStored: settings.hasCartesiaKey
            ),
            APIKeyListEntry(
                id: "soniox", title: "Soniox", category: "Transcription & Voice Output",
                isStored: settings.hasSonioxKey
            ),
            APIKeyListEntry(
                id: "modulate", title: "Modulate", category: "Transcription", isStored: settings.hasModulateKey
            ),
            APIKeyListEntry(
                id: "assemblyai", title: "AssemblyAI", category: "Transcription",
                isStored: settings.hasAssemblyAIKey
            ),
            APIKeyListEntry(
                id: "gladia", title: "Gladia", category: "Transcription", isStored: settings.hasGladiaKey
            ),
            APIKeyListEntry(
                id: "google", title: GeminiTranscribeModels.providerDisplayName,
                category: "Transcription", isStored: settings.hasGoogleKey
            )
        ]
    }

    private static func streamingProviderEntries(for settings: AppSettings) -> [APIKeyListEntry] {
        [
            APIKeyListEntry(
                id: "xai", title: "xAI", category: "Transcription", isStored: settings.hasXAIKey
            ),
            APIKeyListEntry(
                id: "meta", title: "Meta", category: "Transcription", isStored: settings.hasMetaKey
            ),
            APIKeyListEntry(
                id: "speechmatics", title: "Speechmatics", category: "Transcription & Voice Output",
                isStored: settings.hasSpeechmaticsKey
            ),
            APIKeyListEntry(
                id: "revai", title: "Rev.ai", category: "Transcription", isStored: settings.hasRevAIKey
            ),
            APIKeyListEntry(
                id: "mistral", title: "Mistral", category: "Transcription & Voice Output",
                isStored: settings.hasMistralKey
            ),
            APIKeyListEntry(
                id: "azure", title: "Azure Speech", category: "Transcription", isStored: settings.hasAzureKey
            )
        ]
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
            Section("Azure Speech resource") { AzureSpeechEndpointField() }
            if visibleEntries.isEmpty {
                ContentUnavailableView(
                    "No API Keys",
                    systemImage: "key.slash",
                    description: Text("Try another search or status filter.")
                )
            } else {
                ForEach(visibleEntries) { entry in
                    apiKeySection(for: entry)
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
            ToolbarItem(placement: .topBarTrailing) {
                if isValidating {
                    ProgressView()
                } else {
                    Button("Save") {
                        saveKeys()
                    }
                    .disabled(!self.drafts.hasUnsavedKey)
                }
            }
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

    private func apiKeySection(for entry: APIKeyListEntry) -> some View {
        let presentation = presentation(for: entry.id)
        return Section {
            SecureField("API Key", text: draftBinding(for: entry.id))
                .textContentType(.password)
                .autocorrectionDisabled()

            if entry.isStored && draftBinding(for: entry.id).wrappedValue.isEmpty {
                Button("Clear Stored Key", role: .destructive) {
                    clearStoredKey(for: entry.id)
                }
            }

            // Purely informational: a billing endpoint that fails changes this
            // line and nothing else on the screen.
            ProviderBalanceView(
                credentialIdentifier: Self.credentialIdentifier(for: entry.id),
                isKeyStored: entry.isStored,
                store: balances
            )
        } header: {
            HStack {
                Label(presentation.title, systemImage: presentation.systemImage)
                Spacer()
                Text(entry.isStored ? "Stored" : "Missing")
                    .font(.caption)
                    .foregroundStyle(entry.isStored ? .green : .secondary)
            }
        } footer: {
            Text(presentation.help)
                .font(.caption)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func presentation(for id: String) -> KeyPresentation {
        switch id {
        case "deepgram":
            return KeyPresentation(
                title: "Deepgram",
                systemImage: "waveform",
                help: "Get your key from deepgram.com."
            )
        case "elevenlabs":
            return KeyPresentation(
                title: "ElevenLabs", systemImage: "mic.and.signal.meter", help: "Get your key from elevenlabs.io."
            )
        case "openrouter":
            return KeyPresentation(
                title: "OpenRouter",
                systemImage: "network",
                help: "Get your key from openrouter.ai."
            )
        case "openai":
            return KeyPresentation(
                title: "OpenAI", systemImage: "brain.head.profile", help: "Get your key from platform.openai.com."
            )
        case "cartesia":
            return KeyPresentation(
                title: "Cartesia", systemImage: "waveform.circle", help: "Get your key from cartesia.ai."
            )
        case "soniox":
            return KeyPresentation(
                title: "Soniox", systemImage: "waveform.badge.mic", help: "Get your key from soniox.com."
            )
        case "modulate":
            return KeyPresentation(
                title: "Modulate", systemImage: "waveform.badge.magnifyingglass", help: "Get your key from modulate.ai."
            )
        case "assemblyai":
            return KeyPresentation(
                title: "AssemblyAI", systemImage: "waveform.badge.plus", help: "Get your key from assemblyai.com."
            )
        case "google":
            return KeyPresentation(
                title: GeminiTranscribeModels.providerDisplayName, systemImage: "sparkles",
                help: "Get your key from aistudio.google.com."
            )
        case "xai":
            return KeyPresentation(
                title: "xAI", systemImage: "waveform.badge.mic", help: "Get your key from console.x.ai."
            )
        case "azure":
            return KeyPresentation(title: "Azure Speech", systemImage: "cloud",
                                   help: "Enter your Azure key and region as key:region.")
        case "meta":
            return KeyPresentation(
                title: "Meta", systemImage: "waveform.badge.mic",
                help: "Get your Model API key from llama.developer.meta.com."
            )
        case "speechmatics":
            return KeyPresentation(
                title: "Speechmatics", systemImage: "waveform.and.magnifyingglass",
                help: "Get your key from portal.speechmatics.com."
            )
        case "revai":
            return KeyPresentation(
                title: "Rev.ai", systemImage: "waveform.badge.mic",
                help: "Get your access token from www.rev.ai."
            )
        case "mistral":
            return KeyPresentation(
                title: "Mistral", systemImage: "waveform.circle",
                help: "Get your key from console.mistral.ai."
            )
        default:
            return KeyPresentation(
                title: "Gladia", systemImage: "waveform.badge.exclamationmark", help: "Get your key from gladia.io."
            )
        }
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
        id == "azure" ? AzureSpeechConfiguration.credentialIdentifier : "\(id).apiKey"
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

    private func clearStoredKey(for id: String) {
        self.store("", for: id)
        reloadBalancesAfterCredentialChange()
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func store(_ key: String, for id: String) {
        switch id {
        case "deepgram": settings.deepgramAPIKey = key
        case "elevenlabs": settings.elevenLabsAPIKey = key
        case "openrouter": settings.openRouterAPIKey = key
        case "openai": settings.openAIAPIKey = key
        case "cartesia": settings.cartesiaAPIKey = key
        case "soniox": settings.sonioxAPIKey = key
        case "modulate": settings.modulateAPIKey = key
        case "assemblyai": settings.assemblyAIAPIKey = key
        case "google": settings.googleAPIKey = key
        case "xai": settings.xAIAPIKey = key
        case "azure": settings.azureAPIKey = key
        case "meta": settings.metaAPIKey = key
        case "speechmatics": settings.speechmaticsAPIKey = key
        case "revai": settings.revAIAPIKey = key
        case "mistral": settings.mistralAPIKey = key
        default: settings.gladiaAPIKey = key
        }
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
        Task {
            isValidating = true
            var messages: [String] = []
            for id in order {
                guard let key = submission[id] else { continue }
                let message = await self.save(key, for: id)
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
    private func save(_ key: String, for id: String) async -> String {
        if let failure = await self.validationFailure(of: key, for: id) {
            return failure
        }
        self.store(key, for: id)
        self.drafts.clear(id, ifStill: key)
        if id == "deepgram" {
            // Auto-select Deepgram as the provider now that there is a key.
            settings.reconfigureDefaultProvider()
        }
        return Self.savedMessage(for: id, title: self.presentation(for: id).title)
    }

    /// The alert line for a key its provider rejects, or nil when the key
    /// passed or the provider has no cheap probe; the others check the key
    /// when a session connects, and a stored key is never read as entitlement.
    ///
    /// Provider responses can echo account details or the submitted key, so
    /// the alert gets a fixed local line and the original goes to the private
    /// log.
    private func validationFailure(of key: String, for id: String) async -> String? {
        let title = self.presentation(for: id).title
        let outcome: APIKeyValidationResult.Outcome
        switch id {
        case "azure":
            do {
                _ = try await AzureSpeechVoiceAPI().listVoices(credentials: key)
                return nil
            } catch {
                SpeakLogger.logError(error, context: "Azure Speech key validation", logger: apiKeysLogger)
                return "✗ \(title): the key and region could not be verified, so they were not saved."
            }
        case "deepgram":
            outcome = await DeepgramAPIKeyValidator().validate(key).outcome
        case "elevenlabs":
            outcome = await ElevenLabsSTTAPIKeyValidator().validate(key).outcome
        case "meta":
            outcome = await MetaMuseAPIKeyValidator().validate(key).outcome
        default:
            return nil
        }
        guard case .failure(let detail) = outcome else { return nil }
        apiKeysLogger.error(
            "API key validation failed for \(id, privacy: .public): \(detail, privacy: .private)"
        )
        return "✗ \(title): the key could not be verified, so it was not saved. Check it and try again."
    }

    private static func savedMessage(for id: String, title: String) -> String {
        switch id {
        case "azure":
            return "✓ Azure key and region saved; transcription access depends on your resource."
        case "deepgram", "elevenlabs":
            return "✓ \(title) key validated and saved"
        case "meta":
            return "✓ Meta key validated for Muse Voice Transcribe and saved"
        case "soniox":
            return "✓ Soniox key saved for transcription and voice output"
        case "revai":
            return "✓ Rev.ai access token saved"
        default:
            return "✓ \(title) key saved"
        }
    }
}
#endif
