import SpeakCore
import SwiftUI

/// In-app release notes for macOS.
///
/// Opens on the installed version so its changes are visible immediately, with
/// the bundled history of earlier versions browsable alongside.
struct ReleaseNotesView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var browser = ReleaseNotesView.makeBrowser()

  static func makeBrowser(bundle: Bundle = .main) -> ReleaseNotesBrowser {
    ReleaseNotesBrowser(installedVersion: ReleaseNotesCatalog.installedVersion(bundle: bundle))
  }

  var body: some View {
    NavigationSplitView {
      versionList
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    } detail: {
      detail
    }
    .frame(minWidth: 720, minHeight: 480)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") { dismiss() }
      }
    }
  }

  private var versionList: some View {
    List(selection: selectionBinding) {
      ForEach(browser.entries) { entry in
        VStack(alignment: .leading, spacing: 2) {
          Text("Version \(entry.version)")
            .font(.body)
          if let published = entry.publishedDate {
            Text(published.formatted(date: .abbreviated, time: .omitted))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .tag(entry.version)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(browser.title(for: entry))
      }
    }
    .navigationTitle("Release Notes")
  }

  @ViewBuilder
  private var detail: some View {
    if let entry = browser.selectedEntry {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let notice = browser.installedVersionNotice {
            noticeLabel(notice)
          }
          ReleaseNotesContentView(entry: entry)
        }
        .padding(20)
      }
      .navigationTitle(browser.title(for: entry))
    } else {
      ContentUnavailableView(
        "No Release Notes",
        systemImage: "sparkles",
        description: Text("Release notes are added to each published build.")
      )
    }
  }

  private func noticeLabel(_ text: String) -> some View {
    Label(text, systemImage: "info.circle")
      .font(.callout)
      .foregroundStyle(.secondary)
  }

  private var selectionBinding: Binding<String?> {
    Binding(
      get: { browser.selectedVersion },
      set: { newValue in
        guard let newValue else { return }
        browser.select(version: newValue)
      }
    )
  }
}
