import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func configuration() throws -> DesktopConfiguration {
        if let configuration = settings.configuration { return configuration }
        var values: [String: AnyCodable] = [:]
        if let polish = settings.postProcessing {
            values["postProcessingTemperature"] = AnyCodable(.double(polish.temperature))
            values["postProcessingOutputLanguage"] = AnyCodable(.string(polish.outputLanguage ?? ""))
        }
        return try DesktopConfiguration(values: values)
    }

    package func saveConfiguration(_ entries: [String]) throws {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before changing configuration.")
        }
        let configuration = try configuration().applying(entries)
        var changed = settings
        changed.configuration = configuration
        var polish = changed.postProcessing ?? .init()
        polish.temperature = configuration.number("postProcessingTemperature")
        polish.outputLanguage = configuration.text("postProcessingOutputLanguage")
        changed.postProcessing = polish
        try effects.writeSettings(JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json"))
        settings = changed
        Platform.hud(.hidden)
        update("Configuration saved. New recordings use these preferences.")
    }

    /// Export only portable preferences, never keys, device paths, native hotkeys
    /// or service-enabling switches. Unsupported imported values are retained.
    package func exportConfiguration(path: String) throws {
        guard !closed else { throw DesktopHostError(message: "The app is closing.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let document = DesktopConfigurationDocument(preferences: try configuration())
        let data = try encoder.encode(document)
        guard data.count <= DesktopConfigurationDocument.maximumBytes else { throw DesktopConfigurationError.tooLarge }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        update("Portable preferences exported, including preserved imported values. Credential stores were not read.")
    }

    package func importConfiguration(path: String) throws {
        guard !closed, !busy, recording == nil else {
            throw DesktopHostError(message: "Finish dictation before importing configuration.")
        }
        let source = URL(fileURLWithPath: path)
        let maximumBytes = DesktopConfigurationDocument.maximumBytes
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw DesktopConfigurationError.tooLarge
        }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var data = Data()
        while data.count <= maximumBytes {
            guard let chunk = try file.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw DesktopConfigurationError.tooLarge }
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: data)
        guard document.version == 1 else { throw DesktopConfigurationError.unsupportedVersion }
        var changed = settings
        changed.configuration = document.preferences
        var polish = changed.postProcessing ?? .init()
        polish.temperature = document.preferences.number("postProcessingTemperature")
        polish.outputLanguage = document.preferences.text("postProcessingOutputLanguage")
        changed.postProcessing = polish
        try effects.writeSettings(JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json"))
        settings = changed
        Platform.hud(.hidden)
        let unknown = document.preferences.values.keys.filter { key in
            !DesktopConfiguration.fields.contains { $0.key == key }
        }.sorted()
        update("Configuration imported. Provider/model choices and service permissions are unchanged."
            + (unknown.isEmpty ? "" : " Preserved but not applied: \(unknown.joined(separator: ", "))."))
    }
}

package struct DesktopConfigurationDocument: Codable {
    package static let maximumBytes = 1_048_576
    package var version = 1
    package let preferences: DesktopConfiguration
}
