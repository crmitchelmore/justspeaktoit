import AppKit
import SpeakCore
import SwiftUI

// MARK: - Automation CLI card (issue #775)

extension SettingsView {
  /// Installs, updates and removes the standalone `speak` CLI. Shown only on
  /// channels that may place executable code in the user's Application
  /// Support folder.
  @ViewBuilder
  var automationCLICard: some View {
    if DistributionChannel.current.supportsStandaloneCLIInstaller {
      SettingsCard(title: "Automation CLI", systemImage: "terminal.fill", tint: Color.brandLagoon) {
        VStack(alignment: .leading, spacing: 12) {
          Text(
            "The \"speak\" command-line tool runs dictation from the terminal or an AI agent: "
              + "transcribe files, listen, stop, read history, check status, and serve MCP. "
              + "It installs into your Application Support folder — no administrator rights, "
              + "and your shell profile is never edited for you."
          )
          .font(.callout)
          .foregroundStyle(.secondary)

          automationCLIStatus
          automationCLIActions
        }
      }
      .speakTooltip("Install the standalone speak CLI for terminal and agent automation.")
    }
  }

  @ViewBuilder
  private var automationCLIStatus: some View {
    switch cliInstaller.state {
    case .notInstalled:
      SettingsInlineInfo(
        title: "Not installed",
        message: "Install the CLI to use speak from the terminal, scripts, or MCP clients.",
        systemImage: "terminal"
      )
    case .unavailable(let message):
      SettingsInlineInfo(title: "Not available", message: message, systemImage: "exclamationmark.circle")
    case .installing(let phase):
      automationCLIProgress(for: phase)
    case .installed(let cli):
      automationCLIInstalledDetails(cli, updateAvailable: nil)
    case .updateAvailable(let cli, let latest):
      automationCLIInstalledDetails(cli, updateAvailable: latest)
    case .failed(let message, let installed):
      SettingsInlineInfo(
        title: installed == nil ? "Installation failed" : "Update failed",
        message: installed == nil
          ? message
          : "\(message) The previously installed CLI is still in place.",
        systemImage: "xmark.octagon"
      )
      if let installed {
        automationCLIInstalledDetails(installed, updateAvailable: nil)
      }
    }
  }

  private func automationCLIProgress(for phase: SpeakCLIInstaller.Phase) -> some View {
    HStack(spacing: 10) {
      switch phase {
      case .downloading(let fraction?):
        ProgressView(value: fraction).frame(maxWidth: 220)
        Text("Downloading \(Int(fraction * 100))%")
      case .downloading(nil):
        ProgressView().controlSize(.small)
        Text("Downloading")
      case .verifying:
        ProgressView().controlSize(.small)
        Text("Verifying signature and checksum")
      case .installing:
        ProgressView().controlSize(.small)
        Text("Installing")
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }

  private func automationCLIInstalledDetails(
    _ cli: SpeakCLIInstaller.InstalledCLI,
    updateAvailable: String?
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      LabeledContent("Version", value: cli.version)
      LabeledContent("Architecture", value: cli.architecture)
      LabeledContent("Path") {
        Text(cliInstaller.executableURL.path)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
      if let updateAvailable {
        SettingsInlineInfo(
          title: "Update available",
          message: "Version \(updateAvailable) of the CLI is published. The app itself is not changed.",
          systemImage: "arrow.down.circle"
        )
      }
      if !cliInstaller.isCompatible(cli) {
        SettingsInlineInfo(
          title: "Protocol mismatch",
          message: "This CLI speaks automation protocol v\(cli.automationSchemaVersion); the app speaks "
            + "v\(cliInstaller.dependencies.automationSchemaVersion). Update the CLI.",
          systemImage: "exclamationmark.triangle"
        )
      }
    }
    .font(.callout)
  }

  @ViewBuilder
  private var automationCLIActions: some View {
    let state = cliInstaller.state
    HStack(spacing: 8) {
      switch state {
      case .notInstalled, .unavailable:
        Button("Install CLI") { Task { await cliInstaller.install() } }
          .buttonStyle(.borderedProminent)
          .disabled(state.isBusy)
        Button("Check again") { Task { await cliInstaller.checkForUpdate() } }
          .buttonStyle(.bordered)
      case .installing:
        EmptyView()
      case .installed:
        Button("Check for update") { Task { await cliInstaller.checkForUpdate() } }
          .buttonStyle(.bordered)
        automationCLIPathButtons
        Button("Uninstall", role: .destructive) { cliInstaller.uninstall() }
          .buttonStyle(.bordered)
      case .updateAvailable:
        Button("Update CLI") { Task { await cliInstaller.install() } }
          .buttonStyle(.borderedProminent)
        automationCLIPathButtons
        Button("Uninstall", role: .destructive) { cliInstaller.uninstall() }
          .buttonStyle(.bordered)
      case .failed(_, let installed):
        Button(installed == nil ? "Retry install" : "Retry update") { Task { await cliInstaller.install() } }
          .buttonStyle(.borderedProminent)
        if installed != nil {
          automationCLIPathButtons
          Button("Uninstall", role: .destructive) { cliInstaller.uninstall() }
            .buttonStyle(.bordered)
        }
      }
    }
  }

  @ViewBuilder
  private var automationCLIPathButtons: some View {
    Button("Copy PATH command") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(cliInstaller.pathCommand, forType: .string)
    }
    .buttonStyle(.bordered)
    .speakTooltip(cliInstaller.pathCommand)
    Button("Reveal in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting([cliInstaller.executableURL])
    }
    .buttonStyle(.bordered)
  }
}
