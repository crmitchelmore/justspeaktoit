import SpeakCore
import SwiftUI
import UIKit

/// The keyboard's single control row:
/// globe · language chip · profile chip · mic/stop · delete · return.
///
/// Each chip appears only when it has somewhere to switch to, and the mic
/// drops its caption once both are present so the row never wraps.
struct KeyboardControlRow: View {
    @ObservedObject var model: KeyboardViewModel
    let surface: KeyboardSurfaceState
    let showsInputModeSwitch: Bool
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let showInputModeList: (UIButton, UIEvent) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if showsInputModeSwitch {
                InputModeSwitchButton(action: showInputModeList)
                    .frame(width: 46, height: 46)
                    .background(keyBackground)
                    .accessibilityLabel("Next keyboard")
                    .accessibilityHint("Touch and hold to choose another keyboard")
            }

            if let chip = model.languageChipLabel, model.showsLanguageChip, !surface.isBlocked {
                chipButton(
                    label: chip,
                    accessibilityLabel: "Dictation language \(chip). Tap to switch.",
                    identifier: "keyboardLanguageChip",
                    action: model.cycleLanguage
                )
            }

            if let chip = model.profileChipLabel, !surface.isBlocked {
                profileMenu(label: chip)
            }

            micButton

            Button {
                deleteBackward()
            } label: {
                Image(systemName: "delete.left")
                    .font(.body.weight(.medium))
                    .frame(width: 46, height: 46)
            }
            .background(keyBackground)
            .disabled(surface.controlsDisabled)
            .accessibilityLabel("Delete backward")
            .accessibilityIdentifier("keyboardDeleteButton")

            Button {
                insertText("\n")
            } label: {
                Image(systemName: "return")
                    .font(.body.weight(.medium))
                    .frame(width: 46, height: 46)
            }
            .background(keyBackground)
            .disabled(surface.controlsDisabled)
            .accessibilityLabel("Return")
            .accessibilityIdentifier("keyboardReturnButton")
        }
        .foregroundStyle(.primary)
    }

    /// One quick-switch chip: a key-sized button whose single tap advances the
    /// preference ring, disabled while capture or post-processing runs.
    private func chipButton(
        label: String,
        accessibilityLabel: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 46)
        }
        .background(keyBackground)
        .disabled(surface.isBusy)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    private func profileMenu(label: String) -> some View {
        Menu {
            ForEach(model.profileOptions) { profile in
                Button {
                    model.selectProfile(profile.id)
                } label: {
                    Label(
                        "\(profile.displayName) · \(profile.route.displayName)",
                        systemImage: profile.id == model.selectedProfileIdentifier ? "checkmark" : "circle"
                    )
                }
            }
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 46)
        }
        .background(keyBackground)
        .disabled(surface.isBusy)
        .accessibilityLabel(
            "Dictation profile \(model.profileDisplayName), \(model.profileRouteDisplayName). Choose profile."
        )
        .accessibilityIdentifier("keyboardProfileChip")
    }

    private var micButton: some View {
        Button {
            model.micTapped()
        } label: {
            HStack(spacing: 8) {
                if surface.micShowsProgress {
                    ProgressView()
                } else {
                    Image(systemName: surface.micSymbol)
                        .font(.title3.weight(.semibold))
                }
                if let caption = surface.micCaption {
                    Text(caption)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(.white)
            .background(
                micTint,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(surface.micDisabled)
        .accessibilityLabel(surface.micAccessibilityLabel)
        .accessibilityIdentifier("keyboardMicButton")
    }

    private var micTint: Color {
        if surface.isActivelyCapturing {
            return .red
        }
        return surface.micDisabled ? Color.gray.opacity(0.5) : .blue
    }

    private var keyBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
