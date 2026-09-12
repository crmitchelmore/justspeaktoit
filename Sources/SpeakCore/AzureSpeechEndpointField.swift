import SwiftUI

/// A device-local resource address; API credentials remain in Keychain.
public struct AzureSpeechEndpointField: View {
    @AppStorage(AzureSpeechConfiguration.endpointDefaultsKey) private var endpoint = ""
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Azure resource endpoint", text: $endpoint)
                .autocorrectionDisabled()
                #if os(iOS)
                // The origin check requires a lowercase `https` scheme, so a
                // sentence-cased `Https://` from the keyboard would be rejected.
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .accessibilityIdentifier("azure-speech-resource-endpoint")
            Text("For live transcription, paste the HTTPS endpoint from your Speech resource’s Keys and Endpoint page. "
                + "Recorded audio uses your region when this is empty. Models depend on region and tier.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !endpoint.isEmpty, (try? AzureSpeechConfiguration.resourceURL(endpoint)) == nil {
                Text("Use a resource address ending in cognitiveservices.azure.com or services.ai.azure.com.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
