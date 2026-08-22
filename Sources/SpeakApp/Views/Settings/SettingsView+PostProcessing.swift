// swiftlint:disable file_length
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
            "Universal-3.5 Pro supports contextual prompting, but this app currently sends keyterms only."
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
          Text("Comma-separated terms to boost recognition accuracy (e.g. proper nouns, jargon). Max 100 terms, each ≤50 characters.")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField(
            "AssemblyAI, Universal-3.5 Pro, Keanu Reeves",
            text: settingsBinding(\AppSettings.assemblyAIKeyterms)
          )
          .textFieldStyle(.roundedBorder)
        }
      }
      .speakTooltip("Add domain-specific terms to improve Universal-3.5 Pro recognition accuracy.")
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
              postProcessingLocationSelector

              Text("Choose whether cleanup runs locally on this Mac or remotely through OpenRouter.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isCloudPostProcessingModelSelected {
              remotePostProcessingSection
            } else {
              localPostProcessingSection
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

  private var remotePostProcessingSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Picker("Output Language", selection: settingsBinding(\AppSettings.postProcessingOutputLanguage)) {
          Text("English").tag("English")
          Text("Spanish").tag("Spanish")
          Text("French").tag("French")
          Text("German").tag("German")
          Text("Italian").tag("Italian")
          Text("Portuguese").tag("Portuguese")
          Text("Chinese").tag("Chinese")
          Text("Japanese").tag("Japanese")
          Text("Korean").tag("Korean")
          Text("Russian").tag("Russian")
          Text("Arabic").tag("Arabic")
          Text("Hindi").tag("Hindi")
        }
        .pickerStyle(.menu)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
        )
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

      ModelPicker(
        title: "Remote Post-processing Model",
        help: """
        Choose the OpenRouter model Speak will call for cloud LLM cleanup. \
        Mini and Lite models are faster and cheaper.
        """,
        options: cloudPostProcessingOptions,
        value: cloudPostProcessingModelBinding,
        credentialPurpose: .postProcessing,
        storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
        usesDetailedChooser: true
      )

      SettingsInlineInfo(
        title: "Remote post-processing uses OpenRouter",
        message:
          """
          Speak sends transcript cleanup requests for this model to OpenRouter. \
          Add an OpenRouter API key in Settings > API Keys before using remote post-processing.
          """,
        systemImage: "network"
      )

      if !isOpenRouterKeyStored {
        HStack(alignment: .center, spacing: 10) {
          Label("OpenRouter API key missing", systemImage: "exclamationmark.triangle.fill")
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
          Button("Add OpenRouter Key") {
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
          Text(
            settings.postProcessingTemperature,
            format: .number.precision(.fractionLength(2))
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        Slider(
          value: settingsBinding(\AppSettings.postProcessingTemperature), in: 0...1, step: 0.05)
        .speakTooltip("Lower values stay close to your words; higher values let Speak be more creative.")
      }
    }
  }

  private var localPostProcessingSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        Image(systemName: "lock.shield.fill")
          .foregroundStyle(Color.green)
          .imageScale(.small)
        Text("Local Post-processing - private on this Mac")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Color.green)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule()
          .fill(Color.green.opacity(0.12))
      )

      #if APP_STORE
      Text(
        """
        Local post-processing is separate from OpenRouter and cloud LLMs. Use the built-in rules \
        model for instant cleanup with no downloaded runtime.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      #else
      Text(
        """
        Local post-processing is separate from OpenRouter and cloud LLMs. Use the built-in rules \
        model for instant cleanup, or download GGUF instruction models from Hugging Face for local LLM cleanup.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      #endif

      if !DistributionChannel.current.supportsExternalLocalModelRuntime {
        localRuntimeUnavailableNote
      }

      Label(
        """
        Small local models can ignore strict formatting or style instructions. For reliable prompt-following, \
        use a larger local instruction model or a remote post-processing model.
        """,
        systemImage: "exclamationmark.triangle"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      localPostProcessingQuickStart
      #if !APP_STORE
      if !localPostProcessingModels.runtimeState.isInstalled {
        localPostProcessingRuntimeStatus
      }
      #endif

      #if APP_STORE
      ModelPicker(
        title: "Local Post-processing Model",
        help: "Used for local-only cleanup after transcription. Built-in rules need no runtime.",
        options: localPostProcessingOptions,
        value: localPostProcessingModelBinding,
        credentialPurpose: .postProcessing,
        storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
        allowsCustom: false
      )
      #else
      ModelPicker(
        title: "Local Post-processing Model",
        help: """
        Used for local-only cleanup after transcription. Built-in rules need no runtime; \
        Hugging Face GGUF models need the local llama.cpp runtime and a model download.
        """,
        options: localPostProcessingOptions,
        value: localPostProcessingModelBinding,
        credentialPurpose: .postProcessing,
        storedAPIKeyIdentifiers: Set(settings.trackedAPIKeyIdentifiers),
        allowsCustom: false
      )
      #endif

      #if !APP_STORE
      localPostProcessingManualImport
      #endif

      VStack(spacing: 10) {
        ForEach(ModelCatalog.postProcessing.filter { $0.id == LocalPostProcessingModelManager.builtInRulesModelID }) { option in
          builtInLocalPostProcessingRow(option)
        }
        #if !APP_STORE
        ForEach(localPostProcessingModels.availableModels) { model in
          localPostProcessingModelRow(model)
        }
        #endif
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.green.opacity(0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.green.opacity(0.2), lineWidth: 1)
    )
  }

  private var localPostProcessingQuickStart: some View {
    VStack(alignment: .leading, spacing: 8) {
      localModelStep(
        number: "1",
        title: "Choose Local",
        detail: "This switches transcript cleanup away from OpenRouter."
      )
      #if APP_STORE
      localModelStep(
        number: "2",
        title: "Use the built-in rules model",
        detail: "The built-in rules model stays available with no download or runtime."
      )
      localModelStep(
        number: "3",
        title: "Record normally",
        detail: "Speak runs built-in cleanup locally after transcription."
      )
      #else
      localModelStep(
        number: "2",
        title: "Download a local LLM model",
        detail: """
        GGUF models come from Hugging Face and show their approximate size before download. \
        The built-in rules model stays available with no download.
        """
      )
      localModelStep(
        number: "3",
        title: "Record normally",
        detail: "Speak runs cleanup locally after transcription. Downloaded models use the app-owned llama.cpp runtime."
      )
      #endif
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.green.opacity(0.08))
    )
  }

  #if !APP_STORE
  private var localPostProcessingRuntimeStatus: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: localPostProcessingRuntimeIcon)
        .foregroundStyle(localPostProcessingRuntimeTint)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        Text("Local LLM runtime")
          .font(.subheadline.weight(.semibold))
        Text("Required only for downloaded Hugging Face GGUF models. Built-in cleanup works without it.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if case .failed(let message) = localPostProcessingModels.runtimeState {
          Text(message)
            .font(.caption2)
            .foregroundStyle(.red)
        }
      }

      Spacer()

      switch localPostProcessingModels.runtimeState {
      case .installed:
        Text("Installed")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
      case .installing:
        ProgressView()
          .controlSize(.small)
      case .notInstalled, .failed:
        Button("Install Runtime") {
          Task { await localPostProcessingModels.installRuntime() }
        }
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }

  private var localPostProcessingManualImport: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Add a Hugging Face GGUF model")
        .font(.caption.weight(.semibold))
      Text(
        """
        Use this for compatible llama.cpp/GGUF instruction models. Paste the Hugging Face repo and exact \
        .gguf filename; Speak will download and run it locally.
        """
      )
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(spacing: 10) {
        TextField("Repo, e.g. unsloth/Qwen3-0.6B-GGUF", text: $localPostProcessingRepoID)
          .textFieldStyle(.roundedBorder)
        TextField("File, e.g. Qwen3-0.6B-Q4_K_M.gguf", text: $localPostProcessingFilename)
          .textFieldStyle(.roundedBorder)
      }
      HStack(spacing: 10) {
        TextField("Size MB (optional)", text: $localPostProcessingSizeMB)
          .textFieldStyle(.roundedBorder)
          .frame(width: 140)
        Button("Add Manual Model") {
          addLocalPostProcessingModel()
        }
        .buttonStyle(.bordered)
        Spacer()
      }
      if let localPostProcessingImportError {
        Text(localPostProcessingImportError)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }
  #endif

  private func builtInLocalPostProcessingRow(_ option: ModelCatalog.Option) -> some View {
    let isSelected = PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel)
      && settings.postProcessingModel.caseInsensitiveCompare(option.id) == .orderedSame
    return localModelRowContainer(isSelected: isSelected, tint: .green) {
      HStack(alignment: .top, spacing: 12) {
      Image(systemName: "wand.and.stars")
        .foregroundStyle(Color.green)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(option.displayName)
            .font(.subheadline.weight(.semibold))
          if isSelected {
            localModelBadge("Selected", tint: .green)
          }
          localModelBadge("Local", tint: .green)
          localModelBadge("Built in", tint: .secondary)
        }
        if let description = option.description {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text("Ready now - 0 MB download - local only")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
      }

      Spacer()

      if isSelected {
        selectedModelBadge()
      } else {
        Button("Use") {
          settings.postProcessingModel = option.id
        }
      }
      }
    }
  }

  #if !APP_STORE
  // swiftlint:disable:next function_body_length
  private func localPostProcessingModelRow(_ model: LocalPostProcessingModel) -> some View {
      let state = localPostProcessingModels.installState(for: model.id)
      let isSelected = state == .installed
        && settings.postProcessingModel.caseInsensitiveCompare(model.id) == .orderedSame
      return localModelRowContainer(isSelected: isSelected, tint: .green) {
        HStack(alignment: .top, spacing: 12) {
        Image(systemName: localPostProcessingModelIcon(for: state))
          .foregroundStyle(localPostProcessingModelTint(for: state))
          .frame(width: 24)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(model.displayName)
              .font(.subheadline.weight(.semibold))
            if isSelected {
              localModelBadge("Selected", tint: .green)
            }
            localModelBadge("Hugging Face", tint: Color.brandAccentDeep)
          }
          Text(model.description)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("\(model.sizeLabel) - \(model.repoID) / \(model.filename)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
          if case .failed(let message) = state {
            Text(message)
              .font(.caption2)
              .foregroundStyle(.red)
          }
        }

        Spacer()

        switch state {
        case .installed:
          VStack(alignment: .trailing, spacing: 8) {
            if isSelected {
              selectedModelBadge()
            } else {
              Button("Use") {
                settings.postProcessingModel = model.id
              }
            }
            Button("Delete") {
              localPostProcessingModels.deleteModel(model)
              if settings.postProcessingModel.caseInsensitiveCompare(model.id) == .orderedSame {
                settings.postProcessingModel = LocalPostProcessingModelManager.builtInRulesModelID
              }
            }
          }
        case .installing:
          VStack(alignment: .trailing, spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Text("Downloading")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        case .notInstalled, .failed:
          VStack(alignment: .trailing, spacing: 8) {
            Button("Download") {
              Task { await localPostProcessingModels.installModel(model) }
            }
          }
        }
      }
    }
  }

  private var localPostProcessingRuntimeIcon: String {
    switch localPostProcessingModels.runtimeState {
    case .installed: return "checkmark.circle.fill"
    case .installing: return "arrow.down.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .notInstalled: return "shippingbox"
    }
  }

  private var localPostProcessingRuntimeTint: Color {
    switch localPostProcessingModels.runtimeState {
    case .installed: return .green
    case .installing: return .brandAccentDeep
    case .failed: return .red
    case .notInstalled: return .secondary
    }
  }

  private func localPostProcessingModelIcon(for state: LocalPostProcessingModelManager.InstallState) -> String {
    switch state {
    case .installed: return "checkmark.circle.fill"
    case .installing: return "arrow.down.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .notInstalled: return "externaldrive.badge.plus"
    }
  }

  private func localPostProcessingModelTint(for state: LocalPostProcessingModelManager.InstallState) -> Color {
    switch state {
    case .installed: return .green
    case .installing: return .brandAccentDeep
    case .failed: return .red
    case .notInstalled: return .secondary
    }
  }

  private func addLocalPostProcessingModel() {
    localPostProcessingImportError = nil
    let size = Int(localPostProcessingSizeMB.trimmingCharacters(in: .whitespacesAndNewlines))
    do {
      _ = try localPostProcessingModels.addHuggingFaceModel(
        repoID: localPostProcessingRepoID,
        filename: localPostProcessingFilename,
        approximateSizeMB: size
      )
      localPostProcessingRepoID = ""
      localPostProcessingFilename = ""
      localPostProcessingSizeMB = ""
    } catch {
      localPostProcessingImportError = error.localizedDescription
    }
  }
  #endif
}
