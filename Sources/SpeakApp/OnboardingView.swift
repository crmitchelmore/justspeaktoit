import AppKit
import AVFoundation
import SpeakHotKeys
import SwiftUI

// MARK: - Provider Info for Onboarding

enum OnboardingProvider: String, CaseIterable, Identifiable {
    case deepgram
    case openai
    case openrouter
    case revai
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .openai: return "OpenAI Whisper"
        case .openrouter: return "OpenRouter"
        case .revai: return "Rev.ai"
        }
    }
    
    var signupURL: URL {
        switch self {
        case .deepgram: return URL(string: "https://console.deepgram.com/signup")!
        case .openai: return URL(string: "https://platform.openai.com/signup")!
        case .openrouter: return URL(string: "https://openrouter.ai/keys")!
        case .revai: return URL(string: "https://www.rev.ai/auth/signup")!
        }
    }
    
    var apiKeyInstructions: String {
        switch self {
        case .deepgram: return "Go to Settings → API Keys → Create Key"
        case .openai: return "Go to API Keys → Create new secret key"
        case .openrouter: return "Go to Keys → Create Key"
        case .revai: return "Go to Access Token → Generate Token"
        }
    }
    
    var freeCredits: String? {
        switch self {
        case .deepgram: return "Free tier includes $200 credit"
        case .openai: return nil
        case .openrouter: return "Pay-as-you-go with many model options"
        case .revai: return "Free tier includes 5 hours"
        }
    }
    
    var keychainIdentifier: String { "\(rawValue).apiKey" }
}

// MARK: - Onboarding State

@MainActor
final class OnboardingState: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var selectedProvider: OnboardingProvider = .deepgram
    @Published var apiKey = ""
    @Published var isValidating = false
    @Published var validationError: String?
    @Published var permissionsGranted: Set<PermissionType> = []
    @Published var selectedHotKey: HotKey = .fnKey
    
    // Test recording state
    @Published var isTestRecording = false
    @Published var testRecordingText: String?
    @Published var testRecordingError: String?
    
    let permissionsManager: PermissionsManager
    let secureStorage: SecureAppStorage
    let settings: AppSettings
    let hotKeyManager: HotKeyManager
    let audioFileManager: AudioFileManager
    let transcriptionManager: TranscriptionManager
    
    init(
        permissionsManager: PermissionsManager,
        secureStorage: SecureAppStorage,
        settings: AppSettings,
        hotKeyManager: HotKeyManager,
        audioFileManager: AudioFileManager,
        transcriptionManager: TranscriptionManager
    ) {
        self.permissionsManager = permissionsManager
        self.secureStorage = secureStorage
        self.settings = settings
        self.hotKeyManager = hotKeyManager
        self.audioFileManager = audioFileManager
        self.transcriptionManager = transcriptionManager
        self.selectedHotKey = settings.selectedHotKey
        refreshPermissions()
    }
    
    func refreshPermissions() {
        permissionsGranted = []
        for perm in [PermissionType.microphone, .accessibility, .inputMonitoring] {
            if permissionsManager.status(for: perm).isGranted {
                permissionsGranted.insert(perm)
            }
        }
    }
    
    var allPermissionsGranted: Bool {
        permissionsGranted.contains(.microphone) &&
        permissionsGranted.contains(.accessibility)
    }
    
    func validateAPIKey() async -> Bool {
        guard !apiKey.isEmpty else {
            validationError = "Please enter an API key"
            return false
        }
        
        isValidating = true
        validationError = nil
        
        do {
            switch selectedProvider {
            case .deepgram:
                let url = URL(string: "https://api.deepgram.com/v1/projects")!
                var request = URLRequest(url: url)
                request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        isValidating = false
                        return true
                    } else if httpResponse.statusCode == 401 {
                        validationError = "Invalid API key"
                    } else {
                        validationError = "Unexpected response (\(httpResponse.statusCode))"
                    }
                }
                
            case .openai:
                let url = URL(string: "https://api.openai.com/v1/models")!
                var request = URLRequest(url: url)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        isValidating = false
                        return true
                    } else if httpResponse.statusCode == 401 {
                        validationError = "Invalid API key"
                    } else {
                        validationError = "Unexpected response (\(httpResponse.statusCode))"
                    }
                }
                
            case .openrouter:
                let url = URL(string: "https://openrouter.ai/api/v1/models")!
                var request = URLRequest(url: url)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        isValidating = false
                        return true
                    } else if httpResponse.statusCode == 401 {
                        validationError = "Invalid API key"
                    } else {
                        validationError = "Unexpected response (\(httpResponse.statusCode))"
                    }
                }
                
            case .revai:
                let url = URL(string: "https://api.rev.ai/speechtotext/v1/account")!
                var request = URLRequest(url: url)
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        isValidating = false
                        return true
                    } else if httpResponse.statusCode == 401 {
                        validationError = "Invalid API key"
                    } else {
                        validationError = "Unexpected response (\(httpResponse.statusCode))"
                    }
                }
            }
        } catch {
            validationError = "Network error: \(error.localizedDescription)"
        }
        
        isValidating = false
        return false
    }
    
    func saveAPIKey() async throws {
        try await secureStorage.storeSecret(apiKey, identifier: selectedProvider.keychainIdentifier)
        // Register the key identifier so it shows up in settings
        settings.registerAPIKeyIdentifier(selectedProvider.keychainIdentifier)
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case hotkey
    case apiKey
    case testRecording
    case complete
    
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .hotkey: return "Hotkey"
        case .apiKey: return "API Key"
        case .testRecording: return "Test"
        case .complete: return "Ready!"
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @StateObject private var state: OnboardingState
    @Binding var isComplete: Bool
    
    init(
        permissionsManager: PermissionsManager,
        secureStorage: SecureAppStorage,
        settings: AppSettings,
        hotKeyManager: HotKeyManager,
        audioFileManager: AudioFileManager,
        transcriptionManager: TranscriptionManager,
        isComplete: Binding<Bool>
    ) {
        _state = StateObject(wrappedValue: OnboardingState(
            permissionsManager: permissionsManager,
            secureStorage: secureStorage,
            settings: settings,
            hotKeyManager: hotKeyManager,
            audioFileManager: audioFileManager,
            transcriptionManager: transcriptionManager
        ))
        _isComplete = isComplete
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= state.currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 30)
            
            // Content
            Group {
                switch state.currentStep {
                case .welcome:
                    WelcomeStepView(state: state)
                case .permissions:
                    PermissionsStepView(state: state)
                case .hotkey:
                    HotKeyStepView(state: state)
                case .apiKey:
                    APIKeyStepView(state: state)
                case .testRecording:
                    TestRecordingStepView(state: state)
                case .complete:
                    CompleteStepView(state: state, isComplete: $isComplete)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Spacer()
            
            // Navigation buttons
            HStack {
                if state.currentStep != .welcome {
                    Button("Back") {
                        withAnimation {
                            // Special case: if on .complete and testRecording was skipped
                            if state.currentStep == .complete && state.selectedHotKey == .fnKey {
                                // Go back to apiKey, skipping testRecording
                                state.currentStep = .apiKey
                            } else if let prev = OnboardingStep(rawValue: state.currentStep.rawValue - 1) {
                                state.currentStep = prev
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                if state.currentStep == .apiKey {
                    Button("Skip for Now") {
                        withAnimation {
                            // Skip API key and test recording, go straight to complete
                            state.currentStep = .complete
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                
                if state.currentStep == .complete {
                    Button("Get Started") {
                        isComplete = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button(state.currentStep == .apiKey ? "Save & Continue" : "Next") {
                        Task {
                            await advanceStep()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAdvance)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .frame(width: 600, height: 550)
    }
    
    private var canAdvance: Bool {
        switch state.currentStep {
        case .welcome:
            return true
        case .permissions:
            return state.permissionsGranted.contains(.microphone)
        case .hotkey:
            return true
        case .apiKey:
            return !state.apiKey.isEmpty && !state.isValidating
        case .testRecording:
            return true
        case .complete:
            return true
        }
    }
    
    private func advanceStep() async {
        switch state.currentStep {
        case .hotkey:
            // Save the selected hotkey to settings
            state.settings.selectedHotKey = state.selectedHotKey
            state.hotKeyManager.restartWithCurrentHotKey()
            if let next = OnboardingStep(rawValue: state.currentStep.rawValue + 1) {
                withAnimation {
                    state.currentStep = next
                }
            }
        case .apiKey:
            // Validate and save API key
            let valid = await state.validateAPIKey()
            if valid {
                do {
                    try await state.saveAPIKey()
                    withAnimation {
                        // If using non-Fn hotkey, show test recording; otherwise go to complete
                        if state.selectedHotKey != .fnKey {
                            state.currentStep = .testRecording
                        } else {
                            state.currentStep = .complete
                        }
                    }
                } catch {
                    state.validationError = "Failed to save: \(error.localizedDescription)"
                }
            }
        case .testRecording:
            withAnimation {
                state.currentStep = .complete
            }
        default:
            if let next = OnboardingStep(rawValue: state.currentStep.rawValue + 1) {
                withAnimation {
                    state.currentStep = next
                }
            }
        }
    }
}

// MARK: - Step Views

struct WelcomeStepView: View {
    @ObservedObject var state: OnboardingState
    
    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: AppIconProvider.applicationIcon())
                .resizable()
                .frame(width: 100, height: 100)
            
            Text("Just Speak to It")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Voice transcription that types for you")
                .font(.title3)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "mic.fill", title: "Speak naturally", description: "Record with a hotkey, speak normally")
                FeatureRow(icon: "keyboard.fill", title: "Text appears instantly", description: "Transcription is typed into any app")
                FeatureRow(icon: "key.fill", title: "Your keys, your privacy", description: "Bring your own API keys - no data collection")
            }
            .padding(.top, 20)
            .padding(.horizontal, 40)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct PermissionsStepView: View {
    @ObservedObject var state: OnboardingState
    @State private var showAccessibilityHelper = false
    @State private var accessibilityAttempted = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            
            Text("App Permissions")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Just Speak to It needs a few permissions to work")
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                PermissionRow(
                    type: .microphone,
                    title: "Microphone",
                    description: "To hear your voice",
                    isGranted: state.permissionsGranted.contains(.microphone),
                    onRequest: {
                        Task {
                            _ = await state.permissionsManager.request(.microphone)
                            state.refreshPermissions()
                        }
                    }
                )
                
                PermissionRow(
                    type: .accessibility,
                    title: "Accessibility",
                    description: "To type text into other apps",
                    isGranted: state.permissionsGranted.contains(.accessibility),
                    onRequest: {
                        accessibilityAttempted = true
                        Task {
                            _ = await state.permissionsManager.request(.accessibility)
                            // Wait a moment then check if it worked
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            state.refreshPermissions()
                            // If still not granted after attempt, show helper
                            if !state.permissionsGranted.contains(.accessibility) {
                                showAccessibilityHelper = true
                            }
                        }
                    }
                )
                
                // Show manual add helper if accessibility wasn't auto-added
                if showAccessibilityHelper && !state.permissionsGranted.contains(.accessibility) {
                    AccessibilityManualHelper(
                        onComplete: {
                            state.refreshPermissions()
                            if state.permissionsGranted.contains(.accessibility) {
                                showAccessibilityHelper = false
                            }
                        }
                    )
                }
                
                PermissionRow(
                    type: .inputMonitoring,
                    title: "Input Monitoring",
                    description: "For global hotkey detection",
                    isGranted: state.permissionsGranted.contains(.inputMonitoring),
                    isOptional: true,
                    onRequest: {
                        Task {
                            _ = await state.permissionsManager.request(.inputMonitoring)
                            state.refreshPermissions()
                        }
                    }
                )
            }
            .padding(.horizontal, 40)
            .padding(.top, 10)
            
            if !showAccessibilityHelper {
                Text("If permissions don't appear in System Settings, restart the app")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
                
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
    }
}

// MARK: - Accessibility Manual Helper

struct AccessibilityManualHelper: View {
    let onComplete: () -> Void
    @State private var currentStep = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("App not appearing? Add it manually:")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                ManualStep(number: 1, text: "Click the button below to open Accessibility settings", isActive: currentStep == 0)
                ManualStep(number: 2, text: "Click the + button at the bottom of the app list", isActive: currentStep == 1)
                ManualStep(number: 3, text: "Navigate to Applications → JustSpeakToIt", isActive: currentStep == 2)
                ManualStep(number: 4, text: "Click Open, then enable the toggle", isActive: currentStep == 3)
            }
            
            HStack(spacing: 12) {
                Button("Open Accessibility Settings") {
                    // Open directly to Accessibility pane
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    currentStep = 1
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button("I've Added It") {
                    onComplete()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("Show App in Finder") {
                    // Reveal the app in Finder
                    let appPath = Bundle.main.bundlePath
                    NSWorkspace.shared.selectFile(appPath, inFileViewerRootedAtPath: "")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundColor(.accentColor)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

struct ManualStep: View {
    let number: Int
    let text: String
    let isActive: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption)
                .fontWeight(isActive ? .bold : .regular)
                .foregroundColor(isActive ? .accentColor : .secondary)
                .frame(width: 16)
            
            Text(text)
                .font(.caption)
                .foregroundColor(isActive ? .primary : .secondary)
        }
    }
}

struct PermissionRow: View {
    let type: PermissionType
    let title: String
    let description: String
    let isGranted: Bool
    var isOptional = false
    let onRequest: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline)
                    if isOptional {
                        Text("(Optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            } else {
                Button("Grant") {
                    onRequest()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

struct APIKeyStepView: View {
    @ObservedObject var state: OnboardingState
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "key.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.accentColor)
                
                Text("Set Up Transcription")
                    .font(.title)
                    .fontWeight(.bold)
                
                // Provider selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose your transcription provider:")
                        .font(.subheadline)
                    
                    Picker("Provider", selection: $state.selectedProvider) {
                        ForEach(OnboardingProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: state.selectedProvider) { _, _ in
                        state.apiKey = ""
                        state.validationError = nil
                    }
                }
                .padding(.horizontal, 40)
                
                VStack(alignment: .leading, spacing: 14) {
                    // Step 1: Sign up
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Create a free account")
                            .font(.headline)
                        
                        Link(destination: state.selectedProvider.signupURL) {
                            HStack {
                                Text("Sign up for \(state.selectedProvider.displayName)")
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                        .font(.subheadline)
                        
                        if let credits = state.selectedProvider.freeCredits {
                            Text(credits)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Step 2: Create key
                    VStack(alignment: .leading, spacing: 6) {
                        Text("2. Create an API key")
                            .font(.headline)
                        
                        Text(state.selectedProvider.apiKeyInstructions)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    // Step 3: Paste key
                    VStack(alignment: .leading, spacing: 6) {
                        Text("3. Paste your API key below")
                            .font(.headline)
                        
                        SecureField("\(state.selectedProvider.displayName) API Key", text: $state.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task {
                                    _ = await state.validateAPIKey()
                                }
                            }
                        
                        if state.isValidating {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Validating...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if let error = state.validationError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
                .padding(.horizontal, 40)
                
                Text("You can add more providers or change settings later")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Hotkey Step

struct HotKeyStepView: View {
    @ObservedObject var state: OnboardingState
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard.fill")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)
            
            Text("Choose Your Hotkey")
                .font(.title)
                .fontWeight(.bold)
            
            Text("This is the key you'll press to start and stop recording")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 16) {
                // Fn key option
                Button {
                    state.selectedHotKey = .fnKey
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("🌐")
                                    .font(.title2)
                                Text("Fn (Globe) Key")
                                    .font(.headline)
                            }
                            Text("Default — works on most Mac keyboards")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if state.selectedHotKey == .fnKey {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        }
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(state.selectedHotKey == .fnKey ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(state.selectedHotKey == .fnKey ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                }
                .buttonStyle(.plain)
                
                // Custom shortcut option
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Shortcut")
                                .font(.headline)
                            Text("Choose any key combination")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if state.selectedHotKey != .fnKey {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        }
                    }
                    
                    HotKeyRecorder("Record shortcut", hotKey: $state.selectedHotKey)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(state.selectedHotKey != .fnKey ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(state.selectedHotKey != .fnKey ? Color.accentColor : Color.clear, lineWidth: 2)
                )
            }
            .padding(.horizontal, 40)
            
            // Troubleshooting
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    TroubleshootingRow(icon: "globe", text: "If Fn opens emoji picker: go to System Settings → Keyboard → \"Press 🌐 key to\" and change it to \"Do Nothing\"")
                    TroubleshootingRow(icon: "keyboard", text: "External keyboards may not send Fn events — use a custom shortcut instead")
                    TroubleshootingRow(icon: "lock.shield", text: "Accessibility and Input Monitoring permissions are required for hotkey detection")
                }
                .padding(.top, 8)
            } label: {
                Text("Having trouble with Fn?")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 40)
        }
    }
}

struct TroubleshootingRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Test Recording Step

struct TestRecordingStepView: View {
    @ObservedObject var state: OnboardingState
    @State private var audioPlayer: AVAudioPlayer?
    @State private var recordingURL: URL?
    @State private var isPlaying = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)
            
            Text("Test Your Setup")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Record a short phrase to verify everything works")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 16) {
                // Hotkey reminder
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.accentColor)
                    Text("Press **\(state.selectedHotKey.displayString)** to record, or use the button below")
                        .font(.subheadline)
                }
                .padding()
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)
                
                // Record button
                Button {
                    Task {
                        if state.isTestRecording {
                            await stopTestRecording()
                        } else {
                            await startTestRecording()
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: state.isTestRecording ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                        Text(state.isTestRecording ? "Stop Recording" : "Start Recording")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(state.isTestRecording ? Color.red : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                
                // Results
                if let text = state.testRecordingText {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Transcription successful!")
                                .font(.headline)
                                .foregroundColor(.green)
                        }
                        
                        Text(text)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                        
                        // Playback button
                        if recordingURL != nil {
                            Button {
                                togglePlayback()
                            } label: {
                                HStack {
                                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                    Text(isPlaying ? "Stop Playback" : "Play Recording")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 40)
                }
                
                if let error = state.testRecordingError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 40)
                }
            }
            
            Text("You can skip this step and test later")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onDisappear {
            // Stop recording and playback if active when navigating away
            if state.isTestRecording {
                Task {
                    try? await state.audioFileManager.stopRecording()
                    state.isTestRecording = false
                }
            }
            audioPlayer?.stop()
            isPlaying = false
        }
    }
    
    private func startTestRecording() async {
        guard !state.isTestRecording else { return }
        state.testRecordingError = nil
        state.testRecordingText = nil
        state.isTestRecording = true
        do {
            let url = try await state.audioFileManager.startRecording()
            recordingURL = url
        } catch {
            state.isTestRecording = false
            state.testRecordingError = "Failed to start recording: \(error.localizedDescription)"
        }
    }
    
    private func stopTestRecording() async {
        do {
            let summary = try await state.audioFileManager.stopRecording()
            state.isTestRecording = false
            recordingURL = summary.url
            
            // Transcribe the recording
            let result = try await state.transcriptionManager.transcribeFile(at: summary.url)
            if result.text.isEmpty {
                state.testRecordingError = "No speech detected. Try speaking louder or check your microphone."
            } else {
                state.testRecordingText = result.text
            }
        } catch {
            state.isTestRecording = false
            state.testRecordingError = "Transcription failed: \(error.localizedDescription)"
        }
    }
    
    private func togglePlayback() {
        if isPlaying {
            audioPlayer?.stop()
            isPlaying = false
        } else if let url = recordingURL {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: url)
                audioPlayer?.play()
                isPlaying = true
                
                // Poll to reset isPlaying when audio finishes naturally
                Task {
                    while isPlaying, let player = audioPlayer {
                        if !player.isPlaying {
                            isPlaying = false
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    }
                }
            } catch {
                state.testRecordingError = "Failed to play recording: \(error.localizedDescription)"
            }
        }
    }
}

struct CompleteStepView: View {
    @ObservedObject var state: OnboardingState
    @Binding var isComplete: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)
            
            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Just Speak to It is ready to use")
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 16) {
                TipRow(icon: "keyboard", text: "Press \(state.selectedHotKey.displayString) to start recording")
                TipRow(icon: "text.cursor", text: "Click in any text field, then record")
                TipRow(icon: "gearshape.fill", text: "Right-click the menu bar icon for settings")
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
            
            Text("Tip: The app runs in your menu bar")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 10)
        }
    }
}

struct TipRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30)
            
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Preview

#if DEBUG
// Preview requires the full AppEnvironment to construct dependencies.
// Use the running app or SpeakHotKeysDemo for visual testing.
#endif
