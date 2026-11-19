import AppKit
import Foundation
import SpeakCore
import SwiftUI

/// `SpeakCore.AppSwitchDelivery` would resolve to the `SpeakCore` version enum, not the module.
typealias SharedAppSwitchDelivery = AppSwitchDelivery

/// The value domains of the macOS-only preferences `AppSettings` publishes.
extension AppSettings {
  enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// Converts to SwiftUI ColorScheme, returning nil for system (follows system setting)
    var colorScheme: ColorScheme? {
      switch self {
      case .system: return nil
      case .light: return .light
      case .dark: return .dark
      }
    }

    /// The app-wide AppKit appearance; nil follows the system setting.
    var nsAppearance: NSAppearance? {
      switch self {
      case .system: return nil
      case .light: return NSAppearance(named: .aqua)
      case .dark: return NSAppearance(named: .darkAqua)
      }
    }
  }

  enum TranscriptionMode: String, CaseIterable, Identifiable {
    case liveNative
    case batchRemote
    case localModel

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .liveNative:
        return "Remote Streaming"
      case .batchRemote:
        return "Remote Batch"
      case .localModel:
        return "Local"
      }
    }
  }

  nonisolated static func effectiveTranscriptionModeDisplayName(
    transcriptionMode: TranscriptionMode,
    liveTranscriptionModel: String,
    localTranscriptionMode: LocalTranscriptionMode
  ) -> String {
    switch transcriptionMode {
    case .liveNative:
      return ModelCatalog.isOnDeviceLiveTranscriptionModel(liveTranscriptionModel)
        ? "Apple On-Device"
        : "Remote Streaming"
    case .batchRemote:
      return "Remote Batch"
    case .localModel:
      return localTranscriptionMode.displayName
    }
  }

  var effectiveTranscriptionModeDisplayName: String {
    Self.effectiveTranscriptionModeDisplayName(
      transcriptionMode: transcriptionMode,
      liveTranscriptionModel: liveTranscriptionModel,
      localTranscriptionMode: localTranscriptionMode
    )
  }

  enum LocalTranscriptionMode: String, CaseIterable, Identifiable {
    case batch
    case streaming

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .batch:
        return "Local Batch"
      case .streaming:
        return "Local Streaming"
      }
    }
  }

  enum TextOutputMethod: String, CaseIterable, Identifiable {
    case smart
    case accessibilityOnly
    case clipboardOnly

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .smart:
        return "Smart (Auto)"
      case .accessibilityOnly:
        return "Accessibility"
      case .clipboardOnly:
        return "Clipboard"
      }
    }
  }

  nonisolated static func availableTextOutputMethods(
    for channel: DistributionChannel
  ) -> [TextOutputMethod] {
    channel.supportsAccessibilityTextInsertion ? TextOutputMethod.allCases : [.clipboardOnly]
  }

  nonisolated static func normalizedTextOutputMethod(
    _ method: TextOutputMethod,
    for channel: DistributionChannel
  ) -> TextOutputMethod {
    availableTextOutputMethods(for: channel).contains(method) ? method : .clipboardOnly
  }

  enum AccessibilityInsertionMode: String, CaseIterable, Identifiable {
    case insertAtCursor
    case replaceAll

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .insertAtCursor:
        return "Insert at Cursor"
      case .replaceAll:
        return "Replace Field"
      }
    }
  }

  /// Where a finished transcript goes when, by the time it is ready, the user
  /// is in a different app from the one where recording started.
  typealias AppSwitchDelivery = SharedAppSwitchDelivery

  enum HotKeyActivationStyle: String, CaseIterable, Identifiable {
    case holdToRecord
    case doubleTapToggle
    case holdAndDoubleTap

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .holdToRecord:
        return "Press & Hold"
      case .doubleTapToggle:
        return "Double Tap"
      case .holdAndDoubleTap:
        return "Hold & Double Tap"
      }
    }

    var allowsHold: Bool {
      switch self {
      case .holdToRecord, .holdAndDoubleTap:
        return true
      case .doubleTapToggle:
        return false
      }
    }

    var allowsDoubleTap: Bool {
      switch self {
      case .doubleTapToggle, .holdAndDoubleTap:
        return true
      case .holdToRecord:
        return false
      }
    }
  }

  /// Controls where the app appears in the system UI
  enum AppVisibility: String, CaseIterable, Identifiable {
    case dockAndMenuBar
    case menuBarOnly
    case dockOnly

    var id: String { rawValue }

    var displayName: String {
      switch self {
      case .dockAndMenuBar:
        return "Dock & Menu Bar"
      case .menuBarOnly:
        return "Menu Bar Only"
      case .dockOnly:
        return "Dock Only"
      }
    }

    var showInDock: Bool {
      self == .dockAndMenuBar || self == .dockOnly
    }

    var showInMenuBar: Bool {
      self == .dockAndMenuBar || self == .menuBarOnly
    }
  }

  typealias HUDSizePreference = HUDExpansionPreference

  enum SpeedMode: String, CaseIterable, Identifiable {
    case instant       // Mode A: Raw, no LLM
    case livePolish    // Mode B: Incremental tail rewrite

    var id: String { rawValue }

    var displayName: String {
      coreID.displayName
    }

    var description: String {
      switch self {
      case .instant:
        return "Raw transcription with no AI cleanup. Fastest output."
      case .livePolish:
        return "AI cleans up spelling and punctuation as you speak."
      }
    }

    var usesLivePolish: Bool {
      switch self {
      case .instant:
        return false
      case .livePolish:
        return true
      }
    }

    /// Bridge to `SpeakCore.SpeedModeID`. Use a switch so adding a new
    /// `SpeedMode` is a compile error until a corresponding `SpeedModeID`
    /// mapping is added (rather than silently falling back to `.instant`).
    var coreID: SpeedModeID {
      switch self {
      case .instant: return .instant
      case .livePolish: return .livePolish
      }
    }
  }
}
