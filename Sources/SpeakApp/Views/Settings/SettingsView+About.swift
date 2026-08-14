import SpeakCore
import SpeakHotKeys
import SpeakSync
import AppKit
import SwiftUI

extension SettingsView {
  var aboutSettings: some View {
    SpeakDensitySettingsSection(density: settings.visualDensity) {
      SettingsCard(title: "Just Speak to It", systemImage: "info.circle", tint: Color.blue) {
        VStack(alignment: .leading, spacing: 16) {
          HStack(alignment: .top, spacing: 16) {
            if let appIcon = NSImage(named: "AppIcon") {
              Image(nsImage: appIcon)
                .resizable()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
              Text("Just Speak to It")
                .font(.title2.bold())
              Text("Voice-to-text made simple")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              Text("Built by Chris Mitchelmore")
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
          }

          Divider()

          VStack(alignment: .leading, spacing: 8) {
            Label("Version \(appVersion)", systemImage: "tag")
            Label("Build \(buildNumber)", systemImage: "hammer")
            if updaterManager.supportsSelfUpdate, let latest = updaterManager.latestVersion {
              Label("Latest \(latest)", systemImage: "arrow.up.circle")
            } else if updaterManager.supportsSelfUpdate {
              Label(updaterManager.updateStatusMessage, systemImage: "arrow.up.circle")
            } else {
              Label(updaterManager.updateStatusMessage, systemImage: "app.badge")
            }

            if let commit = commitRef, !commit.isEmpty {
              Label("Commit \(String(commit.prefix(7)))", systemImage: "arrow.triangle.branch")
            }
            Label(buildType, systemImage: buildType == "Release" ? "checkmark.seal" : "wrench.and.screwdriver")
              .foregroundStyle(buildType == "Release" ? .green : .orange)
            Label("Distribution: \(DistributionChannel.current.displayName)", systemImage: "shippingbox")
          }
          .font(.callout)
          .foregroundStyle(.secondary)

          Divider()

          HStack(spacing: 12) {
            if updaterManager.supportsSelfUpdate {
              Button {
                updaterManager.checkForUpdates()
              } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
              }
              .buttonStyle(.bordered)
              .disabled(!updaterManager.canCheckForUpdates)
            }

            Button {
              showingReleaseNotes = true
            } label: {
              Label("Release Notes", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Shows what changed in this version and earlier versions")

            if updaterManager.allowsCrossChannelMessaging {
              Link(destination: URL(string: "https://github.com/crmitchelmore/justspeaktoit/releases")!) {
                Label("View Releases", systemImage: "shippingbox")
              }
              .buttonStyle(.bordered)
            }
          }
        }
      }
      .sheet(isPresented: $showingReleaseNotes) {
        ReleaseNotesView()
      }

      SettingsCard(title: "Feedback & Support", systemImage: "bubble.left.and.bubble.right", tint: Color.green) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Have a bug to report or a feature to request? Visit our GitHub repository.")
            .font(.callout)
            .foregroundStyle(.secondary)

          HStack(spacing: 12) {
            Link(destination: URL(string: "https://github.com/crmitchelmore/justspeaktoit/issues")!) {
              Label("Report Issue", systemImage: "ladybug")
            }
            .buttonStyle(.bordered)

            Link(destination: URL(string: "https://github.com/crmitchelmore/justspeaktoit/issues/new?template=feature_request.md")!) {
              Label("Request Feature", systemImage: "lightbulb")
            }
            .buttonStyle(.bordered)

            Link(destination: URL(string: "https://github.com/crmitchelmore/justspeaktoit")!) {
              Label("View on GitHub", systemImage: "link")
            }
            .buttonStyle(.bordered)
          }
        }
      }

      SettingsCard(title: "Transfer to iOS", systemImage: "iphone.and.arrow.forward", tint: Color.cyan) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Transfer your API keys and settings to the iOS app by scanning a QR code.")
            .font(.callout)
            .foregroundStyle(.secondary)

          Button {
            showingConfigTransfer = true
          } label: {
            Label("Generate QR Code", systemImage: "qrcode")
          }
          .buttonStyle(.bordered)
        }
      }
      .sheet(isPresented: $showingConfigTransfer) {
        ConfigTransferView(secureStorage: environment.secureStorage)
      }

      SettingsCard(title: "Support Development", systemImage: "heart.fill", tint: Color.pink) {
        VStack(alignment: .leading, spacing: 12) {
          Text("If you find this app useful, consider leaving a tip to support continued development.")
            .font(.callout)
            .foregroundStyle(.secondary)

          TipJarView()
            .frame(maxWidth: .infinity)

          // In-app StoreKit tips work in App Store builds; external donation
          // links are only shown where cross-channel messaging is permitted.
          if DistributionChannel.current.allowsCrossChannelMessaging {
            HStack(spacing: 12) {
              Link(destination: URL(string: "https://github.com/sponsors/crmitchelmore")!) {
                Label("GitHub Sponsors", systemImage: "heart")
              }
              .buttonStyle(.bordered)

              Link(destination: URL(string: "https://ko-fi.com/crmitchelmore")!) {
                Label("Ko-fi", systemImage: "cup.and.saucer")
              }
              .buttonStyle(.bordered)
            }
          }
        }
      }

      SettingsCard(title: "Dependencies", systemImage: "shippingbox", tint: Color.orange) {
        VStack(alignment: .leading, spacing: 8) {
          Text("This app is built with the following open-source libraries:")
            .font(.callout)
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 6) {
            if updaterManager.supportsSelfUpdate {
              dependencyRow(
                name: "Sparkle",
                version: "2.6.0+",
                url: "https://sparkle-project.org",
                description: "Auto-update framework"
              )
            }
            dependencyRow(name: "SwiftLint", version: "0.55.0+", url: "https://github.com/realm/SwiftLint", description: "Swift linting tool")
            dependencyRow(name: "SwiftFormat", version: "0.53.6+", url: "https://github.com/nicklockwood/SwiftFormat", description: "Code formatting")
          }
        }
      }

      SettingsCard(title: "Legal", systemImage: "doc.text", tint: Color.gray) {
        VStack(alignment: .leading, spacing: 8) {
          Text("© 2024-2026 Chris Mitchelmore. All rights reserved.")
            .font(.callout)
            .foregroundStyle(.secondary)

          Link(destination: URL(string: "https://github.com/crmitchelmore/justspeaktoit/blob/main/LICENSE")!) {
            Label("View License (MIT)", systemImage: "doc.plaintext")
          }
          .buttonStyle(.bordered)
        }
      }
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
  }

  private var buildNumber: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
  }

  private var commitRef: String? {
    Bundle.main.object(forInfoDictionaryKey: "GitCommitSHA") as? String
  }

  private var buildType: String {
    // DEBUG builds are development, RELEASE builds check location
    #if DEBUG
    return "Development"
    #else
    // Release builds typically run from /Applications
    let bundlePath = Bundle.main.bundlePath
    if bundlePath.hasPrefix("/Applications") {
      return "Release"
    } else {
      return "Development"
    }
    #endif
  }

  private func dependencyRow(name: String, version: String, url: String, description: String) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .font(.callout.bold())
        Text(description)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Spacer()
      Text(version)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1), in: Capsule())
      Link(destination: URL(string: url)!) {
        Image(systemName: "arrow.up.right.square")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.blue)
    }
  }
}
