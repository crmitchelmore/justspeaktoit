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
                + "Recorded audio also accepts http://127.0.0.1:PORT for a local proxy. "
                + "Save local-proxy/ followed by the proxy token in the Azure transcription key field. "
                + "The proxy does not support live transcription. An empty endpoint uses your Azure region.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !endpoint.isEmpty, (try? AzureSpeechConfiguration.batchResourceURL(endpoint)) == nil {
                Text("Use an Azure HTTPS resource address or http://127.0.0.1:PORT, with no path.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
