import AppKit
import Combine

@MainActor
final class StatusBarController {
  private let statusItem: NSStatusItem
  private let openMainWindow: () -> Void
  private let appSettings: AppSettings
  private let historyManager: HistoryManager
  private let mainManager: MainManager

  private var cancellables: Set<AnyCancellable> = []

  init(
    appSettings: AppSettings,
    historyManager: HistoryManager,
    mainManager: MainManager,
    openMainWindow: @escaping () -> Void
  ) {
    self.appSettings = appSettings
    self.historyManager = historyManager
    self.mainManager = mainManager
    self.openMainWindow = openMainWindow

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "waveform", accessibilityDescription: "Speak")
    statusItem.button?.imagePosition = .imageLeading
    statusItem.button?.appearsDisabled = false
    statusItem.menu = buildMenu()

    observeChanges()
  }

  private func observeChanges() {
    appSettings.$transcriptionMode
      .combineLatest(appSettings.$postProcessingEnabled, appSettings.$textOutputMethod)
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.refresh()
      }
      .store(in: &cancellables)

    historyManager.$statistics
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.refresh()
      }
      .store(in: &cancellables)

    mainManager.$state
      .receive(on: RunLoop.main)
      .sink { [weak self] state in
        self?.updateButton(for: state)
        self?.refresh()
      }
      .store(in: &cancellables)
  }

  private func refresh() {
    statusItem.menu = buildMenu()
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()

    let headline = NSMenuItem()
    headline.title = "Speak"
    headline.isEnabled = false
    menu.addItem(headline)

    let modelItem = NSMenuItem()
    modelItem.title = "Mode: \(appSettings.transcriptionMode.displayName)"
    modelItem.isEnabled = false
    menu.addItem(modelItem)

    let postProcess = NSMenuItem()
    postProcess.title =
      appSettings.postProcessingEnabled
      ? "Post-processing: Enabled" : "Post-processing: Disabled"
    postProcess.isEnabled = false
    menu.addItem(postProcess)

    let outputItem = NSMenuItem()
    outputItem.title = "Output: \(appSettings.textOutputMethod.displayName)"
    outputItem.isEnabled = false
    menu.addItem(outputItem)

    menu.addItem(.separator())

    let stats = historyManager.statistics
    let totalItem = NSMenuItem()
    totalItem.title = "Sessions: \(stats.totalSessions)"
    totalItem.isEnabled = false
    menu.addItem(totalItem)

    let durationItem = NSMenuItem()
    let minutes = Int(stats.cumulativeRecordingDuration / 60)
    let seconds = Int(stats.cumulativeRecordingDuration) % 60
    durationItem.title = "Time Recorded: \(minutes)m \(seconds)s"
    durationItem.isEnabled = false
    menu.addItem(durationItem)

    let spendItem = NSMenuItem()
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    let spendText = formatter.string(from: stats.totalSpend as NSDecimalNumber) ?? "$0.00"
    spendItem.title = "Spend: \(spendText)"
    spendItem.isEnabled = false
    menu.addItem(spendItem)

    menu.addItem(.separator())

    let toggleItem = NSMenuItem(
      title: mainManagerActionTitle,
      action: #selector(toggleRecording),
      keyEquivalent: ""
    )
    toggleItem.target = self
    menu.addItem(toggleItem)

    let openItem = NSMenuItem(
      title: "Open Speak…",
      action: #selector(openApp),
      keyEquivalent: ""
    )
    openItem.target = self
    menu.addItem(openItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(
      title: "Quit",
      action: #selector(quitApp),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)

    return menu
  }

  private var mainManagerActionTitle: String {
    switch mainManager.state {
    case .idle, .completed(_), .failed(_):
      return "Start Recording"
    case .recording:
      return "Stop Recording"
    case .processing, .delivering:
      return "Finishing…"
    }
  }

  private func updateButton(for state: MainManager.State) {
    switch state {
    case .idle:
      statusItem.button?.title = "Speak"
    case .completed(_):
      statusItem.button?.title = "Speak"
    case .recording:
      statusItem.button?.title = "Recording…"
    case .processing:
      statusItem.button?.title = "Transcribing…"
    case .delivering:
      statusItem.button?.title = "Delivering…"
    case .failed(_):
      statusItem.button?.title = "Needs Attention"
    }
  }

  @objc private func toggleRecording() {
    if case .processing = mainManager.state { return }
    if case .delivering = mainManager.state { return }
    mainManager.toggleRecordingFromUI()
  }

  @objc private func openApp() {
    openMainWindow()
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }
}
// @Implement: This file should provide the UI for the status bar. It should briefly show the core settings of the app (which model we're currently using and if we're using post-processing). To open the main window of the app.What is the current insert method, and what are brief stats from recordings?
// StatusBarController hosts an NSStatusItem with dynamic menu reflecting recording & processing state.
