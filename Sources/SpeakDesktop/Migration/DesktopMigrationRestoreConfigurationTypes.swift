import Foundation
import SpeakCore

extension DesktopMigrationRestore {
    /// This device's settings, API keys and model inventory as the host sees
    /// them. A nil member keeps that part of the backup unapplied.
    public struct Configuration: Sendable {
        let preferences: ConfigurationPreferences?
        let credentials: ConfigurationCredentials?
        let models: ConfigurationModels

        public init(
            preferences: ConfigurationPreferences?, credentials: ConfigurationCredentials?,
            models: ConfigurationModels = .init()
        ) {
            self.preferences = preferences
            self.credentials = credentials
            self.models = models
        }
    }

    /// One API key the confirmed choice writes. `prior` is the value it replaces.
    public struct CredentialWrite: Equatable, Sendable {
        public let identifier: String
        public let value: String
        public let prior: String
    }

    /// What the host writes for a confirmed restore.
    public struct ConfigurationWrite: Sendable {
        /// The complete portable preference set to apply, or nil to leave settings unchanged.
        public let preferences: [String: AnyCodable]?
        public let credentials: [CredentialWrite]

        var isEmpty: Bool { preferences == nil && credentials.isEmpty }
    }

    /// Host access to settings and API keys. `write` must put back anything it
    /// changed before throwing; on success it returns an undo for a later failure.
    public typealias ConfigurationUndo = @Sendable () async throws -> Void

    public struct ConfigurationSource: Sendable {
        let read: @Sendable () async throws -> Configuration
        let write: @Sendable (ConfigurationWrite) async throws -> ConfigurationUndo

        public init(
            read: @escaping @Sendable () async throws -> Configuration,
            write: @escaping @Sendable (ConfigurationWrite) async throws -> ConfigurationUndo
        ) {
            self.read = read
            self.write = write
        }
    }

    struct AudioSource: Equatable, Sendable {
        let source: URL
        let pathExtension: String
    }

    struct VocabularyWrite: Equatable, Sendable {
        let path: String
        let data: Data
        let prior: Data?
    }

    public struct ConfigurationPreferences: Sendable {
        /// This device's portable preferences, keyed like the Mac's.
        let values: [String: AnyCodable]
        /// Keys this device applies; any other imported key is skipped.
        let supportedKeys: Set<String>
        /// True when this device accepts a complete preference set.
        let isValid: @Sendable ([String: AnyCodable]) -> Bool

        public init(
            values: [String: AnyCodable], supportedKeys: Set<String>,
            isValid: @escaping @Sendable ([String: AnyCodable]) -> Bool
        ) {
            self.values = values
            self.supportedKeys = supportedKeys
            self.isValid = isValid
        }
    }

    public struct ConfigurationCredentials: Sendable {
        /// The explicit opt-in. Without it no credential is read or written.
        let include: Bool
        let supported: Set<String>
        /// Reads one stored value; an empty string means none is stored.
        let read: @Sendable (String) throws -> String

        public init(include: Bool, supported: Set<String>, read: @escaping @Sendable (String) throws -> String) {
            self.include = include
            self.supported = supported
            self.read = read
        }
    }

    public struct ConfigurationModels: Sendable {
        /// Models this device can download, by catalogue identifier, with display names.
        public let available: [String: String]
        public let installed: Set<String>

        public init(available: [String: String] = [:], installed: Set<String> = []) {
            self.available = available
            self.installed = installed
        }
    }
}
