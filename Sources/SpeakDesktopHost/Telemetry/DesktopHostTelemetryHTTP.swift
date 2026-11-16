import Foundation
import SpeakDesktop
import SpeakSync

/// Telemetry over the host's existing HTTPS transport (URLSession on Linux,
/// WinHTTP on Windows): redirect-free, cookie-free and bounded. Responses are
/// read only for their status and capped small.
package struct DesktopHostTelemetryHTTP: DesktopTelemetryHTTP {
    package static let timeout: Duration = .seconds(5)
    private let transport: any CloudKitWebServicesHTTPTransport

    package init(transport: any CloudKitWebServicesHTTPTransport) {
        self.transport = transport
    }

    package func post(_ url: URL, headers: [String: String], body: Data) async throws -> Int {
        let request = CloudKitWebServicesHTTPRequest(method: "POST", url: url, headers: headers, body: body)
        return try await transport.send(request, responseLimit: 16_384).statusCode
    }
}
