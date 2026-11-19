import Combine
import CoreAudio
import Foundation
import SpeakCore
import os

/// Asks Core Audio whether this process is capturing from any input device.
/// This is the same signal that lights the menu-bar microphone indicator.
enum MacMicrophoneProbe {
  /// Nil when the OS cannot say (before macOS 14.2).
  static func isRunningInput() -> Bool? {
    guard #available(macOS 14.2, *) else { return nil }
    var translate = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var pid = ProcessInfo.processInfo.processIdentifier
    var process = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let found = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &translate, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process
    )
    guard found == noErr else { return nil }
    // A process that never touched audio has no process object: it is not capturing.
    guard process != kAudioObjectUnknown else { return false }
    var running = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(process, &running, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
  }
}

/// The Mac's live view of ``SystemResourceRegistry`` (issue #1471).
///
/// It publishes every registered hold, compares the registry with what Core
/// Audio reports so an open microphone nobody claims is shown (and logged with
/// the holds at that moment), and registers holds on behalf of components
/// whose state is already published: the dictation session, the hotkey
/// listener, speech playback and Compare Models.
@MainActor
final class SystemResourceMonitor: ObservableObject {
  static let shared = SystemResourceMonitor()

  /// Standing listeners stay up through "Release everything": stopping the
  /// hotkey would leave the user with no way to dictate. Each has its own button.
  static let releaseEverythingKinds: Set<SystemResourceKind> = Set(SystemResourceKind.allCases)
    .subtracting([.hotKey, .accessibility])

  @Published private(set) var holds: [SystemResourceHold] = []
  @Published private(set) var microphone: MicrophoneUseAttribution = .unknown

  let registry: SystemResourceRegistry
  private let probe: () -> Bool?
  private let logger = Logger(subsystem: "com.github.speakapp", category: "SystemResources")
  private var auditor = MicrophoneUseAuditor()
  private var observation: SystemResourceObservation?
  private var pollTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []
  private var adapterHolds: [String: SystemResourceToken] = [:]

  init(registry: SystemResourceRegistry = .shared, probe: @escaping () -> Bool? = MacMicrophoneProbe.isRunningInput) {
    self.registry = registry
    self.probe = probe
    self.holds = registry.holds
    self.observation = registry.observe { [weak self] holds in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.holds = holds
        self.sample()
      }
    }
  }

  /// Starts sampling the OS and the published owners. Safe to call twice.
  func start(environment: AppEnvironment) {
    guard self.pollTask == nil else { return }
    self.observeDictation(environment.main)
    self.observeHotKey(environment.hotKeys)
    self.observeSpeech(environment.tts)
    self.observeCompareModels(environment.compareModels)
    self.pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        self?.sample()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  var headline: String {
    if self.microphone.isUnattributed { return "Microphone open, not claimed by any feature" }
    return SystemResourceSummary.headline(for: self.holds)
  }

  var hasReleasableHolds: Bool {
    self.holds.contains { $0.isReleasable && Self.releaseEverythingKinds.contains($0.kind) }
  }

  func release(_ hold: SystemResourceHold) async {
    self.logger.info("User released \(hold.kind.rawValue, privacy: .public): \(hold.title, privacy: .public)")
    await self.registry.release(hold.id)
  }

  func releaseEverything() async {
    let count = await self.registry.releaseAll(kinds: Self.releaseEverythingKinds)
    self.logger.info("User released everything: \(count) holds")
    self.sample()
  }

  // MARK: - Microphone audit

  private func sample() {
    let result = self.auditor.observe(osReportsInput: self.probe(), holds: self.holds, at: Date())
    if result.attribution != self.microphone { self.microphone = result.attribution }
    if result.shouldReport {
      let holds = SystemResourceSummary.diagnostics(for: self.holds)
      self.logger.error("Microphone open with no registered owner. Holds: \(holds, privacy: .public)")
    }
  }

  // MARK: - Adapters for published state

  private func setHold(_ key: String, active: Bool, make: (SystemResourceRegistry) -> SystemResourceToken) {
    if active {
      if self.adapterHolds[key] == nil { self.adapterHolds[key] = make(self.registry) }
    } else {
      self.adapterHolds.removeValue(forKey: key)?.end()
    }
  }

  private func observeDictation(_ main: MainManager) {
    main.$state
      .map { $0 == .recording }
      .removeDuplicates()
      .sink { [weak self, weak main] recording in
        self?.setHold("dictation", active: recording) { registry in
          registry.acquire(
            kind: .microphone, title: "Dictation",
            reason: "Recording the dictation you started.", owner: "MainManager",
            releaseTitle: "Cancel recording",
            release: { await MainActor.run { main?.userRequestedStopDueToError() } }
          )
        }
      }
      .store(in: &self.cancellables)
  }

  private func observeHotKey(_ hotKeys: HotKeyManager) {
    hotKeys.$monitoringState
      .map { $0 == .active }
      .removeDuplicates()
      .sink { [weak self, weak hotKeys] active in
        self?.setHold("hotkey", active: active) { registry in
          registry.acquire(
            kind: .hotKey, title: "Dictation hotkey",
            reason: "Listens for your hotkey through a keyboard event tap. Nothing is recorded.",
            owner: "HotKeyManager", releaseTitle: "Pause hotkey",
            release: { await MainActor.run { hotKeys?.stopMonitoring() } }
          )
        }
      }
      .store(in: &self.cancellables)
  }

  private func observeSpeech(_ speech: TextToSpeechManager) {
    speech.$isPlaying
      .combineLatest(speech.$isSynthesizing)
      .map { $0 || $1 }
      .removeDuplicates()
      .sink { [weak self, weak speech] speaking in
        self?.setHold("speech", active: speaking) { registry in
          registry.acquire(
            kind: .audioOutput, title: "Speech playback",
            reason: "Reading text aloud.", owner: "TextToSpeechManager", releaseTitle: "Stop speaking",
            release: { await MainActor.run { speech?.stop() } }
          )
        }
      }
      .store(in: &self.cancellables)
  }

  private func observeCompareModels(_ compare: CompareModelsController) {
    compare.$phase
      .map { $0 == .starting || $0 == .streaming }
      .removeDuplicates()
      .sink { [weak self, weak compare] capturing in
        self?.setHold("compare", active: capturing) { registry in
          registry.acquire(
            kind: .microphone, title: "Compare Models recording",
            reason: "Streaming your voice to several models side by side. Stops itself after 10 minutes.",
            owner: "CompareModelsController", releaseTitle: "Stop comparing",
            release: { await compare?.cancelStreaming() }
          )
        }
      }
      .store(in: &self.cancellables)
  }
}
