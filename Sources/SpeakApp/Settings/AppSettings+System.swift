import AppKit
import Foundation
import ServiceManagement
import SpeakCore

/// What `AppSettings` reaches outside `UserDefaults`: the Dock, login items and
/// the local model catalogue used to validate a streaming source.
extension AppSettings {
  /// Streaming sources the app is allowed to select, plus the fallback used when the persisted
  /// choice is not one of them.
  struct LocalStreamingCatalog {
    var supportedIDs: Set<String>
    var defaultID: String

    @MainActor
    static func current() -> LocalStreamingCatalog {
      let whisperKitStreamingIDs = LocalModelManager.shared.availableModels
        .filter(\.supportsLiveStreaming)
        .map(WhisperKitStreamingModel.id(for:))
      let defaultID = FluidAudioModelManager.supportsCurrentHardware
        ? FluidAudioParakeetModel.id
        : whisperKitStreamingIDs.first ?? ""
      let fluidAudioStreamingIDs = FluidAudioModelManager.supportsCurrentHardware
        ? [FluidAudioParakeetModel.id]
        : []
      var supportedIDs = Set(whisperKitStreamingIDs).union(fluidAudioStreamingIDs)
      #if !APP_STORE
      supportedIDs.formUnion(LocalModelManager.recommendedStreamingModelSources.map(\.id))
      supportedIDs.formUnion(LocalModelManager.shared.streamingModelSources.map(\.id))
      #endif
      return LocalStreamingCatalog(supportedIDs: supportedIDs, defaultID: defaultID)
    }
  }

  /// Resolves the streaming catalogue the first time ``localStreamingModelSource`` is read.
  /// Overridable so tests can prove launch never forces `LocalModelManager.shared`.
  static var localStreamingCatalogProvider: @MainActor () -> LocalStreamingCatalog =
    LocalStreamingCatalog.current

  /// What applying these settings reaches outside `defaults`: the folder that
  /// holds the default Recordings directory, the app's Dock presence and its
  /// login item. The app uses `.live`; test settings pass their own, so
  /// constructing them never creates folders in the user's Application
  /// Support, changes the test runner's activation policy or queries login items.
  struct SystemDependencies {
    var fileManager: FileManager
    var setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    var registerLoginItem: @MainActor (_ enabled: Bool) throws -> Void

    /// Serialises login-item changes so the most recent request is applied last.
    private static let loginItemQueue = DispatchQueue(label: "com.justspeaktoit.login-item", qos: .utility)

    /// Waits for queued login-item changes, so quitting cannot abandon the latest toggle.
    static func drainLoginItemChanges() async {
      await withCheckedContinuation { continuation in
        loginItemQueue.async { continuation.resume() }
      }
    }

    static let live = SystemDependencies(
      fileManager: .default,
      setActivationPolicy: { NSApplication.shared.setActivationPolicy($0) },
      // `SMAppService.status` is a synchronous XPC round trip (about 80-120 ms
      // measured on launch), so reconcile off the main thread.
      registerLoginItem: { enabled in
        loginItemQueue.async {
          do {
            let service = SMAppService.mainApp
            if enabled {
              if service.status != .enabled {
                try service.register()
              }
            } else if service.status == .enabled {
              try service.unregister()
            }
          } catch {
            SpeakLogger.logger(category: "AppSettings")
              .error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
          }
        }
      }
    )
  }
}

extension AppSettings.SystemDependencies {
  /// Registers or unregisters the app as a login item; a failure is logged, not thrown.
  @MainActor
  func updateLoginItem(enabled: Bool) {
    do {
      try registerLoginItem(enabled)
    } catch {
      SpeakLogger.logger(category: "AppSettings")
        .error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
    }
  }
}
