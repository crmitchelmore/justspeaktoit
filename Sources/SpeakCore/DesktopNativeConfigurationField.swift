import Foundation

/// Noncredential source identities only; these are not archive keys or executable capabilities.
public enum DesktopNativeConfigurationField: String, CaseIterable, Sendable {
    case customPrompt = "postProcessing.customPrompt"
    case legacyCustomPrompt = "configuration.postProcessingSystemPrompt"
    case microphoneDeviceID
    case localUseGPU
    case azureSpeechResourceEndpoint
    case voiceModelID = "voiceOutput.modelID"
    case voiceID = "voiceOutput.voiceID"
    case voiceTrackUsage = "voiceOutput.ttsTrackUsage"
    case hotKey
    case textOutput

    public var sourceRoot: String { String(rawValue.split(separator: ".")[0]) }

    public var provenance: DesktopNativeConfigurationCapture.Provenance {
        self == .legacyCustomPrompt ? .legacyConfiguration : .nativeSettings
    }

    public func value(in root: AnyCodable) -> AnyCodable? {
        var value = root.storage
        for component in rawValue.split(separator: ".").dropFirst() {
            guard case .object(let object) = value, let child = object[String(component)] else { return nil }
            value = child
        }
        return AnyCodable(value)
    }

    public func validate(_ value: AnyCodable, platform: DesktopNativeConfigurationCapture.Platform) throws {
        if case .null = value.storage { return }
        switch self {
        case .localUseGPU, .voiceTrackUsage:
            guard case .bool = value.storage else { throw invalidValue() }
        case .azureSpeechResourceEndpoint:
            try validateEndpoint(value)
        case .hotKey, .textOutput:
            try validateObject(value, platform: platform)
        default:
            guard case .string = value.storage else { throw invalidValue() }
        }
    }

    private func validateEndpoint(_ value: AnyCodable) throws {
        guard case .string(let endpoint) = value.storage else { throw invalidValue() }
        if !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try AzureSpeechConfiguration.batchResourceURL(endpoint)
        }
    }

    private func validateObject(_ value: AnyCodable, platform: DesktopNativeConfigurationCapture.Platform) throws {
        guard case .object(let object) = value.storage,
              let members = Self.members(for: sourceRoot, platform: platform),
              Set(object.keys) == Set(members.keys) else { throw invalidValue() }
        for (key, scalar) in object {
            guard let kind = members[key], kind.matches(scalar) else { throw invalidValue() }
        }
    }

    public static func unclassifiedPaths(
        in roots: [String: AnyCodable], platform: DesktopNativeConfigurationCapture.Platform
    ) -> [String] {
        roots.keys.sorted().flatMap { root -> [String] in
            guard let members = members(for: root, platform: platform),
                  case .object(let object) = roots[root]?.storage else { return [] }
            return object.keys.sorted().filter { members[$0] == nil }.map { "\(root).\($0)" }
        }
    }

    private enum Scalar {
        case text, boolean, number, unsigned32

        func matches(_ value: AnyCodable.JSONValue) -> Bool {
            switch (self, value) {
            case (.text, .string), (.boolean, .bool), (.number, .int): return true
            case (.number, .double(let number)): return number.isFinite
            case (.unsigned32, .int(let number)): return UInt32(exactly: number) != nil
            case (.unsigned32, .double(let number)): return UInt32(exactly: number) != nil
            default: return false
            }
        }
    }

    private static func members(
        for root: String, platform: DesktopNativeConfigurationCapture.Platform
    ) -> [String: Scalar]? {
        switch root {
        case customPrompt.sourceRoot:
            return ["mode": .text, "modelIdentifier": .text, "customPrompt": .text,
                    "outputLanguage": .text, "temperature": .number]
        case voiceID.sourceRoot:
            return ["modelID": .text, "voiceID": .text, "ttsTrackUsage": .boolean,
                    ApplicationPreferenceKey.ttsAutoPlay.rawValue: .boolean,
                    ApplicationPreferenceKey.ttsSaveToDirectory.rawValue: .boolean,
                    ApplicationPreferenceKey.ttsSpeed.rawValue: .number,
                    ApplicationPreferenceKey.ttsPitch.rawValue: .number,
                    ApplicationPreferenceKey.ttsUseSSML.rawValue: .boolean]
        case hotKey.sourceRoot:
            return platform == .windows
                ? ["modifiers": .unsigned32, "virtualKey": .unsigned32, "style": .text] : ["style": .text]
        case textOutput.sourceRoot:
            var members: [String: Scalar] = ["method": .text, "restoreClipboard": .boolean]
            if platform == .windows { members["insertion"] = .text }
            return members
        default:
            return nil
        }
    }

    private func invalidValue() -> DataMigrationError {
        .invalid("Invalid or unclassified native configuration value at \(rawValue).")
    }
}
