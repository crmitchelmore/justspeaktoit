import SwiftUI

/// One bundled or discovered catalogue model's details and settings, confirmed
/// with an explicit choice; the catalogue-option counterpart of the audio model page.
@MainActor
struct OpenRouterOptionDetail: View {
    let option: ModelCatalog.Option
    let purpose: ModelCredentialPurpose
    let actionTitle: String
    let selectedTitle: String
    let routeNote: String
    let isSelected: Bool
    var temperature: Binding<Double>?
    let onSelect: (String) -> Void

    var body: some View {
        Form {
            Section("Model") {
                Text(option.displayName).font(.headline)
                Text(OpenRouterCatalogOptions.modelSlug(for: option.id)).font(.caption).textSelection(.enabled)
                if let description = option.description, !description.isEmpty { Text(description) }
                LabeledContent("Provider", value: OpenRouterCatalogOptions.provider(for: option, purpose: purpose))
                if let length = option.contextLength {
                    LabeledContent("Context limit", value: "\(length.formatted()) tokens")
                }
                LabeledContent("Speed", value: option.latencyTier.displayName)
                if !option.tags.isEmpty {
                    LabeledContent("Strengths", value: option.tags.map(\.displayName).joined(separator: ", "))
                }
                if OpenRouterCatalogOptions.isUnqualifiedDiscovery(option) {
                    Label("Discovered model: not yet tested for cleanup.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Pricing") {
                if let pricing = option.pricing {
                    LabeledContent("Input / output", value: pricing.displayName + " tokens")
                    Text("Base prices can vary by context and provider; check OpenRouter before use.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Pricing is not listed for this model.")
                }
                if let url = OpenRouterCatalogOptions.modelPageURL(for: option.id) {
                    Link("Model details on OpenRouter", destination: url)
                }
            }
            if let temperature {
                Section("Settings") {
                    LabeledContent("Temperature") {
                        Text(temperature.wrappedValue, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }
                    Slider(value: temperature, in: 0...1, step: 0.05)
                        .accessibilityLabel("Temperature")
                        .accessibilityValue(String(format: "%.2f", temperature.wrappedValue))
                    Text("Lower values stay close to your words. This applies to every remote cleanup model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(isSelected ? selectedTitle : actionTitle) {
                    onSelect(option.id)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSelected)
                .accessibilityIdentifier("openRouterOption.use")
                Text(routeNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(option.displayName)
    }
}
