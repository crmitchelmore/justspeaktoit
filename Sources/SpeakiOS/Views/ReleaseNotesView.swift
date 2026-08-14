#if os(iOS)
import SpeakCore
import SwiftUI

/// In-app release notes for iOS.
///
/// The installed version's notes are shown first so the current changes are
/// visible immediately; earlier bundled versions are browsable from the same
/// screen.
public struct ReleaseNotesView: View {
    @State private var browser = ReleaseNotesView.makeBrowser()

    public init() {}

    public static func makeBrowser(bundle: Bundle = .main) -> ReleaseNotesBrowser {
        ReleaseNotesBrowser(installedVersion: ReleaseNotesCatalog.installedVersion(bundle: bundle))
    }

    public var body: some View {
        List {
            if let entry = browser.selectedEntry {
                Section {
                    ReleaseNotesContentView(entry: entry, showsVersionHeader: false)
                        .padding(.vertical, 4)
                } header: {
                    Text(browser.title(for: entry))
                } footer: {
                    if let notice = browser.installedVersionNotice {
                        Text(notice)
                    }
                }

                if !browser.otherEntries.isEmpty {
                    Section("Earlier Versions") {
                        ForEach(browser.otherEntries) { earlier in
                            NavigationLink {
                                ReleaseNoteDetailView(entry: earlier)
                            } label: {
                                versionRow(earlier)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Release Notes",
                    systemImage: "sparkles",
                    description: Text("Release notes are added to each published build.")
                )
            }
        }
        .navigationTitle("Release Notes")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func versionRow(_ entry: ReleaseNoteEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Version \(entry.version)")
            if let published = entry.publishedDate {
                Text(published.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(browser.title(for: entry))
    }
}

/// Full notes for a version reached from the release-notes list.
public struct ReleaseNoteDetailView: View {
    private let entry: ReleaseNoteEntry

    public init(entry: ReleaseNoteEntry) {
        self.entry = entry
    }

    public var body: some View {
        ScrollView {
            ReleaseNotesContentView(entry: entry, showsVersionHeader: false)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .navigationTitle("Version \(entry.version)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
