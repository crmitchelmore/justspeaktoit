import AppKit
import SpeakCore
import SpeakHotKeys
import SwiftUI

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
                        .fill(
                            step.rawValue <= state.currentStep.rawValue
                                ? Color.accentColor : Color.secondary.opacity(0.3)
                        )
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
                    .accessibilityIdentifier("onboardingBackButton")
                }

                Spacer()

                if state.currentStep == .apiKey {
                    Button("Skip for Now") {
                        state.skipAPIKeySetup()
                        withAnimation {
                            // Skip API key and test recording, go straight to complete
                            state.currentStep = .complete
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("onboardingSkipButton")
                }

                if state.currentStep == .complete {
                    Button("Get Started") {
                        if AppEnvironment.shared?.analyticsAvailable == true {
                            UserDefaults.standard.set(true, forKey: "hasAnsweredAnalyticsConsent")
                            AppEnvironment.shared?.captureOnboardingCompletedAfterConsent()
                        } else {
                            AppEnvironment.shared?.capture(.onboardingCompleted(stepsSkipped: .zero))
                        }
                        isComplete = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboardingGetStartedButton")
                } else {
                    Button(nextButtonTitle) {
                        Task {
                            await advanceStep()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAdvance)
                    .accessibilityIdentifier("onboardingNextButton")
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .frame(width: 600, height: 550)
        .onAppear {
            AppEnvironment.shared?.capture(.onboardingStarted(entryPoint: .freshInstall))
        }
    }

    private var nextButtonTitle: String {
        state.currentStep == .apiKey && state.transcriptionLocation == .remote ? "Save & Continue" : "Next"
    }

    private var canAdvance: Bool {
        guard !state.isCompletingRemoteSetup else { return false }
        switch state.currentStep {
        case .welcome:
            return true
        case .permissions:
            return state.permissionsGranted.contains(.microphone)
        case .hotkey:
            return true
        case .apiKey:
            if state.transcriptionLocation == .local {
                return state.configuredLocalPreset != nil && !state.isConfiguringLocalModel
            }
            return !state.apiKey.isEmpty && !state.isValidating
        case .testRecording:
            return true
        case .complete:
            return true
        }
    }

    private func saveHotKeySelection() {
        // Alpha must not claim Stable's default shortcut just by pressing Next.
        guard ReleaseTrain.current == .stable || state.hotKeyWasChosen else { return }
        state.settings.chooseGlobalHotKey(state.selectedHotKey)
        state.hotKeyManager.restartWithCurrentHotKey()
    }

    private func advanceStep() async {
        let completedStep = state.currentStep
        switch state.currentStep {
        case .hotkey:
            saveHotKeySelection()
            if let next = OnboardingStep(rawValue: state.currentStep.rawValue + 1) {
                withAnimation {
                    state.currentStep = next
                }
            }
        case .apiKey:
            await finishTranscriptionSetup()
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
        // Track step completion for steps with an analytics mapping
        if let analyticsStep = completedStep.analyticsStep {
            AppEnvironment.shared?.capture(.onboardingStepCompleted(step: analyticsStep))
        }
    }

    private func finishTranscriptionSetup() async {
        guard canAdvance else { return }
        if state.transcriptionLocation == .remote {
            let completed = await state.completeRemoteSetup(
                validate: { await state.validateAPIKey() },
                save: { try await state.saveAPIKey() }
            )
            guard completed else { return }
            AppEnvironment.shared?.capture(.providerConfigured(
                provider: state.selectedProvider.analyticsProviderType,
                method: .manual
            ))
        } else {
            guard state.completeLocalModelSetup() else { return }
        }
        withAnimation {
            state.currentStep = state.selectedHotKey != .fnKey ? .testRecording : .complete
        }
    }
}
