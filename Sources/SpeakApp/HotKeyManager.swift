import AppKit
import CoreGraphics
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

enum HotKeyMonitoringState: Equatable {
	case stopped
	case active
	case inputMonitoringRequired
	case registrationFailed

	var displayName: String {
		switch self {
		case .stopped:
			return "Stopped"
		case .active:
			return "Active"
		case .inputMonitoringRequired:
			return "Needs Input Monitoring"
		case .registrationFailed:
			return "Reconnect Required"
		}
	}
}

/// Thin wrapper over `HotKeyEngine` that preserves the existing app-level API.
///
/// Manages permissions, keyboard shortcuts (⌘R, Escape), and delegates
/// gesture detection to the SpeakHotKeys library engine.
@MainActor
final class HotKeyManager: ObservableObject {
	@Published private(set) var monitoringState: HotKeyMonitoringState = .stopped

	private let permissionsManager: PermissionsManager
	private let appSettings: AppSettings
	private let log = Logger(subsystem: "com.github.speakapp", category: "HotKeyManager")

	/// The underlying engine from SpeakHotKeys library.
	let engine: HotKeyEngine

	private var shortcutListeners: [KeyboardShortcut: [UUID: () -> Void]] = [:]
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private var lifecycleObservers: [NSObjectProtocol] = []
	private var workspaceLifecycleObservers: [NSObjectProtocol] = []
	private var wasMonitoringBeforeRecording = false
	private var monitoringRequested = false
	private var recoveryTask: Task<Void, Never>?
	private var permissionRequestTask: Task<Void, Never>?

	init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
		self.permissionsManager = permissionsManager
		self.appSettings = appSettings
		self.engine = HotKeyEngine(
			configuration: HotKeyConfiguration(
				holdThreshold: appSettings.holdThreshold,
				doubleTapWindow: appSettings.doubleTapWindow
			)
		)
		registerLifecycleObservers()
	}

	deinit {
		recoveryTask?.cancel()
		permissionRequestTask?.cancel()
		for observer in lifecycleObservers {
			NotificationCenter.default.removeObserver(observer)
		}
		for observer in workspaceLifecycleObservers {
			NSWorkspace.shared.notificationCenter.removeObserver(observer)
		}
	}

	func startMonitoring() {
		monitoringRequested = true
		installMonitoring(requestPermission: true)
	}

	private func installMonitoring(requestPermission: Bool) {
		guard !engine.isMonitoring, globalMonitor == nil, localMonitor == nil else {
			refreshMonitoringState()
			return
		}

		if requestPermission {
			permissionRequestTask?.cancel()
			permissionRequestTask = Task { [weak self] in
				guard let self else { return }
				for permission in [PermissionType.inputMonitoring] {
					let status = await MainActor.run { self.permissionsManager.status(for: permission) }
					if !status.isGranted {
						_ = await self.permissionsManager.request(permission)
					}
					guard !Task.isCancelled else { return }
				}
				await MainActor.run {
					guard !Task.isCancelled, self.monitoringRequested else { return }
					if self.appSettings.selectedHotKey == .fnKey {
						self.reconnectMonitoring()
					} else {
						self.refreshMonitoringState()
					}
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
		refreshMonitoringState()
	}

	func stopMonitoring() {
		permissionRequestTask?.cancel()
		permissionRequestTask = nil
		monitoringRequested = false
		tearDownMonitoring()
		monitoringState = .stopped
	}

	private func tearDownMonitoring() {
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

	func reconnectMonitoring() {
		guard monitoringRequested else {
			startMonitoring()
			return
		}
		tearDownMonitoring()
		installMonitoring(requestPermission: false)
	}

	func pauseForHotKeyRecording() {
		wasMonitoringBeforeRecording = engine.isMonitoring || globalMonitor != nil || localMonitor != nil
		stopMonitoring()
	}

	func resumeAfterHotKeyRecording() {
		guard wasMonitoringBeforeRecording else { return }
		wasMonitoringBeforeRecording = false
		startMonitoring()
	}

	/// Restart monitoring with the current hotkey from settings.
	func restartWithCurrentHotKey() {
		let shouldRestart = monitoringRequested
		engine.stop()
		if shouldRestart {
			let hotKey = appSettings.selectedHotKey
			engine.updateConfiguration(
				HotKeyConfiguration(
					holdThreshold: appSettings.holdThreshold,
					doubleTapWindow: appSettings.doubleTapWindow
				)
			)
			engine.start(for: hotKey)
			refreshMonitoringState()
		}
	}

	private func refreshMonitoringState() {
		guard monitoringRequested else {
			monitoringState = .stopped
			return
		}
		if appSettings.selectedHotKey == .fnKey, !CGPreflightListenEventAccess() {
			monitoringState = .inputMonitoringRequired
			return
		}
		guard engine.isMonitoring else {
			monitoringState = .registrationFailed
			return
		}
		monitoringState = .active
	}

	private func scheduleRecovery(reason: String) {
		guard monitoringRequested else { return }
		recoveryTask?.cancel()
		recoveryTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(500))
			guard !Task.isCancelled, let self, self.monitoringRequested else { return }
			self.log.info("Rearming global hotkey after \(reason, privacy: .public)")
			self.reconnectMonitoring()
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

	private func registerLifecycleObservers() {
		let center = NotificationCenter.default
		lifecycleObservers = [
			center.addObserver(forName: .speakHotKeyShouldPause, object: nil, queue: .main) { [weak self] _ in
				Task { @MainActor in
					self?.pauseForHotKeyRecording()
				}
			},
			center.addObserver(forName: .speakHotKeyDidChange, object: nil, queue: .main) { [weak self] _ in
				Task { @MainActor in
					self?.resumeAfterHotKeyRecording()
				}
			},
			center.addObserver(
				forName: NSApplication.didBecomeActiveNotification,
				object: nil,
				queue: .main
			) { [weak self] _ in
				Task { @MainActor in
					self?.scheduleRecovery(reason: "app activation")
				}
			}
		]

		let workspaceCenter = NSWorkspace.shared.notificationCenter
		workspaceLifecycleObservers = [
			workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
				Task { @MainActor in
					self?.scheduleRecovery(reason: "system wake")
				}
			},
			workspaceCenter.addObserver(
				forName: NSWorkspace.sessionDidBecomeActiveNotification,
				object: nil,
				queue: .main
			) { [weak self] _ in
				Task { @MainActor in
					self?.scheduleRecovery(reason: "session unlock")
				}
			}
		]
	}
}
