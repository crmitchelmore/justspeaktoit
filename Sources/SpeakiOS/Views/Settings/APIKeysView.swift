#if os(iOS)
import SpeakCore
import SwiftUI

// swiftlint:disable file_length

// MARK: - API Keys View

// swiftlint:disable:next type_body_length
struct APIKeysView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var deepgramKey = ""
    @State private var openRouterKey = ""
    @State private var openAIKey = ""
    @State private var elevenLabsKey = ""
    @State private var cartesiaKey = ""
    @State private var sonioxKey = ""
    @State private var modulateKey = ""
    @State private var assemblyAIKey = ""
    @State private var gladiaKey = ""
    @State private var googleKey = ""
    @State private var xAIKey = ""
    @State private var azureKey = ""
    @State private var metaKey = ""
    @State private var speechmaticsKey = ""
    @State private var revAIKey = ""
    @State private var mistralKey = ""
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

    fileprivate static func entries(for settings: AppSettings) -> [APIKeyListEntry] {
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
                    .disabled(
                        deepgramKey.isEmpty
                            && openRouterKey.isEmpty
                            && openAIKey.isEmpty
                            && elevenLabsKey.isEmpty
                            && cartesiaKey.isEmpty
                            && sonioxKey.isEmpty
                            && modulateKey.isEmpty
                            && assemblyAIKey.isEmpty
                            && gladiaKey.isEmpty
                            && googleKey.isEmpty
                            && xAIKey.isEmpty
                            && metaKey.isEmpty
                            && azureKey.isEmpty
                    )
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
                credentialIdentifier: "\(entry.id).apiKey",
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

    // swiftlint:disable:next cyclomatic_complexity
    private func draftBinding(for id: String) -> Binding<String> {
        switch id {
        case "deepgram": return $deepgramKey
        case "elevenlabs": return $elevenLabsKey
        case "openrouter": return $openRouterKey
        case "openai": return $openAIKey
        case "cartesia": return $cartesiaKey
        case "soniox": return $sonioxKey
        case "modulate": return $modulateKey
        case "assemblyai": return $assemblyAIKey
        case "google": return $googleKey
        case "xai": return $xAIKey
        case "azure": return $azureKey
        case "meta": return $metaKey
        case "speechmatics": return $speechmaticsKey
        case "revai": return $revAIKey
        case "mistral": return $mistralKey
        default: return $gladiaKey
        }
    }

    private var storedCredentialIdentifiers: Set<String> {
        Set(allEntries.filter(\.isStored).map { "\($0.id).apiKey" })
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

    // swiftlint:disable:next cyclomatic_complexity
    private func clearStoredKey(for id: String) {
        switch id {
        case "deepgram": settings.deepgramAPIKey = ""
        case "elevenlabs": settings.elevenLabsAPIKey = ""
        case "openrouter": settings.openRouterAPIKey = ""
        case "openai": settings.openAIAPIKey = ""
        case "cartesia": settings.cartesiaAPIKey = ""
        case "soniox": settings.sonioxAPIKey = ""
        case "modulate": settings.modulateAPIKey = ""
        case "assemblyai": settings.assemblyAIAPIKey = ""
        case "google": settings.googleAPIKey = ""
        case "xai": settings.xAIAPIKey = ""
        case "azure": settings.azureAPIKey = ""
        case "meta": settings.metaAPIKey = ""
        case "speechmatics": settings.speechmaticsAPIKey = ""
        case "revai": settings.revAIAPIKey = ""
        case "mistral": settings.mistralAPIKey = ""
        default: settings.gladiaAPIKey = ""
        }
        reloadBalancesAfterCredentialChange()
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func saveKeys() {
        Task {
            isValidating = true
            var messages: [String] = []
            if !azureKey.isEmpty {
                do {
                    _ = try await AzureSpeechVoiceAPI().listVoices(credentials: azureKey)
                    settings.azureAPIKey = azureKey
                    azureKey = ""
                    messages.append("Azure key and region saved; transcription access depends on your resource.")
                } catch { messages.append(error.localizedDescription) }
            }

            // Validate and save Deepgram key
            if !deepgramKey.isEmpty {
                let validator = DeepgramAPIKeyValidator()
                let result = await validator.validate(deepgramKey)

                switch result.outcome {
                case .success:
                    settings.deepgramAPIKey = deepgramKey
                    deepgramKey = ""
                    messages.append("✓ Deepgram key validated and saved")
                    // Auto-select Deepgram as the provider now that we have a key
                    settings.reconfigureDefaultProvider()
                case .failure(let message):
                    messages.append("✗ Deepgram: \(message)")
                }
            }

            // Validate and save ElevenLabs key
            if !elevenLabsKey.isEmpty {
                let validator = ElevenLabsSTTAPIKeyValidator()
                let result = await validator.validate(elevenLabsKey)

                switch result.outcome {
                case .success:
                    settings.elevenLabsAPIKey = elevenLabsKey
                    elevenLabsKey = ""
                    messages.append("✓ ElevenLabs API key validated and saved")
                case .failure(let message):
                    messages.append("✗ ElevenLabs: \(message)")
                }
            }

            // Save OpenRouter key (no validation endpoint available)
            if !openRouterKey.isEmpty {
                settings.openRouterAPIKey = openRouterKey
                openRouterKey = ""
                messages.append("✓ OpenRouter key saved")
            }

            // Save OpenAI key (no cheap validation endpoint)
            if !openAIKey.isEmpty {
                settings.openAIAPIKey = openAIKey
                openAIKey = ""
                messages.append("✓ OpenAI key saved")
            }

            // Save Cartesia key (no cheap validation endpoint)
            if !cartesiaKey.isEmpty {
                settings.cartesiaAPIKey = cartesiaKey
                cartesiaKey = ""
                messages.append("✓ Cartesia key saved")
            }

            // The same Soniox credential powers transcription and voice output.
            if !sonioxKey.isEmpty {
                settings.sonioxAPIKey = sonioxKey
                sonioxKey = ""
                messages.append("✓ Soniox key saved for transcription and voice output")
            }

            // Save Modulate key (no cheap validation endpoint)
            if !modulateKey.isEmpty {
                settings.modulateAPIKey = modulateKey
                modulateKey = ""
                messages.append("✓ Modulate key saved")
            }

            // Save AssemblyAI key (no cheap validation endpoint)
            if !assemblyAIKey.isEmpty {
                settings.assemblyAIAPIKey = assemblyAIKey
                assemblyAIKey = ""
                messages.append("✓ AssemblyAI key saved")
            }

            // Save Gladia key (no cheap validation endpoint)
            if !gladiaKey.isEmpty {
                settings.gladiaAPIKey = gladiaKey
                gladiaKey = ""
                messages.append("✓ Gladia key saved")
            }

            // Save Google Gemini key (validated when the session connects)
            if !googleKey.isEmpty {
                settings.googleAPIKey = googleKey
                googleKey = ""
                messages.append("✓ Google Gemini key saved")
            }

            // Save xAI key (validated when the realtime session connects)
            if !xAIKey.isEmpty {
                settings.xAIAPIKey = xAIKey
                xAIKey = ""
                messages.append("✓ xAI key saved")
            }

            if !metaKey.isEmpty {
                let result = await MetaMuseAPIKeyValidator().validate(metaKey)
                switch result.outcome {
                case .success:
                    settings.metaAPIKey = metaKey
                    metaKey = ""
                    messages.append("✓ Meta key validated for Muse Voice Transcribe and saved")
                case .failure(let message):
                    messages.append("✗ Meta: \(message)")
                }
            }

            // Saved without a probe: Speechmatics, Rev.ai and Mistral all
            // validate the credential when the realtime session connects, and
            // a stored key is never read as entitlement.
            if !speechmaticsKey.isEmpty {
                settings.speechmaticsAPIKey = speechmaticsKey
                speechmaticsKey = ""
                messages.append("✓ Speechmatics key saved")
            }

            if !revAIKey.isEmpty {
                settings.revAIAPIKey = revAIKey
                revAIKey = ""
                messages.append("✓ Rev.ai access token saved")
            }

            if !mistralKey.isEmpty {
                settings.mistralAPIKey = mistralKey
                mistralKey = ""
                messages.append("✓ Mistral key saved")
            }

            isValidating = false
            validationMessage = messages.joined(separator: "\n")
            showingValidation = true
            reloadBalancesAfterCredentialChange()
        }
    }
}
#endif
