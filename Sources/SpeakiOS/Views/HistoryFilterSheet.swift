#if os(iOS)
import SpeakCore
import SwiftUI

/// History's model, errors-only and date filters. They narrow the list and never change stored entries.
struct HistoryFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var errorsOnly: Bool
    @Binding var selectedModel: String?
    @Binding var dateRangeEnabled: Bool
    @Binding var startDate: Date
    @Binding var endDate: Date
    let availableModels: [String]

    var body: some View {
        Form {
            Section("Show") {
                Toggle("Errors only", isOn: $errorsOnly)
                    .accessibilityIdentifier("historyFilterErrorsOnlyToggle")
                Picker("Model", selection: $selectedModel) {
                    Text("All Models").tag(String?.none)
                    ForEach(availableModels, id: \.self) { model in
                        Text(ModelCatalog.friendlyName(for: model)).tag(String?.some(model))
                    }
                }
                .accessibilityIdentifier("historyFilterModelPicker")
            }

            Section("Date Range") {
                Toggle("Limit by date", isOn: $dateRangeEnabled)
                    .accessibilityIdentifier("historyFilterDateRangeToggle")
                if dateRangeEnabled {
                    DatePicker("From", selection: $startDate, displayedComponents: .date)
                        .accessibilityIdentifier("historyFilterFromDatePicker")
                    DatePicker("To", selection: $endDate, in: startDate..., displayedComponents: .date)
                        .accessibilityIdentifier("historyFilterToDatePicker")
                }
            }

            if errorsOnly || selectedModel != nil || dateRangeEnabled {
                Section {
                    Button("Reset Filters", role: .destructive) {
                        errorsOnly = false
                        selectedModel = nil
                        dateRangeEnabled = false
                    }
                    .accessibilityIdentifier("historyFilterResetButton")
                }
            }
        }
        .navigationTitle("Filter History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("historyFilterDoneButton")
            }
        }
    }
}
#endif
