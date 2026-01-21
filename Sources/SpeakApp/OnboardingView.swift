import AppKit
import SwiftUI

// MARK: - Onboarding State

@MainActor
final class OnboardingState: ObservableObject {
    @Published var currentStep: OnboardingStep = .welcome
    @Published var deepgramKey = ""
    @Published var isValidating = false
    @Published var validationError: String?
    @Published var permissionsGranted: Set<PermissionType> = []
    
    let permissionsManager: PermissionsManager
    let secureStorage: SecureAppStorage
    
    init(permissionsManager: PermissionsManager, secureStorage: SecureAppStorage) {
        self.permissionsManager = permissionsManager
        self.secureStorage = secureStorage
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
    
    func validateDeepgramKey() async -> Bool {
        guard !deepgramKey.isEmpty else {
            validationError = "Please enter an API key"
            return false
        }
        
        isValidating = true
        validationError = nil
        
        // Simple validation - try to connect to Deepgram
        let url = URL(string: "https://api.deepgram.com/v1/projects")!
        var request = URLRequest(url: url)
        request.setValue("Token \(deepgramKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                isValidating = false
                if httpResponse.statusCode == 200 {
                    return true
                } else if httpResponse.statusCode == 401 {
                    validationError = "Invalid API key"
                    return false
                } else {
                    validationError = "Unexpected response (\(httpResponse.statusCode))"
                    return false
                }
            }
        } catch {
            isValidating = false
            validationError = "Network error: \(error.localizedDescription)"
            return false
        }
        
        isValidating = false
        return false
    }
    
    func saveDeepgramKey() async throws {
        try await secureStorage.storeSecret(deepgramKey, identifier: "deepgram")
    }
}

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case apiKey
    case complete
    
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .apiKey: return "API Key"
        case .complete: return "Ready!"
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @StateObject private var state: OnboardingState
    @Binding var isComplete: Bool
    
    init(permissionsManager: PermissionsManager, secureStorage: SecureAppStorage, isComplete: Binding<Bool>) {
        _state = StateObject(wrappedValue: OnboardingState(
            permissionsManager: permissionsManager,
            secureStorage: secureStorage
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
                case .apiKey:
                    APIKeyStepView(state: state)
                case .complete:
                    CompleteStepView(isComplete: $isComplete)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Spacer()
            
            // Navigation buttons
            HStack {
                if state.currentStep != .welcome {
                    Button("Back") {
                        withAnimation {
                            if let prev = OnboardingStep(rawValue: state.currentStep.rawValue - 1) {
                                state.currentStep = prev
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                if state.currentStep == .complete {
                    Button("Get Started") {
                        isComplete = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button(state.currentStep == .apiKey ? "Continue" : "Next") {
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
        .frame(width: 600, height: 500)
    }
    
    private var canAdvance: Bool {
        switch state.currentStep {
        case .welcome:
            return true
        case .permissions:
            return state.permissionsGranted.contains(.microphone)
        case .apiKey:
            return !state.deepgramKey.isEmpty && !state.isValidating
        case .complete:
            return true
        }
    }
    
    private func advanceStep() async {
        switch state.currentStep {
        case .apiKey:
            // Validate and save API key
            let valid = await state.validateDeepgramKey()
            if valid {
                do {
                    try await state.saveDeepgramKey()
                    withAnimation {
                        state.currentStep = .complete
                    }
                } catch {
                    state.validationError = "Failed to save: \(error.localizedDescription)"
                }
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
                        Task {
                            _ = await state.permissionsManager.request(.accessibility)
                            state.refreshPermissions()
                        }
                    }
                )
                
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
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
            
            Text("Set Up Transcription")
                .font(.title)
                .fontWeight(.bold)
            
            Text("We recommend **Deepgram** for fast, accurate transcription")
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Create a free Deepgram account")
                        .font(.headline)
                    
                    Link(destination: URL(string: "https://console.deepgram.com/signup")!) {
                        HStack {
                            Text("Sign up at deepgram.com")
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                    .font(.subheadline)
                    
                    Text("Free tier includes $200 credit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("2. Create an API key")
                        .font(.headline)
                    
                    Text("Go to Settings → API Keys → Create Key")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("3. Paste your API key below")
                        .font(.headline)
                    
                    SecureField("Deepgram API Key", text: $state.deepgramKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task {
                                _ = await state.validateDeepgramKey()
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
            .padding(.top, 10)
            
            Divider()
                .padding(.horizontal, 40)
            
            VStack(spacing: 8) {
                Text("Other providers available")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 16) {
                    Text("OpenAI Whisper")
                    Text("•")
                    Text("Rev.ai")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                
                Text("Configure in Settings after setup")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CompleteStepView: View {
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
                TipRow(icon: "command", text: "Press ⌥Space (Option+Space) to start recording")
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
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(
            permissionsManager: PermissionsManager(),
            secureStorage: SecureAppStorage(
                permissionsManager: PermissionsManager(),
                appSettings: AppSettings()
            ),
            isComplete: .constant(false)
        )
    }
}
#endif
