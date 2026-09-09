import AppKit
import Foundation
import SpeakCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MigrationController: ObservableObject {
    @Published var exportCategories = MigrationCategory.defaults
    @Published var historyScope = MigrationScope()
    @Published var recordingScope = MigrationScope()
    @Published var incoming: MigrationSnapshot?
    @Published var current: MigrationSnapshot?
    @Published var modes: [MigrationCategory: MigrationMode] = [:]
    @Published var conflictChoices: [String: Bool] = [:]
    @Published var busy = false
    @Published var status = ""
    @Published var report: [String] = []
    @Published var hasRecovery = false
    @Published var importedModels = false
    @Published var recordingItems: [HistoryItem] = []
    @Published var modelReferences: [MigrationModelReference] = []
    @Published var showingModelDownloads = false
    @Published var isRecoveryPreview = false
    let environment: AppEnvironment
    let store: MigrationStore
    let recovery: MigrationRecovery

    init(environment: AppEnvironment, secrets: SecureStorage) {
        self.environment = environment
        store = MigrationStore(defaults: environment.settings.migrationDefaults,
                               support: environment.history.migrationSupportDirectory,
                               history: environment.history,
                               secrets: secrets)
        recovery = MigrationRecovery(root: store.support)
        hasRecovery = recovery.exists
        recordingItems = (try? store.recordingItems()) ?? environment.history.allItems
    }
    var conflicts: [MigrationConflict] {
        guard let current, let incoming else {
            return []
        }
        return MigrationPlanner.conflicts(current: current, incoming: incoming, modes: modes)
    }
    var unresolvedPaths: [MigrationRecord] {
        guard modes[.settings] != .skip else {
            return []
        }
        return incoming?.records[.settings]?.filter { record in
            guard record.id == "recordingsDirectory",
                  let path = record.value.value as? String else {
                return false
            }
            var directory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: path, isDirectory: &directory) || !directory
                .boolValue
        } ?? []
    }
    var unresolvedDevice: Bool {
        guard modes[.settings] != .skip,
              let record = incoming?.records[.settings]?.first(where: { $0.id == "preferredAudioInputUID" }),
              let uid = record.value.value as? String, !uid.isEmpty else {
            return false
        }
        return !environment.audioDevices.devices.contains { $0.id == uid }
    }
    var canImport: Bool {
        incoming != nil && !busy && modes.values.contains { $0 != .skip }
            && conflicts.allSatisfy { conflictChoices[$0.id] != nil }
            && unresolvedPaths.isEmpty && !unresolvedDevice && unresolvedModelDestinations.isEmpty
    }

    func export() async {
        guard !busy, !exportCategories.isEmpty else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "JustSpeakToIt-\(Date().formatted(.iso8601.year().month().day())).zip"
        guard await panel.begin() == .OK, let url = panel.url else {
            return
        }
        await perform("Exporting selected data…") {
            let snapshot = try await self.store.snapshot(categories: self.exportCategories,
                                                         scopes: [
                                                             "history": self.historyScope,
                                                             "recordings": self.recordingScope
                                                         ])
            try await Task.detached { try MigrationArchive.write(snapshot, to: url) }.value
            self.report = snapshot.notices
            self.status = "Export saved: \(url.lastPathComponent)"
        }
    }
    func openImport() async {
        guard !busy else {
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else {
            return
        }
        await perform("Reading export…") {
            self.discardPreview()
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let snapshot = try await Task.detached { try MigrationArchive.read(url) }.value
            try await self.prepare(snapshot, recovery: false)
        }
    }
    func previewRecovery() async {
        await perform("Reading recovery backup…") {
            self.discardPreview()
            let recovery = self.recovery
            let snapshot = try await Task.detached { try recovery.load() }.value
            try await self.prepare(snapshot, recovery: true)
        }
    }
    private func prepare(_ snapshot: MigrationSnapshot, recovery: Bool) async throws {
        incoming = store.validate(snapshot)
        var categories = Set(snapshot.manifest.categories)
        if !categories.isDisjoint(with: [.history, .recordings]) {
            categories.formUnion([.history, .recordings])
        }
        current = try await store.snapshot(categories: categories)
        modes = Dictionary(uniqueKeysWithValues: snapshot.manifest.categories.map { (
            $0,
            recovery ? .replace : .merge
        ) })
        conflictChoices = [:]
        isRecoveryPreview = recovery
        report = incoming?.notices ?? []
        status = "Review categories and conflicts before importing."
    }
    func importData() async {
        guard canImport else {
            return
        }
        await perform("Saving recovery and importing…") {
            guard !self.environment.main.isBusy, !self.environment.main.captureStarting,
                  !self.environment.main.migrationInProgress,
                  let incoming = self.incoming else {
                throw MigrationError.invalid("Finish the active recording before importing.")
            }
            guard self.environment.main.captureOwnership.reserve(.migration) else {
                throw MigrationError.invalid("Finish voice edit or recording before importing.")
            }
            defer { self.environment.main.captureOwnership.release(.migration) }
            self.environment.main.migrationInProgress = true
            defer { self.environment.main.migrationInProgress = false }
            try await self.environment.history.beginDataMigration()
            defer { self.environment.history.endDataMigration() }
            self.environment.autoCorrectionTracker.stopMonitoring()
            let originalFolder = self.store.recordingFolder
            let categories = Set(self.modes.filter { $0.value != .skip }.map(\.key))
            let latest = try await self.store
                .snapshot(categories: Set(self.current?.manifest.categories ?? []))
            // Recheck after preview: never silently overwrite changes made while it was open.
            if let current = self.current, current.records != latest.records {
                self.current = latest
                self.conflictChoices = [:]
                throw MigrationError
                    .invalid(
                        "Data changed while the preview was open. Review the refreshed conflicts, then retry."
                    )
            }
            let useImported = Set(self.conflictChoices.filter(\.value).map(\.key))
            let plan = MigrationPlanner.plan(
                current: latest,
                incoming: incoming,
                modes: self.modes,
                useImported: useImported
            )
            try await self.saveRecovery(latest, categories: categories)
            try await self.applyWithRollback(plan, previous: latest, categories: categories)
            self.report = plan.notices
            if categories.contains(.recordings) {
                self.report += self.store.removeReplacedRecordings(previous: latest,
                                                                   originalFolder: originalFolder)
            }
            self.status = "Imported \(categories.count) categories. Recovery backup retained."
            self.importedModels = categories.contains(.models)
            self.modelReferences = self.references(in: plan)
            self.recordingItems = (try? self.store.recordingItems()) ?? []
            self.discardPreview(preserveResult: true)
        }
    }
    private func saveRecovery(_ latest: MigrationSnapshot, categories: Set<MigrationCategory>) async throws {
        if !isRecoveryPreview {
            var backup = latest
            backup.manifest.categories = MigrationCategory.allCases.filter(categories.contains)
            backup.records = backup.records.filter { categories.contains($0.key) }
            if !categories.contains(.recordings) {
                backup.files = [:]
            }
            let recovery = recovery
            try await Task.detached { try recovery.save(backup) }.value
            hasRecovery = true
        }
    }

    private func applyWithRollback(_ plan: MigrationSnapshot, previous latest: MigrationSnapshot,
                                   categories: Set<MigrationCategory>) async throws {
        do {
            try await store.apply(plan, categories: categories)
            await refreshRuntime()
        } catch {
            let importError = error
            do {
                try await store.apply(latest, categories: categories)
                await refreshRuntime()
            } catch {
                throw MigrationError
                    .invalid(
                        "Import did not complete. Restore the retained recovery backup. "
                            + "Import: \(importError.localizedDescription) Recovery: \(error.localizedDescription)"
                    )
            }
            throw MigrationError
                .invalid(
                    "Import failed; the previous data was restored. \(importError.localizedDescription)"
                )
        }
    }

    private func refreshRuntime() async {
        environment.settings.reloadAfterMigration()
        environment.profiles.reloadAfterMigration()
        environment.pronunciationManager.reloadAfterMigration()
        environment.shortcuts.reloadAfterMigration()
        await environment.personalLexicon.refresh()
        await environment.autoCorrectionTracker.reloadAfterMigration()
        LocalModelManager.shared.reloadAfterMigration()
        LocalPostProcessingModelManager.shared.reloadAfterMigration()
        environment.tts.reloadAfterMigration()
    }
    private func perform(_ message: String, operation: () async throws -> Void) async {
        guard !busy else {
            return
        }
        busy = true
        status = message
        defer { busy = false }
        do { try await operation() } catch { status = error.localizedDescription }
    }
}

@MainActor
extension MigrationController {
    func resolvePath(useCurrent: Bool) async {
        var path = environment.settings.recordingsDirectory.path
        if !useCurrent {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            guard await panel.begin() == .OK, let url = panel.url else {
                return
            }
            path = url.path
        }
        changeSetting("recordingsDirectory", value: path)
    }
    func resolveDevice(_ uid: String) { changeSetting("preferredAudioInputUID", value: uid) }
    private func changeSetting(_ key: String, value: String) {
        guard let index = incoming?.records[.settings]?.firstIndex(where: { $0.id == key }) else {
            return
        }
        incoming?.records[.settings]?[index].value = AnyCodable(.string(value))
    }
    func deleteRecovery() {
        do {
            try recovery.delete()
            hasRecovery = false
            status = "Recovery backup deleted."
        } catch { status = error.localizedDescription }
    }
    func showModelDownloads() {
        showingModelDownloads = true
    }
    func discardPreview(preserveResult: Bool = false) {
        if let directory = incoming?.directory {
            try? FileManager.default.removeItem(at: directory)
        }
        incoming = nil
        current = nil
        modes = [:]
        conflictChoices = [:]
        isRecoveryPreview = false
        if !preserveResult {
            report = []
            status = ""
            importedModels = false
            modelReferences = []
            showingModelDownloads = false
        }
    }
}
