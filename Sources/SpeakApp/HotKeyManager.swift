import AppKit
import Foundation
import SpeakHotKeys
import os.log

/// Bridges SpeakHotKeys.HotKeyGesture to the app-level type used by MainManager.
typealias HotKeyGesture = SpeakHotKeys.HotKeyGesture

enum KeyboardShortcut: Hashable {
case commandR
case escape

var keyCode: UInt16 {
switch self {
case .commandR:
return 15  // R key
case .escape:
return 53  // Escape key
}
}

var requiredModifiers: NSEvent.ModifierFlags {
switch self {
case .commandR:
return .command
case .escape:
return []
}
}
}

typealias HotKeyListenerToken = SpeakHotKeys.HotKeyListenerToken

struct ShortcutListenerToken: Hashable {
fileprivate let id: UUID
fileprivate let shortcut: KeyboardShortcut
}

/// Thin wrapper over `HotKeyEngine` that preserves the existing app-level API.
///
/// Manages permissions, keyboard shortcuts (⌘R, Escape), and delegates
/// gesture detection to the SpeakHotKeys library engine.
@MainActor
final class HotKeyManager: ObservableObject {
private let permissionsManager: PermissionsManager
private let appSettings: AppSettings
private let log = Logger(subsystem: "com.github.speakapp", category: "HotKeyManager")

/// The underlying engine from SpeakHotKeys library.
let engine: HotKeyEngine

private var shortcutListeners: [KeyboardShortcut: [UUID: () -> Void]] = [:]
private var globalMonitor: Any?
private var localMonitor: Any?

init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
self.permissionsManager = permissionsManager
self.appSettings = appSettings
self.engine = HotKeyEngine(
configuration: HotKeyConfiguration(
holdThreshold: appSettings.holdThreshold,
doubleTapWindow: appSettings.doubleTapWindow
)
)
}

func startMonitoring() {
guard !engine.isMonitoring else { return }

Task { [weak self] in
guard let self else { return }
for permission in [PermissionType.accessibility, .inputMonitoring] {
let status = await MainActor.run { self.permissionsManager.status(for: permission) }
if !status.isGranted {
_ = await self.permissionsManager.request(permission)
}
}
}

// Keyboard shortcut monitors (⌘R, Escape)
globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) {
[weak self] event in
self?.handleKeyboardShortcuts(event: event)
}
localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
[weak self] event in
self?.handleKeyboardShortcuts(event: event)
return event
}

// Start the hotkey engine with the current binding
let hotKey = appSettings.selectedHotKey
engine.updateConfiguration(
HotKeyConfiguration(
holdThreshold: appSettings.holdThreshold,
doubleTapWindow: appSettings.doubleTapWindow
)
)
engine.start(for: hotKey)
}

func stopMonitoring() {
if let globalMonitor {
NSEvent.removeMonitor(globalMonitor)
self.globalMonitor = nil
}
if let localMonitor {
NSEvent.removeMonitor(localMonitor)
self.localMonitor = nil
}
engine.stop()
}

/// Restart monitoring with the current hotkey from settings.
func restartWithCurrentHotKey() {
let wasMonitoring = engine.isMonitoring
engine.stop()
if wasMonitoring {
let hotKey = appSettings.selectedHotKey
engine.updateConfiguration(
HotKeyConfiguration(
holdThreshold: appSettings.holdThreshold,
doubleTapWindow: appSettings.doubleTapWindow
)
)
engine.start(for: hotKey)
}
}

@discardableResult
func register(gesture: HotKeyGesture, handler: @escaping () -> Void) -> HotKeyListenerToken {
engine.register(gesture: gesture, handler: handler)
}

func unregister(_ token: HotKeyListenerToken) {
engine.unregister(token)
}

@discardableResult
func register(shortcut: KeyboardShortcut, handler: @escaping () -> Void) -> ShortcutListenerToken {
let identifier = UUID()
var handlers = shortcutListeners[shortcut, default: [:]]
handlers[identifier] = handler
shortcutListeners[shortcut] = handlers
return ShortcutListenerToken(id: identifier, shortcut: shortcut)
}

func unregister(_ token: ShortcutListenerToken) {
shortcutListeners[token.shortcut]?[token.id] = nil
}

func updateTiming(holdThreshold: TimeInterval, doubleTapWindow: TimeInterval) {
appSettings.holdThreshold = holdThreshold
appSettings.doubleTapWindow = doubleTapWindow
engine.updateConfiguration(
HotKeyConfiguration(holdThreshold: holdThreshold, doubleTapWindow: doubleTapWindow)
)
}

private func handleKeyboardShortcuts(event: NSEvent) {
for (shortcut, handlers) in shortcutListeners {
let modifiersMatch = event.modifierFlags.contains(shortcut.requiredModifiers)
let keyCodeMatch = event.keyCode == shortcut.keyCode
if modifiersMatch && keyCodeMatch {
log.debug("Firing keyboard shortcut: \(String(describing: shortcut))")
handlers.values.forEach { $0() }
}
}
}
}
