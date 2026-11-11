import AppKit
import SpeakCore
import SwiftUI

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

                Picker("Where transcription runs", selection: $state.transcriptionLocation) {
                    Text("Local").tag(AppSettings.TranscriptionLocation.local)
                    Text("Remote").tag(AppSettings.TranscriptionLocation.remote)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 40)
                .accessibilityIdentifier("onboardingTranscriptionLocationPicker")
                .onChange(of: state.transcriptionLocation) { _, location in
                    state.validationError = nil
                    if location == .remote {
                        state.leaveLocalModelSetup()
                        state.configuredLocalPreset = nil
                    }
                }

                if state.transcriptionLocation == .local {
                    OnboardingLocalModelSetupView(state: state)
                } else {
                    remoteSetup
                }
            }
            .padding(.vertical, 10)
        }
    }

    private var remoteSetup: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose your transcription provider:")
                    .font(.subheadline)

                Picker("Provider", selection: $state.selectedProvider) {
                    ForEach(OnboardingProvider.allCases) { provider in
                        Text(provider.pickerLabel).tag(provider)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("2. Create an API key")
                        .font(.headline)

                    Text(state.selectedProvider.apiKeyInstructions)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if let summary = APIKeyGuidance.promptSummary(
                        for: state.selectedProvider.keychainIdentifier, uses: state.selectedProvider.guideUses
                    ) {
                        Text(summary)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    APIKeyGuideDisclosure(
                        identifier: state.selectedProvider.keychainIdentifier, uses: state.selectedProvider.guideUses
                    )
                }

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
                            Text("Validating…")
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
    }
}
