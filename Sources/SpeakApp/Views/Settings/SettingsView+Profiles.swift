import SpeakCore
import AppKit
import SwiftUI

extension SettingsView {
  var profilesSettings: some View {
    ProfilesSettingsContent(store: environment.profiles, settings: settings)
  }
}

// MARK: - Profiles list

struct ProfilesSettingsContent: View {
  @ObservedObject var store: DictationProfileStore
  @ObservedObject var settings: AppSettings
  @State private var editingProfile: DictationProfile?
  @State private var isCreatingProfile = false

  var body: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      SettingsCard(
        title: "Per-App Profiles",
        systemImage: "person.crop.rectangle.stack",
        tint: Color.brandAccent
      ) {
        VStack(alignment: .leading, spacing: 12) {
          Text(
            """
            Bind transcription, polish and language settings to specific apps. When you start \
            dictating, Speak matches the frontmost app and applies that profile for the session. \
            Apps without a profile keep your default settings.
            """
          )
          .font(.callout)
          .foregroundStyle(.secondary)

          if store.profiles.isEmpty {
            Text("No profiles yet. Dictation always uses your default settings.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.vertical, 8)
          } else {
            VStack(spacing: 8) {
              ForEach(store.profiles) { profile in
                profileRow(profile)
              }
            }
          }

          Button {
            isCreatingProfile = true
          } label: {
            Label("Add Profile", systemImage: "plus")
          }
          .buttonStyle(.bordered)
          .speakTooltip("Create a profile that activates automatically for chosen apps.")
        }
      }
      .speakTooltip("Configure per-app dictation profiles (Power Mode).")
    }
    .sheet(item: $editingProfile) { profile in
      ProfileEditorView(profile: profile, settings: settings) { updated in
        store.upsert(updated)
      }
    }
    .sheet(isPresented: $isCreatingProfile) {
      ProfileEditorView(profile: nil, settings: settings) { created in
        store.upsert(created)
      }
    }
  }

  private func profileRow(_ profile: DictationProfile) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(profile.name)
          .font(.body.weight(.semibold))
        Text(matcherSummary(for: profile))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button("Edit") {
        editingProfile = profile
      }
      .buttonStyle(.bordered)
      Button {
        store.remove(id: profile.id)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("Delete profile \(profile.name)")
    }
    .settingsControlChrome()
  }

  private func matcherSummary(for profile: DictationProfile) -> String {
    let bundleIDs = profile.matchers
      .filter { $0.kind == .bundleID }
      .map(\.value)
    guard !bundleIDs.isEmpty else { return "No apps assigned — never auto-activates" }
    return bundleIDs.joined(separator: ", ")
  }
}

// MARK: - App matcher section (shared with the profile editor)

struct ProfileAppsSection: View {
  @Binding var bundleIDs: [String]
  @State private var manualBundleID = ""

  private struct RunningApp: Identifiable {
    let name: String
    let bundleID: String
    var id: String { bundleID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Apps")
        .font(.subheadline.weight(.semibold))
      Text("The profile activates when dictation starts while one of these apps is frontmost.")
        .font(.caption)
        .foregroundStyle(.secondary)

      if bundleIDs.isEmpty {
        Text("No apps assigned yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(bundleIDs, id: \.self) { bundleID in
          HStack {
            Text(bundleID)
              .font(.callout.monospaced())
            Spacer()
            Button {
              bundleIDs.removeAll { $0 == bundleID }
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(bundleID)")
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(Color(nsColor: .controlBackgroundColor))
          )
        }
      }

      HStack(spacing: 8) {
        Menu("Add Running App") {
          ForEach(runningApps) { app in
            Button("\(app.name) — \(app.bundleID)") {
              append(app.bundleID)
            }
          }
        }
        .frame(maxWidth: 220)

        TextField("Bundle ID (e.g. com.apple.mail)", text: $manualBundleID)
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .onSubmit(addManualBundleID)
        Button("Add", action: addManualBundleID)
          .disabled(manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private var runningApps: [RunningApp] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app -> RunningApp? in
        guard let bundleID = app.bundleIdentifier else { return nil }
        return RunningApp(name: app.localizedName ?? bundleID, bundleID: bundleID)
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func addManualBundleID() {
    append(manualBundleID)
    manualBundleID = ""
  }

  private func append(_ bundleID: String) {
    let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !bundleIDs.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
    bundleIDs.append(trimmed)
  }
}
