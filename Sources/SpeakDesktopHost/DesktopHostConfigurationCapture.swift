import SpeakCore

package struct DesktopHostConfigurationCapture: Sendable {
    package let canonical: DataMigrationPreferenceProjection
    package let native: DesktopNativeConfigurationCapture?
    package let unresolvedPaths: [String]

    package static func capture<Platform: DesktopHostPlatform>(
        _ settings: DesktopHostController<Platform>.Settings, categories: Set<DataMigrationCategory>,
        selectedNativeFields: Set<String> = [], validateJSON: ((DataMigrationRecord) throws -> Void)? = nil
    ) throws -> Self {
        guard let platform = Platform.nativeConfigurationPlatform else {
            guard selectedNativeFields.isEmpty else {
                throw DataMigrationError.invalid("This host cannot classify native configuration capture sources.")
            }
            return Self(canonical: try DesktopHostPreferenceArchive.project(
                settings, categories: categories, validateJSON: validateJSON
            ), native: nil, unresolvedPaths: [])
        }
        let roots = try settings.nativeConfigurationSources()
        var sources: [String: AnyCodable] = [:]
        for field in DesktopNativeConfigurationField.allCases {
            if field == .legacyCustomPrompt {
                sources[field.rawValue] = settings.legacyCustomPromptSource()
            } else if let root = roots[field.sourceRoot] {
                sources[field.rawValue] = field.value(in: root)
            }
        }
        let native = try DesktopNativeConfigurationCapture.capture(
            sources, platform: platform, selectedFields: selectedNativeFields
        )
        return Self(canonical: try DesktopHostPreferenceArchive.project(
            settings, categories: categories, validateJSON: validateJSON
        ), native: native, unresolvedPaths: DesktopNativeConfigurationField.unclassifiedPaths(
            in: roots, platform: platform
        ))
    }
}

extension DesktopHostController {
    package func configurationCapture(
        categories: Set<DataMigrationCategory>, selectedNativeFields: Set<String> = [],
        validateJSON: ((DataMigrationRecord) throws -> Void)? = nil
    ) throws -> DesktopHostConfigurationCapture {
        try DesktopHostConfigurationCapture.capture(
            settings, categories: categories, selectedNativeFields: selectedNativeFields, validateJSON: validateJSON
        )
    }
}
