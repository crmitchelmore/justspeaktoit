import SpeakCore
import SwiftUI

/// The searchable model list `ModelPicker` presents for long or detailed
/// choices. Native routes are listed first; OpenRouter routes sit behind one
/// drill-in row so a single key's hundreds of models never bury them.
struct ModelChooserSheet: View {
  let title: String
  let options: [ModelCatalog.Option]
  let credentialPurpose: ModelCredentialPurpose
  let storedAPIKeyIdentifiers: Set<String>
  let allowsCustom: Bool
  /// False when the picker has its own Browse OpenRouter button: the one
  /// selected OpenRouter model is then listed inline, with no drill-in row.
  var groupsOpenRouter = true
  @Binding var selection: String

  @State private var selectedTag: ModelCatalog.Tag?
  /// Native routes are listed first; OpenRouter is one row that opens its own list.
  @State private var isBrowsingOpenRouter = false

  private var groups: ModelPickerGrouping.Groups {
    ModelPickerGrouping.groups(options, purpose: credentialPurpose)
  }

  /// Group only when both kinds exist, so single-route pickers stay unchanged.
  private var isGrouped: Bool {
    groupsOpenRouter && !groups.direct.isEmpty && !groups.openRouter.isEmpty
  }

  private var levelOptions: [ModelCatalog.Option] {
    guard isGrouped else { return groups.direct + groups.openRouter }
    return isBrowsingOpenRouter ? groups.openRouter : groups.direct
  }

  var body: some View {
    LongListChooserSheet(
      title: isBrowsingOpenRouter ? ModelPickerGrouping.openRouterTitle : title,
      items: levelOptions, id: { $0.id }, selection: $selection,
      searchText: { [$0.displayName, $0.id, $0.description ?? ""] },
      includes: { option in selectedTag.map { option.tags.contains($0) } ?? true },
      controls: {
        AnyView(HStack {
          if isBrowsingOpenRouter {
            Button {
              isBrowsingOpenRouter = false
            } label: {
              Label("Back", systemImage: "chevron.left")
            }
            .accessibilityIdentifier("modelPicker.openRouter.back")
          }
          Picker("Filter", selection: $selectedTag) {
            Text("All").tag(ModelCatalog.Tag?.none)
            ForEach(ModelCatalog.Tag.allCases, id: \.self) { tag in
              Text(tag.displayName).tag(ModelCatalog.Tag?.some(tag))
            }
          }.pickerStyle(.segmented)
        })
      },
      clearFilters: { selectedTag = nil },
      footer: { select in
        AnyView(Group {
          if isGrouped && !isBrowsingOpenRouter {
            openRouterRow
          }
          if allowsCustom {
            Divider()
            Button {
              select(ModelCatalog.customOptionID)
            } label: {
              HStack {
                Text("Custom…")
                Spacer()
                ModelCredentialStatusView(
                  availability: ModelCredentialResolver.availability(
                    for: ModelCatalog.customOptionID,
                    purpose: credentialPurpose,
                    storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
                  )
                )
              }
            }
            .buttonStyle(.plain)
          }
        })
      },
      row: { option in
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
          Text(groupsOpenRouter ? option.displayName : ModelPickerGrouping.selectionLabel(
            for: option.id, displayName: option.displayName, purpose: credentialPurpose
          ))
            .font(.body)
          Spacer()
          if let contextLength = option.contextLength {
            Text(ModelContextLength.label(contextLength))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          if let pricing = option.pricing {
            Text(pricing.compactDisplay)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          ModelCredentialStatusView(
            availability: ModelCredentialResolver.availability(
              for: option.id,
              purpose: credentialPurpose,
              storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
            )
          )
          ModelTagBadges(tags: option.tags, compact: true)
          LatencyBadgeCompact(option: option)
        }

        if let description = option.description, !description.isEmpty {
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    })
    // A new identity per level resets the sheet's search text when drilling in or out.
    .id(isBrowsingOpenRouter)
  }

  private var openRouterRow: some View {
    Button {
      isBrowsingOpenRouter = true
    } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text(ModelPickerGrouping.openRouterTitle)
            .font(.body)
          Text(openRouterRowSubtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        ModelCredentialStatusView(
          availability: ModelCredentialResolver.availability(
            for: groups.openRouter[0].id,
            purpose: credentialPurpose,
            storedAPIKeyIdentifiers: storedAPIKeyIdentifiers
          )
        )
        Image(systemName: "chevron.right")
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("modelPicker.openRouter")
  }

  private var openRouterRowSubtitle: String {
    if let selected = groups.openRouter.first(where: { $0.id == selection }) {
      return "Selected: \(selected.displayName)"
    }
    return "\(groups.openRouter.count) models from many providers, with one OpenRouter key."
  }
}
