import SpeakCore
import SwiftUI

/// Settings card indexed under "My Voices" in Voice Output settings.
struct VoiceProfilesSettingsCard: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var voiceProfiles: VoiceProfileManager

    @State private var showingCreator = false
    @State private var editingProfile: VoiceProfile?
    @State private var deletingProfile: VoiceProfile?
    @State private var errorMessage: String?

    var body: some View {
        SettingsCard(title: "My Voices", systemImage: "person.wave.2.fill", tint: Color.brandAccent) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Capture 1–3 consented reference clips (5–30s) to build personal voice profiles. "
                        + "Profiles stay private on this Mac and are excluded from History, iCloud sync, "
                        + "exports, backups, and phone transfers."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if voiceProfiles.profiles.isEmpty {
                    Text("No voice profiles yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(voiceProfiles.profiles) { profile in
                        profileRow(profile)
                    }
                }

                if let errorMessage = errorMessage ?? voiceProfiles.lastError {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    showingCreator = true
                } label: {
                    Label("Create Voice Profile…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("voiceProfileCreateButton")
            }
        }
        .sheet(isPresented: $showingCreator) {
            VoiceProfileCreatorSheet(
                permissionsManager: environment.permissions,
                audioDeviceManager: environment.audioDevices
            )
        }
        .sheet(item: $editingProfile) { profile in
            VoiceProfileDetailSheet(profile: profile)
        }
        .sheet(item: $deletingProfile) { profile in
            VoiceProfileDeleteConfirmationSheet(profile: profile) {
                deleteProfile(profile)
            }
        }
    }

    private func profileRow(_ profile: VoiceProfile) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline.weight(.medium))
                Text(rowSubtitle(for: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") {
                editingProfile = profile
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Edit \(profile.name)")
            .accessibilityIdentifier("voiceProfileEdit-\(profile.id)")

            Button(role: .destructive) {
                deletingProfile = profile
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(profile.name)")
            .accessibilityIdentifier("voiceProfileDelete-\(profile.id)")
        }
        .padding(.vertical, 4)
    }

    private func rowSubtitle(for profile: VoiceProfile) -> String {
        let clipLabel = profile.clips.count == 1 ? "1 clip" : "\(profile.clips.count) clips"
        let engineLabel: String
        if profile.engineBindings.isEmpty {
            engineLabel = "no speech engine bound yet"
        } else if profile.engineBindings.count == 1 {
            engineLabel = "1 engine bound"
        } else {
            engineLabel = "\(profile.engineBindings.count) engines bound"
        }
        return "\(clipLabel) · \(profile.language) · \(engineLabel)"
    }

    private func deleteProfile(_ profile: VoiceProfile) {
        errorMessage = nil
        do {
            _ = try voiceProfiles.deleteProfile(id: profile.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Modal wrapper opened from the Voice Output page's "Manage My Voices…" button.
struct VoiceProfilesQuickSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("My Voices")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("voiceProfilesQuickSheetDoneButton")
            }
            ScrollView {
                VoiceProfilesSettingsCard()
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }
}

/// Detail editor for inspecting bindings, playing clips and editing clip transcripts.
struct VoiceProfileDetailSheet: View {
    @EnvironmentObject private var voiceProfiles: VoiceProfileManager
    @Environment(\.dismiss) private var dismiss

    let profile: VoiceProfile
    @State private var name: String
    @State private var transcripts: [UUID: String]
    @State private var errorMessage: String?

    init(profile: VoiceProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _transcripts = State(
            initialValue: Dictionary(uniqueKeysWithValues: profile.clips.map { ($0.id, $0.transcript) })
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit Voice Profile")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("voiceProfileDetailDoneButton")
            }

            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Profile Name")
                .accessibilityIdentifier("voiceProfileDetailNameField")

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reference Clips")
                        .font(.subheadline.weight(.semibold))
                    ForEach(profile.clips) { clip in
                        clipDetailCard(clip)
                    }

                    Text("Bound Engines")
                        .font(.subheadline.weight(.semibold))
                    if profile.engineBindings.isEmpty {
                        Text("No speech engine is bound yet. This profile has no playable voices in Read Aloud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(profile.engineBindings.keys.sorted(), id: \.self) { key in
                            if let binding = profile.engineBindings[key] {
                                Text("\(binding.engineDisplayName) (\(binding.engineID))")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Save Changes") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("voiceProfileDetailSaveButton")
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
    }

    private func clipDetailCard(_ clip: VoiceProfileClip) -> some View {
        let durationText = String(format: "%.1f s", clip.durationSeconds)
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(clip.source.displayName) · \(durationText) · \(clip.sampleRate) Hz")
                .font(.caption.weight(.medium))
            if let url = try? voiceProfiles.clipURL(for: clip, in: profile.id) {
                AudioPlaybackControls(url: url)
            }
            TextEditor(text: Binding(
                get: { transcripts[clip.id] ?? "" },
                set: { transcripts[clip.id] = $0 }
            ))
            .font(.body)
            .frame(minHeight: 54, maxHeight: 80)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.25))
            )
            .accessibilityLabel("Transcript for \(clip.filename)")
            .accessibilityIdentifier("voiceProfileDetailTranscript-\(clip.id)")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func saveChanges() {
        errorMessage = nil
        do {
            _ = try voiceProfiles.renameProfile(id: profile.id, name: name)
            for clip in profile.clips {
                if let text = transcripts[clip.id], text != clip.transcript {
                    _ = try voiceProfiles.updateClipTranscript(
                        profileID: profile.id,
                        clipID: clip.id,
                        transcript: text
                    )
                }
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Confirmation dialog listing remote clones when deleting a profile (#1824).
struct VoiceProfileDeleteConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile: VoiceProfile
    let onConfirmDelete: () -> Void
    @State private var requestRemoteDeletion = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \"\(profile.name)\"?")
                .font(.headline)

            Text(
                "Deleting this voice profile permanently removes all reference audio clips, "
                    + "local voice embeddings, and engine bindings on this Mac."
            )
            .font(.body)

            if !profile.remoteBindings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remote cloud clones linked to this profile:")
                        .font(.subheadline.weight(.medium))
                    ForEach(profile.remoteBindings, id: \.engineID) { remote in
                        Text("• \(remote.providerDisplayName): \(remote.remoteVoiceID)")
                            .font(.caption)
                    }
                    Toggle(
                        "Also delete these remote clones when cloud clone deletion is supported",
                        isOn: $requestRemoteDeletion
                    )
                    .font(.caption)
                    .accessibilityIdentifier("voiceProfileDeleteRemoteToggle")
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("voiceProfileDeleteCancelButton")
                Spacer()
                Button("Delete Profile", role: .destructive) {
                    onConfirmDelete()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("voiceProfileDeleteConfirmButton")
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
