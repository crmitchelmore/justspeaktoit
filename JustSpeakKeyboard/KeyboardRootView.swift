import SpeakCore
import SwiftUI
import UIKit

/// Compact dictation-first keyboard surface.
///
/// Layout is a live transcript strip above one control row
/// (``KeyboardControlRow``), with the insert-pending chip above both when the
/// app has left a transcript waiting. There is deliberately no QWERTY layer —
/// the globe key returns to the system keyboard for typing.
struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardViewModel
    let showsInputModeSwitch: Bool
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let showInputModeList: (UIButton, UIEvent) -> Void

    var body: some View {
        let surface = model.surface
        VStack(spacing: 8) {
            if case let .chip(chip) = model.pickupOffering {
                KeyboardPickupChipRow(
                    chip: chip,
                    insert: { model.insertPendingPickup() },
                    dismiss: { model.dismissPendingPickup() }
                )
            }
            transcriptStrip(surface)
            KeyboardControlRow(
                model: model,
                surface: surface,
                showsInputModeSwitch: showsInputModeSwitch,
                insertText: insertText,
                deleteBackward: deleteBackward,
                showInputModeList: showInputModeList
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func transcriptStrip(_ surface: KeyboardSurfaceState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: surface.stripSymbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Self.tint(surface.stripTone))
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(surface.stripText)
                .font(.subheadline.weight(surface.showsLiveText ? .medium : .regular))
                .foregroundStyle(surface.showsLiveText ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityLabel(surface.stripAccessibilityLabel)
                .accessibilityIdentifier("keyboardLiveTranscript")
            if surface.showsCancel {
                Button("Cancel") {
                    model.cancelTapped()
                }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("keyboardCancelButton")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.15), value: surface.stripText)
    }

    private static func tint(_ tone: KeyboardSurfaceState.Tone) -> Color {
        switch tone {
        case .success: return .green
        case .warning: return .orange
        case .live: return .red
        case .neutral: return .secondary
        }
    }
}
