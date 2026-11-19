import SpeakCore
import SwiftUI

/// The insert-pending chip (issue #1003). One tap inserts; one tap dismisses.
/// Nothing here inserts on its own — putting a transcript the user did not
/// just ask for into whichever field happens to be focused would corrupt
/// their document.
struct KeyboardPickupChipRow: View {
    let chip: KeyboardPickupPolicy.Chip
    let insert: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: insert) {
                HStack(spacing: 6) {
                    Image(systemName: "text.insert")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(chip.label)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chip.label)
            .accessibilityHint("Inserts this transcript at the cursor")
            .accessibilityIdentifier("keyboardPickupChip")

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss pending transcript")
            .accessibilityIdentifier("keyboardPickupDismissButton")
        }
        .foregroundStyle(.primary)
        .background(
            Color.accentColor.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}
