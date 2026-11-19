#if os(iOS)
import SpeakCore
import SwiftUI

/// Local › Downloaded Model rows on the Transcription page: which downloaded
/// model transcribes recordings, and a warning when it isn't downloaded yet.
struct IOSDownloadedModelPicker: View {
    @ObservedObject private var manager = IOSLocalModelManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Picker("Downloaded Model", selection: selection) {
            ForEach(manager.models, id: \.id) { model in
                HStack {
                    Text(model.displayName)
                    Spacer()
                    if manager.state(for: model) != .installed {
                        Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .tag(model.id)
            }
        }
        .pickerStyle(.navigationLink)
        .accessibilityIdentifier("downloadedTranscriptionModelPicker")

        if let model = IOSLocalTranscriptionModels.model(for: settings.batchTranscriptionModel),
           manager.state(for: model) != .installed {
            Label(
                "Download \(model.displayName) in Downloaded Models below before recording.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .font(.caption)
            .accessibilityIdentifier("downloadedModelMissingWarning")
        }

        SettingsFootnote(
            "Transcribes each recording on \(DeviceCopy.thisDevice) when you stop, with no API key. "
                + "If the model isn't downloaded, transcription stops rather than uploading audio."
        )
    }

    private var selection: Binding<String> {
        Binding(
            get: { WhisperKitHuggingFaceModels.normalizedModelID(settings.batchTranscriptionModel) },
            set: { settings.selectDownloadedTranscriptionModel($0) }
        )
    }
}

/// Rows of Settings › Transcription › Downloaded Models: every downloadable
/// Whisper model with its size, state and actions, then a Hugging Face import.
struct IOSDownloadedModelsList: View {
    @ObservedObject private var manager = IOSLocalModelManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var importRepository = ""
    @State private var importModelName = ""
    @State private var showingImport = false
    @State private var errorMessage: String?

    var body: some View {
        if !manager.engineAvailable {
            Label("Downloaded models aren't available in this build.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("downloadedModelsUnavailable")
        }

        ForEach(manager.models, id: \.id) { model in
            IOSDownloadedModelRow(
                model: model,
                state: manager.state(for: model),
                sizeBytes: manager.installedSizeBytes(model),
                isRecommended: manager.isRecommended(model),
                isSelected: isActive(model),
                isImported: manager.isImported(model),
                actions: actions(for: model)
            )
        }

        DisclosureGroup("Import from Hugging Face", isExpanded: $showingImport) {
            TextField("Repository, e.g. argmaxinc/whisperkit-coreml", text: $importRepository)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Hugging Face repository")
                .accessibilityIdentifier("downloadedModelImportRepository")
            TextField("Model folder, e.g. openai_whisper-base", text: $importModelName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Model folder name")
                .accessibilityIdentifier("downloadedModelImportName")
            Button("Add Model") { importModel() }
                .disabled(
                    importRepository.trimmingCharacters(in: .whitespaces).isEmpty
                        || importModelName.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .accessibilityIdentifier("downloadedModelImportButton")
        }
        .accessibilityIdentifier("downloadedModelImportDisclosure")

        SettingsFootnote(
            "Downloaded models transcribe each recording on \(DeviceCopy.thisDevice) after you stop; "
                + "audio is never uploaded and there is no live text. Larger models are more accurate "
                + "but slower and need more memory. Imports must be WhisperKit Core ML models."
        )
        .onAppear { manager.refresh() }
        .alert(
            "Downloaded Models",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(errorMessage ?? "") }
        )
    }

    private func isActive(_ model: LocalTranscriptionModel) -> Bool {
        settings.transcriptionMode == .batch
            && WhisperKitHuggingFaceModels.normalizedModelID(settings.batchTranscriptionModel)
            .caseInsensitiveCompare(model.id) == .orderedSame
    }

    private func actions(for model: LocalTranscriptionModel) -> IOSDownloadedModelRow.Actions {
        IOSDownloadedModelRow.Actions(
            download: { manager.download(model) },
            cancel: { manager.cancelDownload(model) },
            use: { settings.selectDownloadedTranscriptionModel(model.id) },
            remove: {
                perform { manager.isImported(model) ? try manager.removeImport(model) : try manager.remove(model) }
            }
        )
    }

    private func importModel() {
        perform {
            let model = try manager.importModel(repoID: importRepository, modelName: importModelName)
            importRepository = ""
            importModelName = ""
            showingImport = false
            AccessibilityNotification.Announcement("Added \(model.displayName)").post()
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            settings.objectWillChange.send()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One model: name, size, state and the actions that state allows.
struct IOSDownloadedModelRow: View {
    /// What the row shows of a downloaded transcription or cleanup model.
    struct Model {
        let id: String
        let displayName: String
        let approximateSizeMB: Int
    }

    struct Actions {
        let download: () -> Void
        let cancel: () -> Void
        let use: () -> Void
        let remove: () -> Void
    }

    let model: Model
    let state: IOSLocalModelInstallState
    let sizeBytes: Int64?
    let isRecommended: Bool
    let isSelected: Bool
    let isImported: Bool
    let actions: Actions

    init(
        model: Model, state: IOSLocalModelInstallState, sizeBytes: Int64?, isRecommended: Bool, isSelected: Bool,
        isImported: Bool, actions: Actions
    ) {
        self.model = model
        self.state = state
        self.sizeBytes = sizeBytes
        self.isRecommended = isRecommended
        self.isSelected = isSelected
        self.isImported = isImported
        self.actions = actions
    }

    init(
        model: LocalTranscriptionModel, state: IOSLocalModelInstallState, sizeBytes: Int64?, isRecommended: Bool,
        isSelected: Bool, isImported: Bool, actions: Actions
    ) {
        self.init(
            model: Model(id: model.id, displayName: model.displayName, approximateSizeMB: model.approximateSizeMB),
            state: state, sizeBytes: sizeBytes, isRecommended: isRecommended, isSelected: isSelected,
            isImported: isImported, actions: actions
        )
    }

    /// Stable automation suffix: `local/whisperkit/base` → `local-whisperkit-base`.
    static func identifierSuffix(for model: Model) -> String {
        model.id.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    private var suffix: String { Self.identifierSuffix(for: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.displayName)
                .accessibilityValue(accessibilityState)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("downloadedModelRow.\(suffix)")
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            if case .downloading(let fraction) = state {
                ProgressView(value: fraction)
                    .accessibilityLabel("Download progress for \(model.displayName)")
                    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                    .accessibilityIdentifier("downloadedModelProgress.\(suffix)")
            }
            buttons
        }
        .padding(.vertical, 2)
        .onChange(of: state) { _, newState in
            announce(newState)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 16) {
            switch state {
            case .notInstalled, .failed:
                Button("Download") { actions.download() }
                    .accessibilityLabel("Download \(model.displayName)")
                    .accessibilityIdentifier("downloadedModelDownload.\(suffix)")
            case .downloading:
                Button("Cancel") { actions.cancel() }
                    .accessibilityLabel("Cancel downloading \(model.displayName)")
                    .accessibilityIdentifier("downloadedModelCancel.\(suffix)")
            case .installed:
                if !isSelected {
                    Button("Use") { actions.use() }
                        .accessibilityLabel("Use \(model.displayName)")
                        .accessibilityIdentifier("downloadedModelUse.\(suffix)")
                }
            }
            if state == .installed || (isImported && !isDownloading) {
                Button(isImported ? "Remove Import" : "Remove", role: .destructive) { actions.remove() }
                    .accessibilityLabel("Remove \(model.displayName)")
                    .accessibilityIdentifier("downloadedModelRemove.\(suffix)")
            }
        }
        // Separate tap targets inside one List row.
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    private var statusIsError: Bool {
        if case .failed = state { return true }
        return false
    }

    private var sizeText: String {
        if let sizeBytes, sizeBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
        guard model.approximateSizeMB > 0 else { return "Size unknown" }
        return "About " + ByteCountFormatter.string(
            fromByteCount: Int64(model.approximateSizeMB) * 1_000_000, countStyle: .file
        )
    }

    private var stateText: String {
        switch state {
        case .notInstalled: return "Not downloaded"
        case .downloading(let fraction): return "Downloading \(Int((fraction * 100).rounded()))%"
        case .installed: return isSelected ? "Downloaded · In use" : "Downloaded"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var detail: String {
        var parts = [sizeText, stateText]
        if !isRecommended { parts.append("May be slow on \(DeviceCopy.thisDevice)") }
        return parts.joined(separator: " · ")
    }

    private var accessibilityState: String {
        detail.replacingOccurrences(of: " · ", with: ", ")
    }

    private func announce(_ newState: IOSLocalModelInstallState) {
        switch newState {
        case .installed:
            AccessibilityNotification.Announcement("\(model.displayName) downloaded").post()
        case .failed:
            AccessibilityNotification.Announcement("\(model.displayName) download failed").post()
        case .notInstalled, .downloading:
            break
        }
    }
}
#endif
