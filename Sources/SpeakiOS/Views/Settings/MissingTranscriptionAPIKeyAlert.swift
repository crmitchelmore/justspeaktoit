#if os(iOS)
import Foundation
import SpeakCore
import SwiftUI

extension View {
    func iosMissingTranscriptionAPIKeyAlert(
        alert: Binding<IOSMissingTranscriptionAPIKeyAlert?>,
        showingAPIKeys: Binding<Bool>,
        openURL: OpenURLAction
    ) -> some View {
        self.alert(
            alert.wrappedValue?.title ?? "API key required",
            isPresented: Binding(
                get: { alert.wrappedValue != nil },
                set: { if !$0 { alert.wrappedValue = nil } }
            ),
            presenting: alert.wrappedValue
        ) { presentedAlert in
            Button("Add API Key") {
                alert.wrappedValue = nil
                showingAPIKeys.wrappedValue = true
            }
            if let url = presentedAlert.apiKeyURL {
                Button("Get API Key") {
                    alert.wrappedValue = nil
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {
                alert.wrappedValue = nil
            }
        } message: { presentedAlert in
            Text(presentedAlert.message)
        }
    }
}

struct IOSMissingTranscriptionAPIKeyAlert: Identifiable {
    let id = UUID()
    let providerName: String
    let modelName: String
    let apiKeyURL: URL?

    var title: String { "API key required" }

    var message: String {
        "\(providerName) needs an API key for transcription with \(modelName). Add it now and try again."
    }

    @MainActor
    init?(modelID: String, settings: AppSettings) {
        // Provider metadata is single-sourced from SpeakCore's live routing so
        // every provider with a missing key triggers the alert, matching Mac.
        guard let route = LiveTranscriptionRouting.route(for: modelID),
              let apiKeyIdentifier = route.apiKeyIdentifier,
              !settings.storedAPIKeyIdentifiers.contains(apiKeyIdentifier) else {
            return nil
        }

        providerName = route.provider.displayName
        modelName = ModelCatalog.friendlyName(for: modelID)
        apiKeyURL = route.provider.apiKeyURL
    }
}
#endif
