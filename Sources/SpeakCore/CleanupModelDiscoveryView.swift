import SwiftUI

/// Shared native Mac/iOS opt-in control. Opening settings while disabled performs no network work.
public struct CleanupModelDiscoveryView: View {
    @Binding private var selection: String
    @Binding private var enabled: Bool
    @State private var state = CleanupModelDiscoveryStore.shared.snapshot
    @State private var refreshing = false

    public init(selection: Binding<String>, enabled: Binding<Bool>) {
        _selection = selection
        _enabled = enabled
    }

    private var discovered: [DiscoveredCleanupModel] {
        let bundled = Set(ModelCatalog.cloudPostProcessing.map(\.id))
        guard let updated = state.lastUpdated,
              Date().timeIntervalSince(updated) <= CleanupModelDiscoveryStore.maximumCacheAge else { return [] }
        return state.models.filter { !bundled.contains($0.id) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(CleanupModelSelection.settingTitle, isOn: Binding(
                get: { enabled },
                set: { enabled = $0; CleanupModelDiscoveryStore.shared.setEnabled($0) }
            ))
            Text("Downloads public model details only. No key or transcript is sent. Choose a model explicitly below.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Turning discovery off keeps your saved model. Bundled choices remain available offline.")
                .font(.caption).foregroundStyle(.secondary)
            if enabled {
                HStack {
                    Button("Refresh models") { Task { await refresh(force: true) } }
                        .disabled(refreshing)
                    if refreshing { ProgressView().controlSize(.small) }
                }
                if let message = state.errorMessage { Text(message).font(.caption) }
                if let updated = state.lastUpdated {
                    Text("Last updated: \(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Base prices can vary by context and provider. "
                    + "Discovered models have not been tested for cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Browse discovered models (\(discovered.count))") {
                    ForEach(discovered) { model in
                        Button {
                            selection = model.selectionID
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(model.name)
                                    Text(model.option.pricing?.displayName ?? "Pricing not supplied")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == model.selectionID { Image(systemName: "checkmark") }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .task(id: enabled) {
            CleanupModelDiscoveryStore.shared.setEnabled(enabled)
            if enabled { await refresh(force: false) }
        }
    }

    @MainActor private func refresh(force: Bool) async {
        refreshing = true
        defer { refreshing = false }
        state = await CleanupModelDiscoveryStore.shared.refresh(force: force)
    }
}
