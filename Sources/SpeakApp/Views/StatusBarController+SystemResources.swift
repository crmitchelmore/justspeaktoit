import AppKit
import Combine
import SpeakCore

// MARK: - System resources quick view (issue #1471)

extension StatusBarController {
  func observeSystemResources() {
    resources.$holds
      .combineLatest(resources.$microphone)
      .map { holds, microphone in holds.map { "\($0.id)\($0.isReleasing)" }.joined() + "\(microphone.isUnattributed)" }
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.refresh() }
      .store(in: &cancellables)
  }

  func addSystemResourceItems(to menu: NSMenu) {
    let headline = NSMenuItem(title: resources.headline, action: #selector(openSystemResources), keyEquivalent: "")
    headline.target = self
    headline.image = NSImage(
      systemSymbolName: resources.holds.contains { $0.kind == .microphone } || resources.microphone.isUnattributed
        ? "mic.fill" : "checkmark.circle",
      accessibilityDescription: nil
    )
    headline.setAccessibilityIdentifier("statusBarSystemResourcesItem")
    menu.addItem(headline)
    for hold in resources.holds {
      let duration = SystemResourceSummary.duration(since: hold.since)
      let item = NSMenuItem(title: "\(hold.title), \(duration)", action: nil, keyEquivalent: "")
      item.indentationLevel = 1
      item.toolTip = hold.reason
      if let releaseTitle = hold.releaseTitle {
        let submenu = NSMenu()
        let release = NSMenuItem(title: releaseTitle, action: #selector(releaseHold(_:)), keyEquivalent: "")
        release.target = self
        release.representedObject = hold.id
        release.isEnabled = !hold.isReleasing
        submenu.addItem(release)
        item.submenu = submenu
      } else {
        item.isEnabled = false
      }
      menu.addItem(item)
    }
    if resources.hasReleasableHolds || resources.microphone.isUnattributed {
      let releaseAll = NSMenuItem(
        title: "Release Everything", action: #selector(releaseEverything), keyEquivalent: ""
      )
      releaseAll.target = self
      releaseAll.setAccessibilityIdentifier("statusBarReleaseEverythingItem")
      menu.addItem(releaseAll)
    }
  }

  @objc func openSystemResources() {
    openStatus()
  }

  @objc func releaseHold(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID,
          let hold = resources.holds.first(where: { $0.id == id }) else { return }
    Task { await resources.release(hold) }
  }

  @objc func releaseEverything() {
    Task { await resources.releaseEverything() }
  }
}
