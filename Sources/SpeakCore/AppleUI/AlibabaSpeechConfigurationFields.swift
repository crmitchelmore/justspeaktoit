import SwiftUI

public struct AlibabaSpeechConfigurationFields: View {
    @AppStorage("alibaba.newKey.region") private var region = ""
    @AppStorage("alibaba.newKey.workspace") private var workspace = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("API key region", selection: $region) {
                Text("Choose a region").tag("")
                ForEach(AlibabaSpeechConfiguration.Region.allCases, id: \.rawValue) { value in
                    Text(value.displayName).tag(value.rawValue)
                }
            }
            TextField("Workspace ID (for example, llm-...)", text: $workspace)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityIdentifier("alibaba-workspace-id")
            Text("For the new or replacement Alibaba key you save below. Use a key from this same region and "
                + "workspace. The key, region and workspace are saved and transferred together; changing these "
                + "fields does not change an existing key. Fun-ASR and Qwen3.5 require Beijing or Singapore.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

public extension AlibabaSpeechConfiguration {
    static func credentialsForSaving(_ key: String, defaults: UserDefaults = .standard) throws -> String {
        guard let region = Region(rawValue: defaults.string(forKey: "alibaba.newKey.region") ?? "") else {
            throw AlibabaSpeechError.configuration
        }
        return try Self(
            region: region, workspace: defaults.string(forKey: "alibaba.newKey.workspace") ?? "", apiKey: key
        ).encodedCredentials()
    }
}
