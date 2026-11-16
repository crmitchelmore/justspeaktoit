import Foundation
import SpeakCore

extension DesktopMigrationRestore {
    static let preferenceCategories: [DataMigrationCategory] = [.settings, .vocabulary, .connections]
    static let preferenceKinds: Set<String> = ["default", "jsonDefault"]

    /// Categories this host can write and roll back. API keys need the explicit
    /// opt-in; settings need the host's configuration source.
    static func appliedCategories(_ configuration: Configuration?) -> Set<DataMigrationCategory> {
        var categories: Set<DataMigrationCategory> = [.history, .profiles, .vocabulary, .recordings]
        if configuration?.preferences != nil { categories.formUnion([.settings, .connections]) }
        if configuration?.credentials?.include == true { categories.insert(.credentials) }
        return categories
    }

    // MARK: Validation

    static func validateConfigurationRecord(_ record: DataMigrationRecord, category: DataMigrationCategory) throws {
        guard !record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.id.utf8.count < 1024 else {
            throw DataMigrationError.invalid("Invalid identifier")
        }
        switch category {
        case .credentials where record.kind == "secret":
            guard case .string = record.value.storage else { throw DataMigrationError.invalid("Invalid API key") }
        case .settings, .connections, .credentials:
            try DataMigrationPreferenceCatalog.validate(record, category: category) { _ in }
        case .vocabulary where preferenceKinds.contains(record.kind):
            try DataMigrationPreferenceCatalog.validate(record, category: category) { _ in }
        case .vocabulary:
            try DataMigrationVocabularyCatalog.validate(record, category: category)
        case .recordings, .models:
            try validateFileRecord(record, category: category)
        case .history, .profiles:
            throw DataMigrationError.invalid("Unknown item type")
        }
    }

    private static func validateFileRecord(_ record: DataMigrationRecord, category: DataMigrationCategory) throws {
        if category == .models {
            guard record.id.hasPrefix("local/"), !record.id.contains("..") else {
                throw DataMigrationError.invalid("Invalid model identifier")
            }
            return
        }
        guard record.kind == "audio", UUID(uuidString: record.id) != nil, let file = record.file,
              DataMigrationArchivePolicy.safeAudioPath(file) else {
            throw DataMigrationError.invalid("Invalid recording")
        }
    }

    // MARK: Baseline

    static func currentVocabulary(_ directory: URL, incoming: DataMigrationSnapshot) throws -> [String: Data?] {
        guard (incoming.records[.vocabulary] ?? []).contains(where: { !preferenceKinds.contains($0.kind) }) else {
            return [:]
        }
        var result: [String: Data?] = [:]
        do {
            for definition in DataMigrationVocabularyCatalog.collections {
                result[definition.desktopPath] = .some(try DesktopVocabularyMigrationSource.read(
                    definition.desktopPath, root: directory.standardizedFileURL,
                    checkCancellation: { try Task.checkCancellation() }
                ))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DataMigrationError.invalid(
                "This device's vocabulary could not be read, so nothing was restored. \(error.localizedDescription)"
            )
        }
        return result
    }

    static func currentCredentials(
        _ incoming: DataMigrationSnapshot, configuration: Configuration?
    ) throws -> [String: String] {
        guard let credentials = configuration?.credentials, credentials.include else { return [:] }
        var result: [String: String] = [:]
        for record in incoming.records[.credentials] ?? [] where record.kind == "secret"
            && credentials.supported.contains(record.id) {
            try Task.checkCancellation()
            do {
                result[record.id] = try credentials.read(record.id)
            } catch {
                throw DataMigrationError.invalid("This device's API keys could not be read, so nothing was restored.")
            }
        }
        return result
    }

    // MARK: Planning

    static func computePreferences(
        _ incoming: DataMigrationSnapshot, baseline: Baseline, choice: Choice,
        configuration: Configuration?, into result: inout Computed
    ) {
        guard let target = configuration?.preferences else {
            if (incoming.records[.vocabulary] ?? []).contains(where: { preferenceKinds.contains($0.kind) }) {
                result.skipped.append(DataMigrationCategory.vocabulary.title
                    + ": vocabulary settings are not restored on this device.")
            }
            return
        }
        var merge = PreferenceMerge(values: baseline.preferences)
        for category in preferenceCategories {
            guard let records = incoming.records[category] else { continue }
            merge.tallies[category] = PreferenceTally()
            for record in records where preferenceKinds.contains(record.kind) {
                merge.merge(record, category: category, choice: choice, target: target)
            }
        }
        recordPreferences(merge, baseline: baseline, target: target, into: &result)
    }

    private static func recordPreferences(
        _ merge: PreferenceMerge, baseline: Baseline, target: ConfigurationPreferences, into result: inout Computed
    ) {
        if merge.unsupported > 0 {
            result.skipped.append(DataMigrationCategory.settings.title
                + ": \(merge.unsupported) setting(s) have no equivalent on this device and were not applied.")
        }
        if merge.invalid > 0 {
            result.skipped.append(DataMigrationCategory.settings.title
                + ": \(merge.invalid) setting(s) have values this device does not accept and were not applied.")
        }
        for (category, count) in merge.tallies {
            let keys = DataMigrationPreferenceCatalog.keys(in: category).intersection(target.supportedKeys)
            let existing = baseline.preferences.keys.filter(keys.contains).count
            let change = Changes(
                existing: existing, added: count.added, updated: count.updated, removed: 0,
                retained: existing + count.added, reordered: false
            )
            // Vocabulary rows also count collection items; computeVocabulary folds these in.
            result.add(category, change, conflicts: count.conflicts)
        }
        if merge.values != baseline.preferences { result.preferences = merge.values }
    }

    static func computeCredentials(
        _ incoming: DataMigrationSnapshot, baseline: Baseline, choice: Choice,
        configuration: Configuration?, into result: inout Computed
    ) {
        guard let records = incoming.records[.credentials],
              let target = configuration?.credentials, target.include else { return }
        var added = 0, updated = 0, conflicts = 0, unsupported = 0, pairing = 0
        for record in records {
            guard record.kind == "secret" else {
                pairing += 1
                continue
            }
            guard target.supported.contains(record.id), case let .string(value) = record.value.storage,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                unsupported += 1
                continue
            }
            let prior = baseline.credentials[record.id] ?? ""
            guard prior != value else { continue }
            if !prior.isEmpty {
                conflicts += 1
                guard choice == .replace else { continue }
                updated += 1
            } else {
                added += 1
            }
            result.credentials.append(.init(identifier: record.id, value: value, prior: prior))
        }
        let title = DataMigrationCategory.credentials.title
        if pairing > 0 {
            result.skipped.append(title + ": Mac pairing details do not apply on this device and were not imported.")
        }
        if unsupported > 0 {
            result.skipped.append(title
                + ": \(unsupported) key(s) are for services this device does not use and were not imported.")
        }
        let existing = baseline.credentials.values.filter { !$0.isEmpty }.count
        result.add(.credentials, Changes(
            existing: existing, added: added, updated: updated, removed: 0,
            retained: existing + added, reordered: false
        ), conflicts: conflicts)
    }

    static func computeVocabulary(
        _ incoming: DataMigrationSnapshot, baseline: Baseline, choice: Choice,
        digests: LocalModelDigestProvider, into result: inout Computed
    ) throws {
        guard let records = incoming.records[.vocabulary]?.filter({ !preferenceKinds.contains($0.kind) }),
              !records.isEmpty else { return }
        var existing = 0, added = 0, updated = 0, conflicts = 0
        for definition in DataMigrationVocabularyCatalog.collections {
            try Task.checkCancellation()
            let prior = baseline.vocabulary[definition.desktopPath].flatMap { $0 }
            var current = try vocabularyRecords(prior, kind: definition.kind, digests: digests)
            existing += current.count
            var changed = false
            for record in records where record.kind == definition.kind {
                if let index = current.firstIndex(where: { $0.identity == record.identity }) {
                    guard current[index].value != record.value else { continue }
                    conflicts += 1
                    guard choice == .replace else { continue }
                    current[index].value = record.value
                    updated += 1
                } else {
                    current.append(record)
                    added += 1
                }
                changed = true
            }
            guard changed else { continue }
            result.vocabulary.append(.init(path: definition.desktopPath, data: try encode(current), prior: prior))
        }
        let preferences = result.changes[.vocabulary]
        result.add(.vocabulary, Changes(
            existing: existing + (preferences?.existing ?? 0), added: added + (preferences?.added ?? 0),
            updated: updated + (preferences?.updated ?? 0), removed: 0,
            retained: existing + added + (preferences?.retained ?? 0), reordered: false
        ), conflicts: conflicts + (result.conflicts[.vocabulary] ?? 0))
    }

    private static func vocabularyRecords(
        _ data: Data?, kind: String, digests: LocalModelDigestProvider
    ) throws -> [DataMigrationRecord] {
        do {
            return try data.map {
                try DataMigrationVocabularyCatalog.records(data: $0, kind: kind, digest: digests.sha256(of:))
            } ?? []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DataMigrationError.invalid(
                "This device's vocabulary could not be read, so nothing was restored. " + error.localizedDescription
            )
        }
    }

    private static func encode(_ records: [DataMigrationRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records.map(\.value))
        guard UInt64(data.count) <= DataMigrationArchivePolicy.maximumJSONBytes else {
            throw DataMigrationError.invalid("Restored vocabulary exceeds the supported size.")
        }
        return data
    }

    /// Attaches backup audio to History items this restore adds. Items already
    /// on this device keep their own audio, so nothing is overwritten.
    static func computeAudio(_ incoming: DataMigrationSnapshot, into result: inout Computed) {
        guard let records = incoming.records[.recordings] else { return }
        let restoring = Dictionary(
            result.history.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        var added = 0, kept = 0, unreadable = 0
        for record in records {
            guard let id = UUID(uuidString: record.id), let path = record.file else { continue }
            guard let index = restoring[id], result.history[index].audio == nil else {
                kept += 1
                continue
            }
            guard !result.history[index].replacing, let source = incoming.files[path] else {
                if result.history[index].replacing { kept += 1 } else { unreadable += 1 }
                continue
            }
            result.history[index].audio = .init(
                source: source, pathExtension: (path as NSString).pathExtension.lowercased()
            )
            added += 1
        }
        let title = DataMigrationCategory.recordings.title
        if kept > 0 {
            result.skipped.append(title
                + ": \(kept) recording(s) belong to History already on this device, which keeps its own audio.")
        }
        if unreadable > 0 {
            result.skipped.append(title + ": \(unreadable) recording(s) could not be read from the backup.")
        }
        result.add(.recordings, Changes(
            existing: 0, added: added, updated: 0, removed: 0, retained: added, reordered: false
        ), conflicts: 0)
    }

    /// Model files are never downloaded or copied during restore; the preview
    /// says which ones this device can download from Local models.
    static func modelNotes(_ incoming: DataMigrationSnapshot, configuration: Configuration?) -> [String] {
        guard let records = incoming.records[.models], !records.isEmpty else { return [] }
        let models = configuration?.models ?? .init()
        var downloadable = Set<String>()
        var installed = Set<String>(), unavailable = Set<String>()
        for record in records {
            if models.installed.contains(record.id) {
                installed.insert(record.id)
            } else if let name = models.available[record.id] {
                downloadable.insert(name)
            } else {
                unavailable.insert(record.id)
            }
        }
        let title = DataMigrationCategory.models.title
        var notes: [String] = []
        if !downloadable.isEmpty {
            notes.append(title + ": download " + downloadable.sorted().joined(separator: ", ")
                + " from Local models. Model files are never copied by a restore.")
        }
        if !installed.isEmpty { notes.append(title + ": \(installed.count) model(s) are already on this device.") }
        if !unavailable.isEmpty {
            notes.append(title + ": \(unavailable.count) model(s) cannot run on this device.")
        }
        return notes
    }
}

extension DesktopMigrationRestore.Computed {
    mutating func add(
        _ category: DataMigrationCategory, _ changes: DesktopMigrationRestore.Changes, conflicts count: Int
    ) {
        self.changes[category] = changes
        conflicts[category] = count
    }
}

extension DesktopMigrationRestore {
    struct PreferenceTally: Sendable {
        var added = 0
        var updated = 0
        var conflicts = 0
    }

    /// Folds imported preferences into this device's set one key at a time,
    /// keeping only values the device accepts as a whole.
    struct PreferenceMerge {
        var values: [String: AnyCodable]
        var tallies: [DataMigrationCategory: PreferenceTally] = [:]
        var unsupported = 0
        var invalid = 0

        mutating func merge(
            _ record: DataMigrationRecord, category: DataMigrationCategory, choice: Choice,
            target: ConfigurationPreferences
        ) {
            guard target.supportedKeys.contains(record.id) else {
                unsupported += 1
                return
            }
            let current = values[record.id]
            guard current != record.value else { return }
            if current != nil {
                tallies[category, default: .init()].conflicts += 1
                guard choice == .replace else { return }
            }
            var candidate = values
            candidate[record.id] = record.value
            guard target.isValid(candidate) else {
                invalid += 1
                return
            }
            values = candidate
            if current == nil {
                tallies[category, default: .init()].added += 1
            } else {
                tallies[category, default: .init()].updated += 1
            }
        }
    }
}
