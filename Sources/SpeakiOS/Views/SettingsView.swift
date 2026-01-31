#if os(iOS)
import SwiftUI
import SpeakCore

// MARK: - Settings Storage

/// Simple UserDefaults-based settings for iOS app.
@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()
    
    @Published public var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    
    @Published public var deepgramAPIKey: String {
        didSet { saveToKeychain(key: deepgramAPIKey, for: "deepgram.apiKey") }
    }
    
    @Published public var openRouterAPIKey: String {
        didSet { saveToKeychain(key: openRouterAPIKey, for: "openrouter.apiKey") }
    }
    
    @Published public var liveActivitiesEnabled: Bool {
        didSet { UserDefaults.standard.set(liveActivitiesEnabled, forKey: "liveActivitiesEnabled") }
    }
    
    @Published public var autoStartRecording: Bool {
        didSet { UserDefaults.standard.set(autoStartRecording, forKey: "autoStartRecording") }
    }
    
    private init() {
        let selected = UserDefaults.standard.string(forKey: "selectedModel") ?? "apple/local/SFSpeechRecognizer"
        let deepgram = Self.loadFromKeychain(for: "deepgram.apiKey") ?? ""
        let openRouter = Self.loadFromKeychain(for: "openrouter.apiKey") ?? ""
        
        // Default Live Activities to true if not set
        let liveActivities = UserDefaults.standard.object(forKey: "liveActivitiesEnabled") as? Bool ?? true
        let autoStart = UserDefaults.standard.bool(forKey: "autoStartRecording")
        
        self.selectedModel = selected
        self.deepgramAPIKey = deepgram
        self.openRouterAPIKey = openRouter
        self.liveActivitiesEnabled = liveActivities
        self.autoStartRecording = autoStart
        
        // Auto-configure default provider on first launch or when saved model requires missing key
        configureDefaultProviderIfNeeded()
    }
    
    /// Configure default transcription provider based on available API keys.
    /// Prefers Deepgram if API key is available, otherwise falls back to Apple Speech.
    private func configureDefaultProviderIfNeeded() {
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        let needsDeepgramKey = selectedModel.hasPrefix("deepgram") && !hasDeepgramKey
        
        if isFirstLaunch || needsDeepgramKey {
            if hasDeepgramKey {
                selectedModel = "deepgram/nova-2"
            } else {
                selectedModel = "apple/local/SFSpeechRecognizer"
            }
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
        }
    }
    
    /// Re-configure provider after onboarding or API key changes.
    public func reconfigureDefaultProvider() {
        if hasDeepgramKey {
            selectedModel = "deepgram/nova-2"
        }
    }
    
    public var hasDeepgramKey: Bool { !deepgramAPIKey.isEmpty }
    public var hasOpenRouterKey: Bool { !openRouterAPIKey.isEmpty }
    
    // MARK: - Keychain Helpers
    
    private func saveToKeychain(key: String, for account: String) {
        let service = "com.speak.ios.credentials"
        
        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        guard !key.isEmpty else { return }
        
        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.data(using: .utf8)!
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    
    private static func loadFromKeychain(for account: String) -> String? {
        let service = "com.speak.ios.credentials"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
}

// MARK: - Settings View

public struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    
    public init() {}
    
    public var body: some View {
        Form {
            Section("Transcription") {
                Picker("Live Model", selection: $settings.selectedModel) {
                    // Apple Speech (free, on-device)
                    Text("Apple Speech (On-Device)").tag("apple/local/SFSpeechRecognizer")
                    
                    // Deepgram options (always shown, but warn if no key)
                    Text("Deepgram Nova-2").tag("deepgram/nova-2")
                    Text("Deepgram Nova").tag("deepgram/nova")
                }
                
                if settings.selectedModel.hasPrefix("deepgram") && !settings.hasDeepgramKey {
                    Label("Add Deepgram API key below to use this model", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                
                LabeledContent("Language") {
                    Text(Locale.current.identifier)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Behavior") {
                Toggle(isOn: $settings.autoStartRecording) {
                    Label("Auto-Start Recording", systemImage: "mic.badge.plus")
                }
                
                if settings.autoStartRecording {
                    Text("Recording starts automatically when you open the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Toggle(isOn: $settings.liveActivitiesEnabled) {
                    Label("Live Activities", systemImage: "platter.filled.bottom.iphone")
                }
                
                if settings.liveActivitiesEnabled {
                    Text("Shows transcription progress on Lock Screen and Dynamic Island.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("API Keys") {
                HStack {
                    Label("Deepgram", systemImage: "waveform")
                        .accessibilityLabel("Deepgram API Key")
                    Spacer()
                    Text(settings.hasDeepgramKey ? "Stored" : "Missing")
                        .foregroundStyle(settings.hasDeepgramKey ? .green : .secondary)
                }
                .accessibilityElement(children: .combine)
                
                HStack {
                    Label("OpenRouter", systemImage: "network")
                        .accessibilityLabel("OpenRouter API Key")
                    Spacer()
                    Text(settings.hasOpenRouterKey ? "Stored" : "Missing")
                        .foregroundStyle(settings.hasOpenRouterKey ? .green : .secondary)
                }
                .accessibilityElement(children: .combine)
                
                NavigationLink {
                    APIKeysView(settings: settings)
                } label: {
                    Label("Manage Keys", systemImage: "key.viewfinder")
                }
            }
            
            Section("Sync") {
                // Sync status
                let syncStatus = SyncStatus.current()
                
                HStack {
                    Label("iCloud Keychain", systemImage: "icloud")
                    Spacer()
                    Text(syncStatus.iCloudKeychainAvailable ? "Available" : "Unavailable")
                        .foregroundStyle(syncStatus.iCloudKeychainAvailable ? .green : .secondary)
                }
                .accessibilityElement(children: .combine)
                
                if let lastSync = syncStatus.lastSyncDate {
                    LabeledContent("Last Sync") {
                        Text(lastSync, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // QR Transfer options
                NavigationLink {
                    QRCodeGeneratorView()
                } label: {
                    Label("Share to Another Device", systemImage: "qrcode")
                }
                
                NavigationLink {
                    QRCodeScannerView()
                } label: {
                    Label("Import from QR Code", systemImage: "qrcode.viewfinder")
                }
            }
            
            Section("Send to Mac") {
                NavigationLink {
                    SendToMacView()
                } label: {
                    Label("Configure Mac Connection", systemImage: "desktopcomputer")
                }
            }
            
            Section("Privacy & Debugging") {
                NavigationLink {
                    PrivacyView()
                } label: {
                    Label("Privacy Information", systemImage: "hand.raised")
                }
                
                Toggle(isOn: Binding(
                    get: { SpeakLogger.isDebugMode },
                    set: { SpeakLogger.isDebugMode = $0 }
                )) {
                    Label("Debug Logging", systemImage: "ant")
                }

                if SpeakLogger.isDebugMode {
                    Text("Debug mode logs additional details for troubleshooting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("About") {
                LabeledContent("Version") {
                    Text("1.0.0")
                        .foregroundStyle(.secondary)
                }
                
                LabeledContent("SpeakCore") {
                    Text(SpeakCore.version)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - API Keys View

struct APIKeysView: View {
    @ObservedObject var settings: AppSettings
    @State private var deepgramKey = ""
    @State private var openRouterKey = ""
    @State private var isValidating = false
    @State private var validationMessage: String?
    @State private var showingValidation = false
    
    var body: some View {
        Form {
            Section {
                SecureField("API Key", text: $deepgramKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                
                if settings.hasDeepgramKey && deepgramKey.isEmpty {
                    Button("Clear Stored Key", role: .destructive) {
                        settings.deepgramAPIKey = ""
                    }
                }
            } header: {
                Label("Deepgram", systemImage: "waveform")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Get your API key from deepgram.com")
                    if settings.hasDeepgramKey {
                        Text("✓ API key is stored")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
            }
            
            Section {
                SecureField("API Key", text: $openRouterKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                
                if settings.hasOpenRouterKey && openRouterKey.isEmpty {
                    Button("Clear Stored Key", role: .destructive) {
                        settings.openRouterAPIKey = ""
                    }
                }
            } header: {
                Label("OpenRouter", systemImage: "network")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Get your API key from openrouter.ai")
                    if settings.hasOpenRouterKey {
                        Text("✓ API key is stored")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
            }
        }
        .navigationTitle("API Keys")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isValidating {
                    ProgressView()
                } else {
                    Button("Save") {
                        saveKeys()
                    }
                    .disabled(deepgramKey.isEmpty && openRouterKey.isEmpty)
                }
            }
        }
        .alert("Validation", isPresented: $showingValidation) {
            Button("OK") {}
        } message: {
            Text(validationMessage ?? "Keys saved")
        }
    }
    
    private func saveKeys() {
        Task {
            isValidating = true
            var messages: [String] = []
            
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
            
            // Save OpenRouter key (no validation endpoint available)
            if !openRouterKey.isEmpty {
                settings.openRouterAPIKey = openRouterKey
                openRouterKey = ""
                messages.append("✓ OpenRouter key saved")
            }
            
            isValidating = false
            validationMessage = messages.joined(separator: "\n")
            showingValidation = true
        }
    }
}

// MARK: - Privacy View

struct PrivacyView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speak is designed with privacy in mind. Your audio and transcripts are processed according to the provider you select.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Audio Processing") {
                FeatureRow(
                    icon: "mic.fill",
                    title: "Apple Speech",
                    description: "Audio stays on your device. No data sent to cloud."
                )
                
                FeatureRow(
                    icon: "network",
                    title: "Deepgram",
                    description: "Audio streamed to Deepgram servers for transcription."
                )
            }
            
            Section("API Keys") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Secure Storage", systemImage: "lock.fill")
                        .font(.headline)
                    Text("API keys are encrypted in your device Keychain and never leave your device except when syncing via iCloud Keychain (end-to-end encrypted).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Network Activity") {
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(label: "Apple Speech", value: "On-device only")
                    InfoRow(label: "Deepgram", value: "During transcription")
                    InfoRow(label: "Send to Mac", value: "Local network only")
                    InfoRow(label: "iCloud Sync", value: "Settings & keys (optional)")
                }
                .font(.caption)
            }
            
            Section("What We Don't Collect") {
                VStack(alignment: .leading, spacing: 8) {
                    CheckRow(text: "No usage analytics")
                    CheckRow(text: "No personal information")
                    CheckRow(text: "No transcription content")
                    CheckRow(text: "No third-party tracking")
                }
            }
            
            Section("Permissions") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speak requires these permissions:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    PermissionRow(icon: "mic.fill", name: "Microphone", required: true)
                    PermissionRow(icon: "waveform", name: "Speech Recognition", required: true)
                    PermissionRow(icon: "network", name: "Local Network", required: false)
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.brandLagoon)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct CheckRow: View {
    let text: String
    
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
    }
}

struct PermissionRow: View {
    let icon: String
    let name: String
    let required: Bool
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.brandLagoon)
                .frame(width: 24)
            Text(name)
                .font(.caption)
            Spacer()
            Text(required ? "Required" : "Optional")
                .font(.caption2)
                .foregroundStyle(required ? .red : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(required ? Color.red.opacity(0.1) : Color.secondary.opacity(0.1), in: Capsule())
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}

#Preview("Privacy") {
    NavigationStack {
        PrivacyView()
    }
}
#endif
