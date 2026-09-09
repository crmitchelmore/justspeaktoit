import SpeakCore
import SwiftUI

struct DataMigrationView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var controller: MigrationController?
    var body: some View {
        Group {
            if let controller {
                MigrationContentView(controller: controller)
            } else {
                ProgressView("Loading migration controls…")
            }
        }
        .task {
            if controller == nil {
                await environment.history.waitUntilLoaded()
                controller = MigrationController(environment: environment,
                                                 secrets: await environment.secureStorage.coreStorage())
            }
        }
    }
}

private struct MigrationContentView: View {
    @ObservedObject var controller: MigrationController
    @State private var warnCredentials = false
    @State private var confirmImport = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Data & Migration").font(.title2.bold())
            Text("Move selected data between Macs, or keep a manual backup.").foregroundStyle(.secondary)
            GroupBox("Export") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Select all") { controller.exportCategories = Set(MigrationCategory.allCases) }
                        Button("Select none") { controller.exportCategories = [] }
                    }
                    ForEach(MigrationCategory.allCases) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { controller.exportCategories.contains(category) },
                            set: {
                                if $0 {
                                    controller.exportCategories.insert(category)
                                } else {
                                    controller.exportCategories.remove(category)
                                } }
                        ))
                    }
                    Text("Models include names and download sources, never model files or runtimes.")
                        .font(.caption).foregroundStyle(.secondary)
                    if controller.exportCategories.contains(.history) {
                        MigrationScopeView(title: "History text", scope: $controller.historyScope,
                                           items: controller.environment.history.allItems)
                    }
                    if controller.exportCategories.contains(.recordings) {
                        MigrationScopeView(title: "Recordings", scope: $controller.recordingScope,
                                           items: controller.recordingItems)
                    }
                    Button("Export ZIP…") {
                        if controller.exportCategories.contains(.credentials) {
                            warnCredentials = true
                        } else {
                            Task { await controller.export() }
                        }
                    }
                    .disabled(controller.exportCategories.isEmpty)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("Import") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Choose export ZIP…") { Task { await controller.openImport() } }
                    if let incoming = controller.incoming {
                        MigrationImportPreview(controller: controller, incoming: incoming)
                        HStack {
                            Button(controller
                                .isRecoveryPreview ? "Restore selected data…" : "Import selected data…") {
                                    confirmImport = true
                                }.disabled(!controller.canImport)
                            Button("Cancel") { controller.discardPreview() }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GroupBox("Recovery backup") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        """
                        Before importing, affected data is backed up locally. Credentials are protected by this \
                        Mac’s Keychain. The latest backup stays until you delete it.
                        """
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if controller.hasRecovery {
                        HStack {
                            Button("Review recovery…") { Task { await controller.previewRecovery() } }
                            Button("Delete backup…", role: .destructive) { confirmDelete = true }
                        }
                    } else {
                        Text("No recovery backup yet.").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if controller.busy {
                ProgressView()
            }
            if !controller.status.isEmpty {
                Text(controller.status).textSelection(.enabled)
            }
            if !controller.report.isEmpty {
                DisclosureGroup("Import/export report (\(controller.report.count))") {
                    ForEach(Array(controller.report.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption).textSelection(.enabled)
                    }
                }
            }
            if controller.importedModels {
                Text(
                    """
                    Model references restored. Download missing models before selecting them for transcription \
                    or post-processing.
                    """
                )
                Button("Review model downloads") { controller.showModelDownloads() }
            }
            Text(
                """
                Device identity, sync state, diagnostic logs, caches and executable runtimes are not \
                migrated. Speech insights are rebuilt from history.
                """
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $controller.showingModelDownloads) {
            MigrationModelDownloadsView(controller: controller) }
        .disabled(controller.busy)
        .confirmationDialog(
            "This export contains API keys and credentials",
            isPresented: $warnCredentials,
            titleVisibility: .visible
        ) {
            Button("Export with credentials") { Task { await controller.export() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Anyone with this unencrypted ZIP can read and use these credentials. Store and share it carefully."
            )
        }
        .confirmationDialog(
            "Apply the selected import?",
            isPresented: $confirmImport,
            titleVisibility: .visible
        ) {
            Button("Apply import") { Task { await controller.importData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                Merge preserves unrelated data. Replace changes only the selected category and exported \
                history/date range. Invalid items are skipped and reported. A recovery backup is saved \
                before changes.
                """
            )
        }
        .confirmationDialog(
            "Delete the recovery backup?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete backup", role: .destructive) { controller.deleteRecovery() }
        }
    }
}

private struct MigrationImportPreview: View {
    @ObservedObject var controller: MigrationController
    let incoming: MigrationSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exported \(incoming.manifest.createdAt.formatted())").font(.caption)
            ForEach(incoming.manifest.categories) { category in
                Picker("\(category.title) (\(incoming.records[category]?.count ?? 0))",
                       selection: Binding(get: { controller.modes[category] ?? .skip },
                                          set: { controller.modes[category] = $0 })) {
                    ForEach(MigrationMode.allCases) { mode in Text(mode.rawValue.capitalized).tag(mode) }
                }
                if let scope = incoming.manifest.scopes[category.rawValue], !scope.isComplete {
                    Text("Filtered export: replacement preserves items outside this selection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(controller.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 4) {
                    Text(conflict.title).font(.headline)
                    Text("Existing: \(conflict.summary(conflict.existing))").font(.caption)
                    Text("Imported: \(conflict.summary(conflict.imported))").font(.caption)
                    Picker("Use", selection: Binding<Int>(
                        get: { controller.conflictChoices[conflict.id].map { $0 ? 1 : 0 } ?? -1 },
                        set: { controller.conflictChoices[conflict.id] = $0 == 1 }
                    )) {
                        Text("Choose…").tag(-1)
                        Text("Existing").tag(0)
                        Text("Imported").tag(1)
                    }.pickerStyle(.segmented)
                }
            }
            if !controller.unresolvedPaths.isEmpty {
                Text("The exported recording folder is unavailable on this Mac.")
                HStack {
                    Button("Use current folder") { Task { await controller.resolvePath(useCurrent: true) } }
                    Button("Choose folder…") { Task { await controller.resolvePath(useCurrent: false) } }
                }
            }
            if !controller.unresolvedModelDestinations.isEmpty {
                Text("The exported model destination is unavailable on this Mac.")
                Button("Use this Mac’s managed model folder") { controller.resolveModelDestinations() }
            }
            if controller.unresolvedDevice {
                Text("The exported microphone is unavailable. Choose a replacement:")
                Button("Use system default") { controller.resolveDevice("") }
                ForEach(controller.environment.audioDevices.devices) { device in
                    Button(device.name) { controller.resolveDevice(device.id) }
                }
            }
        }
    }
}

private struct MigrationScopeView: View {
    let title: String
    @Binding var scope: MigrationScope
    let items: [HistoryItem]
    @State private var selection = "all"
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var through = Date()
    var body: some View {
        DisclosureGroup(
            "\(title): \(selection == "all" ? "All entries" : selection == "dates" ? "Date range" : "Selected entries")"
        ) {
            Picker("Include", selection: $selection) {
                Text("All").tag("all")
                Text("Date range").tag("dates")
                Text("Selected entries").tag("selected")
            }.pickerStyle(.segmented)
            if selection == "dates" {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("Through", selection: $through, in: from..., displayedComponents: .date)
            }
            if selection == "selected" {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(items) { item in
                            Toggle(isOn: Binding(
                                get: { scope.selectedIDs?.contains(item.id.uuidString) == true },
                                set: { selected in
                                    var ids = scope.selectedIDs ?? []
                                    if selected {
                                        ids.insert(item.id.uuidString)
                                    } else {
                                        ids.remove(item.id.uuidString)
                                    }
                                    scope.selectedIDs = ids
                                }
                            )) {
                                Text(
                                    item.createdAt.formatted() + " — "
                                        +
                                        String((item.postProcessedTranscription ?? item
                                                .rawTranscription ?? "Recording").prefix(80))
                                )
                                .lineLimit(2)
                            }
                        }
                    }
                }.frame(height: 180)
            }
        }
        .onChange(of: selection) { _, _ in updateScope() }
        .onChange(of: from) { _, _ in updateScope() }
        .onChange(of: through) { _, _ in updateScope() }
    }
    private func updateScope() {
        switch selection {
        case "dates":
            scope = MigrationScope(start: Calendar.current.startOfDay(for: from),
                                   end: Calendar.current.date(
                                       byAdding: .day,
                                       value: 1,
                                       to: Calendar.current.startOfDay(for: max(from, through))
                                   ))
        case "selected": scope = MigrationScope(selectedIDs: scope.selectedIDs ?? [])
        default: scope = MigrationScope()
        }
    }
}
