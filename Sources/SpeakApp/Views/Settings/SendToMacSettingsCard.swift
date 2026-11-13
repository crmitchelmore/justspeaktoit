import AppKit
import SpeakCore
import SwiftUI

/// This Mac's Send to Mac receiver, its pairing code and the devices
/// connected to it. The iOS app pairs and sends from Settings › Sync & Transfer.
struct SendToMacSettingsCard: View, AppSettingsBindingProviding {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject var settings: AppSettings

  var body: some View {
    SettingsCard(title: "Send to Mac", systemImage: "iphone.and.arrow.forward", tint: Color.green) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Receive finished transcripts from Just Speak to It on iPhone or iPad over the local network. "
          + "They're pasted where your cursor is.")
          .font(.callout)
          .foregroundStyle(.secondary)

        settingsToggle(
          "Enable Send to Mac",
          isOn: Binding(
            get: { settings.enableSendToMac },
            set: { newValue in
              settings.enableSendToMac = newValue
              if newValue {
                do {
                  try environment.transportServer.start()
                } catch {
                  // Reflect reality: the listener did not start, so flip the
                  // toggle back off and let the error label explain why.
                  settings.enableSendToMac = false
                }
              } else {
                environment.transportServer.stop()
              }
            }
          ),
          tint: .green
        )
        .speakTooltip(
          "Let iPhone and iPad pair with this Mac and send it transcripts over the local network."
        )

        if let transportError = environment.transportServer.error,
           !environment.transportServer.isRunning {
          Label(
            "Send to Mac could not start: \(transportError.localizedDescription)",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
        }

        if settings.enableSendToMac {
          Divider()

          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Text("Pairing Code:")
                .font(.headline)
              Spacer()
              Text(PairingManager.shared.pairingCode)
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(.green)
              CopyButton(title: "Copy pairing code") {
                CopyFeedback.writeToPasteboard(PairingManager.shared.pairingCode)
              }
              .buttonStyle(.borderless)
              .speakTooltip("Copy pairing code to clipboard")
            }

            Text("Enter this code on iPhone or iPad in Settings › Sync & Transfer › Send to Mac. "
              + "It's used once; the device then keeps its own key.")
              .font(.caption)
              .foregroundStyle(.secondary)

            DestructiveConfirmButton(
              "Regenerate Code",
              dialogTitle: "Regenerate Pairing Code?",
              message: "This disconnects every paired device.",
              confirmTitle: "Regenerate Code"
            ) {
              _ = PairingManager.shared.regeneratePairingCode()
            }
            .buttonStyle(.bordered)
            .speakTooltip("Generate a new pairing code.")

            Text("Regenerating disconnects every paired device.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding()
          .background(
            RoundedRectangle(cornerRadius: 8)
              .fill(Color.green.opacity(0.1))
          )

          if environment.transportServer.isRunning {
            HStack(spacing: 6) {
              Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
              Text("Server running, ready for connections")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          if !environment.transportServer.connectedDevices.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: 8) {
              Text("Connected Devices:")
                .font(.headline)

              ForEach(environment.transportServer.connectedDevices) { device in
                HStack {
                  Image(systemName: "iphone")
                    .foregroundStyle(Color.brandLagoon)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                      .font(.subheadline)
                    Text("Connected \(device.connectedAt, style: .relative) ago")
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Button {
                    environment.transportServer.disconnectDevice(id: device.id)
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                  }
                  .buttonStyle(.borderless)
                  .foregroundStyle(.secondary)
                  .speakTooltip("Disconnect this device")
                  .accessibilityLabel("Disconnect \(device.name)")
                  .accessibilityIdentifier("transportDisconnectDevice-\(device.id)")
                }
                .padding(8)
                .background(
                  RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                )
              }
            }
          }
        }
      }
    }
    .speakTooltip("Send transcripts from iPhone or iPad to this Mac, where they are pasted at the cursor.")
  }
}
