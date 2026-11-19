#if os(iOS)
import SpeakCore
import SwiftUI
import UIKit

extension ContentView {
    // MARK: - Floating Controls with Glass Effect

    /// Icon and visible title, so the action is named on screen on iPhone and
    /// iPad alike rather than relying on an icon-only button.
    var recordButtonLabel: some View {
        let control = recordControl
        return HStack(spacing: density.isCompact ? 6 : 8) {
            Image(systemName: control.symbolName)
                .font(.system(size: primarySymbolSize))
            Text(control.title)
                .font(density.isCompact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, density.isCompact ? 12 : 20)
        .frame(minWidth: primaryControlSize, minHeight: primaryControlSize)
    }

    @ViewBuilder
    var floatingControls: some View {
        #if compiler(>=6.1) && canImport(SwiftUI, _version: 7.0)
        if #available(iOS 26.0, *) {
            floatingControlsGlass
        } else {
            floatingControlsFallback
        }
        #else
        floatingControlsFallback
        #endif
    }

    #if compiler(>=6.1) && canImport(SwiftUI, _version: 7.0)
    @available(iOS 26.0, *)
    @ViewBuilder
    var floatingControlsGlass: some View {
        GlassEffectContainer(spacing: density.isCompact ? 8 : 16) {
            HStack(spacing: density.isCompact ? 8 : 16) {
                // Primary action - Start/Stop
                Button {
                    Task {
                        await toggleRecording()
                    }
                } label: {
                    recordButtonLabel
                }
                .buttonStyle(.glassProminent)
                .tint(isAnyRecording ? .red : .brandAccent)
                .clipShape(Capsule())
                .accessibilityLabel(recordControl.accessibilityLabel)
                .accessibilityInputLabels(recordControl.inputLabels)
                .accessibilityIdentifier("recordToggleButton")

                // Secondary actions (only visible when there's text and not recording)
                if hasTextToShow && !isAnyRecording {
                    // Polish/Post-process button
                    Button {
                        showingPostProcessing = true
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: secondarySymbolSize))
                            .frame(width: secondaryControlSize, height: secondaryControlSize)
                    }
                    .buttonStyle(.glass)
                    .tint(.purple)
                    .clipShape(Circle())
                    .accessibilityLabel("Polish transcript")
                    .accessibilityIdentifier("polishTranscriptButton")
                    .transition(.scale.combined(with: .opacity))

                    // Copy button
                    Button {
                        copyToClipboard()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: secondarySymbolSize))
                            .frame(width: secondaryControlSize, height: secondaryControlSize)
                    }
                    .buttonStyle(.glass)
                    .tint(.brandAccentWarm)
                    .clipShape(Circle())
                    .accessibilityLabel(copied ? "Copied to clipboard" : "Copy transcript")
                    .accessibilityIdentifier("copyTranscriptButton")
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasTextToShow)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: coordinator.isRunning)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: backgroundService.isRunning)
    }
    #endif

    @ViewBuilder
    var floatingControlsFallback: some View {
        HStack(spacing: density.isCompact ? 8 : 16) {
            // Primary action - Start/Stop
            Button {
                Task {
                    await toggleRecording()
                }
            } label: {
                recordButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(isAnyRecording ? .red : .accentColor)
            .clipShape(Capsule())
            .accessibilityLabel(recordControl.accessibilityLabel)
            .accessibilityInputLabels(recordControl.inputLabels)
            .accessibilityIdentifier("recordToggleButton")

            // Secondary actions (only visible when there's text and not recording)
            if hasTextToShow && !isAnyRecording {
                // Polish/Post-process button
                Button {
                    showingPostProcessing = true
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: secondarySymbolSize))
                        .frame(width: secondaryControlSize, height: secondaryControlSize)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .clipShape(Circle())
                .accessibilityLabel("Polish transcript")
                .accessibilityIdentifier("polishTranscriptButton")
                .transition(.scale.combined(with: .opacity))

                // Copy button
                Button {
                    copyToClipboard()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: secondarySymbolSize))
                        .frame(width: secondaryControlSize, height: secondaryControlSize)
                }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .accessibilityLabel(copied ? "Copied to clipboard" : "Copy transcript")
                .accessibilityIdentifier("copyTranscriptButton")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasTextToShow)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: coordinator.isRunning)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: backgroundService.isRunning)
    }
}
#endif
