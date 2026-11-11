#if os(iOS)
import SpeakCore
import SwiftUI
import UIKit

extension ContentView {
    // MARK: - Floating Controls with Glass Effect

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
                    Image(systemName: primaryActionSymbol)
                        .font(.system(size: primarySymbolSize))
                        .frame(width: primaryControlSize, height: primaryControlSize)
                }
                .buttonStyle(.glassProminent)
                .tint(isAnyRecording ? .red : .brandAccent)
                .clipShape(Circle())
                .accessibilityLabel(primaryActionLabel)
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
                Image(systemName: primaryActionSymbol)
                    .font(.system(size: primarySymbolSize))
                    .frame(width: primaryControlSize, height: primaryControlSize)
            }
            .buttonStyle(.borderedProminent)
            .tint(isAnyRecording ? .red : .accentColor)
            .clipShape(Circle())
            .accessibilityLabel(primaryActionLabel)
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
