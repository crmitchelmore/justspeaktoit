import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var postProcessingSettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      if settings.isActiveAssemblyAILiveModel {
        preprocessingSettings
      } else {
        fullPostProcessingSettings
      }
    }
  }

  var modulateFeatureSettings: some View {
    let usesEnglishFastBatch = settings.batchTranscriptionModel == "modulate/velma-2-stt-batch-english-vfast"

    return SettingsCard(
      title: "Modulate features",
      systemImage: "slider.horizontal.3",
      tint: Color.teal
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text(
          "These options apply to Modulate streaming and the multilingual batch model."
            + " Speaker diarisation is on by default."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        Toggle(
          "Speaker diarisation",
          isOn: settingsBinding(\AppSettings.modulateSpeakerDiarizationEnabled)
        )
        .speakTooltip("Label different speakers in Modulate transcripts when the provider supports it.")

        Toggle(
          "Emotion detection",
          isOn: settingsBinding(\AppSettings.modulateEmotionSignalEnabled)
        )
        .speakTooltip("Ask Modulate to attach an emotion label to each detected utterance.")

        Toggle(
          "Accent detection",
          isOn: settingsBinding(\AppSettings.modulateAccentSignalEnabled)
        )
        .speakTooltip("Ask Modulate to identify the speaker accent for each utterance.")

        Toggle(
          "PII/PHI tagging",
          isOn: settingsBinding(\AppSettings.modulatePIIPhiTaggingEnabled)
        )
        .speakTooltip("Wrap sensitive personal or health information in Modulate's tagging output.")

        if usesEnglishFastBatch {
          Text(
            "The Modulate English Fast batch model ignores these optional flags."
              + " They still apply to Modulate streaming and the multilingual batch model."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .speakTooltip("Configure Modulate's diarisation and signal-detection features.")
  }

  private var preprocessingSettings: some View {
    Group {
      SettingsCard(title: "Pre-processing", systemImage: "bolt.fill", tint: Color.mint) {
        VStack(alignment: .leading, spacing: 12) {
          Label(
            "Universal-3.6 Pro supports contextual prompting, but this app currently sends keyterms only."
              + " Formatting and style instructions remain in post-processing.",
            systemImage: "bolt.fill"
          )
          .font(.callout)
          .foregroundStyle(.mint)

          VStack(alignment: .leading, spacing: 6) {
            Text("Used by the AssemblyAI live integration:")
              .font(.caption.weight(.semibold))
            Label("Keyterms prompting (up to 100 terms, each up to 50 characters)", systemImage: "checkmark.circle")
            Label("Dynamic keyterm updates during a session", systemImage: "checkmark.circle")
            Label("One automatically formatted final transcript per turn", systemImage: "checkmark.circle")

            Text("Available in the API but not configured here:")
              .font(.caption.weight(.semibold))
              .padding(.top, 4)
            Label("Contextual prompt and agent context", systemImage: "info.circle")
            Text("Use transcript post-processing for formatting or behavioral instructions.")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
        }
      }
      .speakTooltip("The app sends AssemblyAI recognition keyterms; formatting prompts run after transcription.")

      SettingsCard(title: "Keyterms", systemImage: "textformat.abc", tint: Color.blue) {
        VStack(alignment: .leading, spacing: 8) {
          Text(
            "Comma-separated terms to boost recognition accuracy (e.g. proper nouns, jargon). "
              + "Max 100 terms, each ≤50 characters."
          )
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField(
            "AssemblyAI, Universal-3.6 Pro, Keanu Reeves",
            text: settingsBinding(\AppSettings.assemblyAIKeyterms)
          )
          .textFieldStyle(.roundedBorder)
        }
      }
      .speakTooltip("Add domain-specific terms to improve Universal-3.6 Pro recognition accuracy.")
    }
  }

  private var fullPostProcessingSettings: some View {
    Group {
      SettingsCard(title: "Cleanup", systemImage: "wand.and.stars", tint: Color.brandAccentWarm) {
        VStack(alignment: .leading, spacing: 12) {
          settingsToggle(
            "Enable Post-processing",
            isOn: settingsBinding(\AppSettings.postProcessingEnabled),
            tint: .brandAccentWarm
          )
          .disabled(settings.speedMode != .instant)
          .speakTooltip("Let Speak clean and enhance transcripts automatically before they reach your clipboard.")

          if settings.speedMode != .instant {
            Text("Post-processing is disabled while Processing Speed is set to \(settings.speedMode.displayName).")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          outputLanguageSection

          if hidesModelSelection {
            Text(paidAccess.simpleModelChoicesPolicy.explanation)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            VStack(alignment: .leading, spacing: 8) {
              Text("Post-processing location")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              PostProcessingLocationPicker()

              Text("Choose whether cleanup runs locally on this Mac or remotely through OpenRouter.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isCloudPostProcessingModelSelected {
              remotePostProcessingSection
            } else {
              LocalPostProcessingSection()
            }
          }
        }
      }
      .speakTooltip("Choose how Speak cleans up transcripts, including language and lexicon context.")

      SettingsCard(title: "Cleanup Context", systemImage: "gearshape.2", tint: Color.brandAccentDeep) {
        VStack(alignment: .leading, spacing: 16) {
          Text(systemGeneratedPartsHelpText)
            .font(.caption)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 12) {
            settingsToggle(
              "Include Personal Lexicon Directives",
              isOn: settingsBinding(\AppSettings.postProcessingIncludeLexiconDirectives),
              tint: .brandAccentDeep
            )
            .onChange(of: settings.postProcessingIncludeLexiconDirectives) { _, _ in
              generateSystemPromptPreview()
            }
            Text("Automatically applies your personal corrections and name normalizations to the transcript.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.leading, 28)

            Divider()

            settingsToggle(
              "Include Context Tags",
              isOn: settingsBinding(\AppSettings.postProcessingIncludeContextTags),
              tint: .brandAccentDeep
            )
            .onChange(of: settings.postProcessingIncludeContextTags) { _, _ in
              generateSystemPromptPreview()
            }
            Text("Adds context tags to help the model understand the setting and adjust output accordingly.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.leading, 28)

          }

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            Button {
              showSystemPromptPreview.toggle()
              if showSystemPromptPreview {
                DispatchQueue.main.async {
                  generateSystemPromptPreview()
                }
              }
            } label: {
              HStack {
                Image(systemName: showSystemPromptPreview ? "eye.slash" : "eye")
                Text(showSystemPromptPreview ? "Hide Current Prompt" : "Show Current Prompt")
              }
            }
            .buttonStyle(.bordered)

            if showSystemPromptPreview {
              VStack(alignment: .leading, spacing: 8) {
                Text("Current System Prompt Preview:")
                  .font(.caption.bold())
                  .foregroundStyle(.secondary)

                ScrollView {
                  Text(systemPromptPreview)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .scrollIndicators(.visible)
                .frame(minHeight: 200, maxHeight: 420)
                .background(
                  RoundedRectangle(cornerRadius: 8)
                    .fill(Color.brandAccentWarm.opacity(0.05))
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.brandAccentWarm.opacity(0.2), lineWidth: 1)
                )

                Text("Scroll to view the full prompt.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .speakTooltip("Fine-tune what system-generated instructions are sent to the post-processing model.")
    }
  }

  /// Output languages offered by the cleanup Output Language picker.
  ///
  /// Both post-processing locations read `postProcessingOutputLanguage`: the remote
  /// prompt and the downloaded-local prompt are built from the same setting, so the
  /// picker lives in the shared part of the Cleanup card (issue #852).
  static let postProcessingOutputLanguages: [String] = [
    "English",
    "Spanish",
    "French",
    "German",
    "Italian",
    "Portuguese",
    "Chinese",
    "Japanese",
    "Korean",
    "Russian",
    "Arabic",
    "Hindi"
  ]

  /// Output-language picker shared by local and remote post-processing.
  private var outputLanguageSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      LongListPicker(
        title: "Output Language", items: Self.postProcessingOutputLanguages,
        id: { $0 }, selection: settingsBinding(\AppSettings.postProcessingOutputLanguage), searchText: { [$0] },
        row: { language in
        Text(language)
      })
      .settingsMenuPicker()
      .speakTooltip("Let Speak know which language you want your polished transcript delivered in.")
      .onChange(of: settings.postProcessingOutputLanguage) { _, _ in
        if showSystemPromptPreview {
          generateSystemPromptPreview()
        }
      }

      Text("The language that the transcription will be output in.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// The provider the selected cloud model is actually sent to.
  private var remotePostProcessingRequirement: (identifier: String, providerName: String)? {
    guard case .apiKey(let identifier, let providerName) = ModelCredentialResolver.requirement(
      for: cloudPostProcessingModelBinding.wrappedValue, purpose: .postProcessing
    ) else { return nil }
    return (identifier, providerName)
  }

  private var remotePostProcessingProviderName: String {
    remotePostProcessingRequirement?.providerName ?? "OpenRouter"
  }

  private var isRemotePostProcessingKeyStored: Bool {
    remotePostProcessingRequirement.map { isAPIKeyStored($0.identifier) } ?? true
  }

  private var remotePostProcessingSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      ModelPicker(
        title: "Remote Post-processing Model",
        help: """
        Native provider models use that provider's own key. Use Browse OpenRouter models… to \
        discover and configure models from OpenRouter's wider catalogue. Mini and Lite models are faster and cheaper.
        """,
        options: cloudPostProcessingOptions,
        value: cloudPostProcessingModelBinding,
        credentialPurpose: .postProcessing,
        storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
        usesDetailedChooser: true,
        openRouterBrowser: cleanupOpenRouterBrowser
      )

      SettingsInlineInfo(
        title: "Remote post-processing uses \(remotePostProcessingProviderName)",
        message:
          """
          Speak sends transcript cleanup requests for this model to \(remotePostProcessingProviderName). \
          Save your \(remotePostProcessingProviderName) API key in Settings > API Keys \
          before using remote post-processing.
          """,
        systemImage: "network"
      )

      if !isRemotePostProcessingKeyStored {
        HStack(alignment: .center, spacing: 10) {
          Label("\(remotePostProcessingProviderName) API key missing", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
          Text(
            settings.postProcessingEnabled
              ? "Remote post-processing will be skipped until a key is saved."
              : "Save a key before enabling remote post-processing."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Spacer()
          Button("Add \(remotePostProcessingProviderName) Key") {
            sidebarSelection = .settings(.apiKeys)
          }
          .buttonStyle(.borderedProminent)
          .tint(.orange)
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.orange.opacity(0.10))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
      }

      VStack(alignment: .leading) {
        HStack {
          Text("Temperature")
          Spacer()
          Text(settings.postProcessingTemperature, format: .number.precision(.fractionLength(2)))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Slider(value: settingsBinding(\AppSettings.postProcessingTemperature), in: 0...1, step: 0.05)
        .accessibilityLabel("Temperature")
        .accessibilityValue(String(format: "%.2f", settings.postProcessingTemperature))
        .speakTooltip("Lower values stay close to your words; higher values let Speak be more creative.")
      }
    }
  }
}
