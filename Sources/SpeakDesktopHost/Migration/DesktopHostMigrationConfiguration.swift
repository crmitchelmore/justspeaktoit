import Foundation
import SpeakCore
import SpeakDesktop

/// A model reference in the shape the Mac's backup writes, so a Mac can offer
/// the same catalogue download. Model files are never copied.
private struct DesktopHostModelReference: Codable {
    let id: String
    let name: String
    let source: String
    let destination: String
    let family: String
}

/// Settings, vocabulary, connections, model references and (only with the
/// explicit opt-in) API keys for a full backup and its restore.
extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    /// Keys a backup restore never applies: device-local grants stay as they are.
    static var restoreExcludedConfigurationKeys: Set<String> {
        portableConfigurationExclusions.union([ApplicationPreferenceKey.enableAutomationServer.rawValue])
    }

    /// The host's settings and API keys for a restore. Without
    /// `includeCredentials` no stored key is read or written.
    func migrationRestoreSource(includeCredentials: Bool) -> DesktopMigrationRestore.ConfigurationSource {
        .init(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.migrationRestoreConfiguration(includeCredentials: includeCredentials)
            },
            write: { [weak self] write in
                guard let self else { throw CancellationError() }
                return try await self.applyMigrationConfiguration(write)
            }
        )
    }

    private func migrationRestoreConfiguration(
        includeCredentials: Bool
    ) throws -> DesktopMigrationRestore.Configuration {
        guard !closed else { throw CancellationError() }
        let supported = DesktopConfiguration.supportedKeys.union(Platform.voiceConfigurationKeys)
            .union(Platform.shortcutConfigurationKeys).subtracting(Self.restoreExcludedConfigurationKeys)
        let preferences = DesktopMigrationRestore.ConfigurationPreferences(
            values: try portableConfigurationValues(), supportedKeys: supported,
            isValid: { (try? DesktopConfiguration(values: $0)) != nil }
        )
        let effects = effects
        let credentials = DesktopMigrationRestore.ConfigurationCredentials(
            include: includeCredentials, supported: Set(Self.apiKeyCatalogEntries().map(\.identifier)),
            read: { try effects.apiKey(name: $0) }
        )
        return .init(preferences: preferences, credentials: credentials, models: Platform.migrationModels(host: self))
    }

    /// Writes API keys, then settings. Anything written is put back before an
    /// error is rethrown; the returned undo does the same after a later failure.
    private func applyMigrationConfiguration(
        _ write: DesktopMigrationRestore.ConfigurationWrite
    ) async throws -> DesktopMigrationRestore.ConfigurationUndo {
        guard !closed else { throw CancellationError() }
        guard recording == nil else { throw DesktopHostError(message: "Finish dictation before restoring settings.") }
        let previous = settings
        var written: [DesktopMigrationRestore.CredentialWrite] = []
        do {
            for credential in write.credentials {
                try await writeProviderAPIKey(
                    APIKeyCatalog.sanitizedKey(credential.value), identifier: credential.identifier
                )
                written.append(credential)
                await apiKeyChanged(credential.identifier)
            }
            if let values = write.preferences {
                let document = DesktopConfigurationDocument(preferences: try DesktopConfiguration(values: values))
                _ = try await applyConfigurationDocument(document)
            }
        } catch {
            await undoMigrationConfiguration(previous: previous, settingsChanged: write.preferences != nil,
                                             credentials: written)
            throw error
        }
        let settingsChanged = write.preferences != nil
        let credentials = written
        return { [weak self] in
            guard let self else { return }
            await self.undoMigrationConfiguration(
                previous: previous, settingsChanged: settingsChanged, credentials: credentials
            )
        }
    }

    private func undoMigrationConfiguration(
        previous: Settings, settingsChanged: Bool, credentials: [DesktopMigrationRestore.CredentialWrite]
    ) async {
        if settingsChanged { try? await restoreSettings(previous) }
        for credential in credentials.reversed() {
            try? await writeProviderAPIKey(credential.prior, identifier: credential.identifier)
            await apiKeyChanged(credential.identifier)
        }
    }

    /// The host-owned part of a full backup, or nil when the selection only
    /// covers History and app profiles.
    func migrationBackupConfiguration(
        _ selection: DesktopMigrationBackup.Selection
    ) throws -> DesktopMigrationBackup.Configuration? {
        guard selection.includeConfiguration || selection.includeCredentials else { return nil }
        var records: [DataMigrationCategory: [DataMigrationRecord]] = [:]
        var notices: [String] = []
        if selection.includeConfiguration {
            let projection = try preferenceArchiveProjection(categories: [.settings, .vocabulary, .connections])
            records = projection.records.filter { !$0.value.isEmpty }
            for notice in projection.notices where notice.reason == .requiresJSONValidator {
                let key = notice.path.replacingOccurrences(of: "configuration.", with: "")
                notices.append("Settings, \(key): not included because its value could not be checked.")
            }
            let models = try migrationModelReferences()
            if !models.isEmpty { records[.models] = models }
        }
        let credentials: (@Sendable () throws -> [DataMigrationRecord])?
        if selection.includeCredentials {
            let effects = effects
            let identifiers = Self.apiKeyCatalogEntries().map(\.identifier)
            credentials = {
                try identifiers.compactMap { identifier in
                    let value = try effects.apiKey(name: identifier)
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return DataMigrationRecord(id: identifier, kind: "secret", value: AnyCodable(.string(value)))
                }
            }
        } else {
            credentials = nil
        }
        return .init(
            records: records, notices: notices,
            vocabularyDirectory: selection.includeConfiguration ? directory : nil, credentials: credentials
        )
    }

    private func migrationModelReferences() throws -> [DataMigrationRecord] {
        let models = Platform.migrationModels(host: self)
        let destination = directory.appendingPathComponent("LocalModels").path
        return try models.installed.sorted().compactMap { id in
            guard id.hasPrefix("local/"), !id.contains("..") else { return nil }
            let reference = DesktopHostModelReference(
                id: id, name: models.available[id] ?? id, source: WhisperCppModels.repository,
                destination: destination, family: "whisper"
            )
            return DataMigrationRecord(id: id, kind: "modelReference", value: try DataMigrationCoding.value(reference))
        }
    }

    /// Puts back settings saved before a restore changed them.
    func restoreSettings(_ previous: Settings) async throws {
        invalidateConnectionPreWarming(resetCapture: true)
        let changed = settings
        let changedVoice = settings.voiceOutput
        try await persistAutomationAwareSettings(previous)
        connectionWarm.approved = false
        await configureCleanupDiscovery(refresh: false)
        reconcileSonioxRegionChange(changedVoice)
        reconcileVoiceQualityChange(changedVoice)
        let configuration = try self.configuration()
        try await configureRecordingFeedback(configuration)
        Platform.applyShell(configuration.shellPreferences)
        try publishImportedLocalChoices(from: changed)
    }
}

extension DesktopHostController {
    /// Keys a portable configuration never carries: device-local automation grants and editor projections.
    static var portableConfigurationExclusions: Set<String> {
        Set(["automationLocalConsent", "automationEnabled"]).union(DesktopConfiguration.editorProjectionKeys)
    }

    /// The preferences a configuration file or backup restore exchanges.
    func portableConfigurationValues() throws -> [String: AnyCodable] {
        let voice = try Platform.exportVoiceConfiguration(settings.voiceOutput, over: configuration())
        let projected = try DesktopPostProcessingConfiguration.exportOptions(settings.postProcessing, over: voice)
        return projected.values.filter { !Self.portableConfigurationExclusions.contains($0.key) }
    }
}
