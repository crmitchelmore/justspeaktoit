import SwiftUI

/// The least-privilege creation guide for one stored credential, collapsed by
/// default under its API key field. It shows only the uses passed in.
public struct APIKeyGuideDisclosure: View {
    private let identifier: String
    private let uses: APIKeyUses

    public init(identifier: String, uses: APIKeyUses) {
        self.identifier = identifier
        self.uses = uses
    }

    public var body: some View {
        if let guide = APIKeyGuidance.guide(for: identifier) {
            DisclosureGroup("Create a key with minimum access") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(guide.lines(for: uses).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Link("Open \(guide.providerName) key page", destination: guide.creationURL)
                    ForEach(guide.sources, id: \.self) { source in
                        Link(source.host ?? source.absoluteString, destination: source)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .font(.caption)
            .accessibilityIdentifier("api-key-guide-\(identifier)")
        }
    }
}
