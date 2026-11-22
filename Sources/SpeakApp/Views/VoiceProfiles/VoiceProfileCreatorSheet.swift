import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

/// Modal flow for capturing, importing or trimming 1-3 reference clips with mandatory consent.
struct VoiceProfileCreatorSheet: View {
    private enum ClipSourceTab: String, CaseIterable, Identifiable {
        case record
        case history
        case importFile

        var id: String { rawValue }
        var title: String {
            switch self {
            case .record: "Record Script"
            case .history: "From History"
            case .importFile: "Import File"
            }
        }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var history: HistoryManager
    @EnvironmentObject private var voiceProfiles: VoiceProfileManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var recorder: VoiceProfileRecorder
    @State private var name = ""
    @State private var language = "en"
    @State private var sourceTab: ClipSourceTab = .record
    @State private var stagedClips: [VoiceProfileStagedClip] = []
    @State private var isImportingFile = false
    @State private var transcribingClipID: UUID?
    @State private var consentAccepted = false
    @State private var errorMessage: String?

    init(permissionsManager: PermissionsManager, audioDeviceManager: AudioInputDeviceManager) {
        _recorder = StateObject(
            wrappedValue: VoiceProfileRecorder(
                permissionsManager: permissionsManager,
                audioDeviceManager: audioDeviceManager
            )
        )
    }

    private var languageOptions: [VoiceOutputLanguageOption] {
        VoiceOutputLanguageCatalog.options.filter {
            $0.id != VoiceOutputLanguageCatalog.automaticIdentifier
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !stagedClips.isEmpty
            && stagedClips.count <= VoiceProfile.maximumClips
            && stagedClips.allSatisfy(\.qualityReport.passed)
            && consentAccepted
            && !recorder.isRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Create Voice Profile")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    cleanupPreviewFiles()
                    Task {
                        await recorder.cancelRecording()
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("voiceProfileCancelButton")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    identitySection
                    sourceSection
                    clipsSection
                    consentSection
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Save Profile") {
                    saveProfile()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier("voiceProfileSaveButton")
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 600)
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.audio, .wav, .mpeg4Audio, .mp3],
            allowsMultipleSelection: false
        ) { result in
            handleImportedFile(result)
        }
    }
}

private extension VoiceProfileCreatorSheet {
    var identitySection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profile Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. My Narrator Voice", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Profile Name")
                    .accessibilityIdentifier("voiceProfileNameField")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Language")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Language", selection: $language) {
                    ForEach(languageOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("voiceProfileLanguagePicker")
            }
            .frame(width: 220)
        }
    }

    var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Clip Source", selection: $sourceTab) {
                ForEach(ClipSourceTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("voiceProfileSourcePicker")

            switch sourceTab {
            case .record:
                VoiceProfileRecorderSection(
                    recorder: recorder,
                    voiceProfiles: voiceProfiles,
                    isAtClipLimit: stagedClips.count >= VoiceProfile.maximumClips
                ) { clip in
                    appendClip(clip)
                }
            case .history:
                VoiceProfileHistoryPickerSection(
                    history: history,
                    voiceProfiles: voiceProfiles,
                    isAtClipLimit: stagedClips.count >= VoiceProfile.maximumClips
                ) { clip in
                    appendClip(clip)
                }
            case .importFile:
                importFileView
            }
        }
    }

    var importFileView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import a WAV, M4A, or MP3 speech sample (5–30 s; longer files are auto-trimmed).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose Audio File…") {
                isImportingFile = true
            }
            .buttonStyle(.bordered)
            .disabled(stagedClips.count >= VoiceProfile.maximumClips)
            .accessibilityIdentifier("voiceProfileImportFileButton")
        }
    }

    var clipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reference Clips (\(stagedClips.count)/\(VoiceProfile.maximumClips))")
                .font(.subheadline.weight(.semibold))

            if stagedClips.isEmpty {
                Text("Capture, pick from History, or import 1–3 clean 5–30s mono voice samples.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(stagedClips.enumerated()), id: \.element.id) { index, clip in
                    VoiceProfileStagedClipCard(
                        clip: clip,
                        index: index,
                        transcript: transcriptBinding(for: clip.id),
                        isTranscribing: transcribingClipID == clip.id,
                        disableAutoFill: transcribingClipID != nil,
                        onAutoFill: { Task { await autoFillTranscript(for: clip.id) } },
                        onRemove: { removeClip(at: index) }
                    )
                }
            }
        }
    }

    var consentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $consentAccepted) {
                Text(ConsentAttestation.requiredText)
                    .font(.callout)
            }
            .accessibilityIdentifier("voiceProfileConsentToggle")

            Text("Profiles and clips stay private on this Mac — never synced to iCloud, exported, or shared.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    func transcriptBinding(for clipID: UUID) -> Binding<String> {
        Binding(
            get: { stagedClips.first { $0.id == clipID }?.transcript ?? "" },
            set: { updated in
                guard let index = stagedClips.firstIndex(where: { $0.id == clipID }) else { return }
                stagedClips[index].transcript = updated
            }
        )
    }

    func appendClip(_ clip: VoiceProfileStagedClip) {
        errorMessage = nil
        guard stagedClips.count < VoiceProfile.maximumClips else { return }
        stagedClips.append(clip)
    }

    func removeClip(at index: Int) {
        guard stagedClips.indices.contains(index) else { return }
        if let url = stagedClips[index].previewURL {
            try? FileManager.default.removeItem(at: url)
        }
        stagedClips.remove(at: index)
    }

    func handleImportedFile(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let staged = try voiceProfiles.prepareClipFromFile(at: url, targetFormat: .pcm24k)
                appendClip(staged)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func autoFillTranscript(for clipID: UUID) async {
        guard let index = stagedClips.firstIndex(where: { $0.id == clipID }) else { return }
        errorMessage = nil
        transcribingClipID = clipID
        defer { transcribingClipID = nil }
        do {
            let text = try await voiceProfiles.transcribeBuffer(stagedClips[index].pcmBuffer)
            if let currentIndex = stagedClips.firstIndex(where: { $0.id == clipID }) {
                stagedClips[currentIndex].transcript = text
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveProfile() {
        errorMessage = nil
        guard consentAccepted else {
            errorMessage = VoiceProfileStoreError.consentRequired.localizedDescription
            return
        }
        let inputs = stagedClips.map { staged in
            VoiceProfileStore.ClipInput(
                id: staged.id,
                pcmBuffer: staged.pcmBuffer,
                targetFormat: .pcm24k,
                transcript: staged.transcript,
                source: staged.source
            )
        }
        do {
            _ = try voiceProfiles.createProfile(
                name: name,
                language: language,
                clips: inputs,
                consent: ConsentAttestation()
            )
            cleanupPreviewFiles()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cleanupPreviewFiles() {
        for clip in stagedClips {
            if let url = clip.previewURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
