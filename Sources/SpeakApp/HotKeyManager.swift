import AppKit
import Combine
import CoreGraphics
import Foundation
import SpeakCore
import SpeakHotKeys
import os.log

/// Bridges SpeakHotKeys.HotKeyGesture to the app-level type used by MainManager.
typealias HotKeyGesture = SpeakHotKeys.HotKeyGesture

typealias HotKeyListenerToken = SpeakHotKeys.HotKeyListenerToken

struct ShortcutListenerToken: Hashable {
	fileprivate let id: UUID
	fileprivate let shortcut: KeyboardShortcut
}

/// Thin wrapper over `HotKeyEngine` that preserves the existing app-level API.
///
/// Manages permissions, keyboard shortcuts (⌘R, Escape), and delegates
/// gesture detection to the SpeakHotKeys library engine.
///
/// Keyboard shortcuts are delivered on the app-local monitor for the whole time monitoring
/// is on. The system-wide monitor is separate and short-lived: it exists only while
/// something has registered a `GlobalEscapeReason`, and it only ever fires shortcuts that
/// declare `deliveredGlobally`. So while Speak is idle it is not reading key presses in
/// other apps at all, rather than reading them and discarding them in a handler guard.
@MainActor
final class HotKeyManager: ObservableObject {
	@Published private(set) var monitoringState: HotKeyMonitoringState = .stopped

	private let permissionsManager: PermissionsManager
	private let appSettings: AppSettings
	private let eventMonitoring: KeyEventMonitoring
	private let log = SpeakLogger.logger(category: "HotKeyManager")

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
	private var globalEscapeReasons: Set<GlobalEscapeReason> = []
	private var recordingStateCancellable: AnyCancellable?

	init(
		permissionsManager: PermissionsManager,
		appSettings: AppSettings,
		eventMonitoring: KeyEventMonitoring = NSEventKeyMonitoring()
	) {
		self.permissionsManager = permissionsManager
		self.appSettings = appSettings
		self.eventMonitoring = eventMonitoring
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
		// A monitor outlives the object that installed it, so leaving one behind would keep
		// an orphaned handler on the process-wide event stream.
		if let globalMonitor {
			eventMonitoring.removeMonitor(globalMonitor)
		}
		if let localMonitor {
			eventMonitoring.removeMonitor(localMonitor)
		}
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
		guard !engine.isMonitoring, localMonitor == nil else {
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

		// Every keyboard shortcut (⌘R, Escape) is reachable while Speak is the active app.
		// The system-wide half is installed separately and only while something needs it —
		// see `updateGlobalEscapeMonitor`.
		localMonitor = eventMonitoring.addLocalMonitor(matching: [.keyDown]) { [weak self] event in
			self?.handleKeyboardShortcuts(event: event, scope: .local)
			return event
		}
		updateGlobalEscapeMonitor()

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
		cancelScheduledRecovery()
		permissionRequestTask?.cancel()
		permissionRequestTask = nil
		monitoringRequested = false
		tearDownMonitoring()
		monitoringState = .stopped
	}

	private func tearDownMonitoring() {
		if let globalMonitor {
			eventMonitoring.removeMonitor(globalMonitor)
			self.globalMonitor = nil
		}
		if let localMonitor {
			eventMonitoring.removeMonitor(localMonitor)
			self.localMonitor = nil
		}
		engine.stop()
	}

	/// Tears the engine down and rearms it with the current binding.
	///
	/// A hold that is in progress ends with a balanced `holdEnd`, so a recording
	/// that started on hold never survives the reconnect.
	func reconnectMonitoring() {
		cancelScheduledRecovery()
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
		cancelScheduledRecovery()
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

	/// Rearms monitoring a moment after a lifecycle event.
	///
	/// Only the newest request may rearm. A manual reconnect or a binding change
	/// cancels a pending recovery, so a stale lifecycle event cannot reset a newer
	/// detector.
	private func scheduleRecovery(reason: String) {
		guard monitoringRequested else { return }
		recoveryTask?.cancel()
		recoveryTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(500))
			guard !Task.isCancelled, let self, self.monitoringRequested else { return }
			self.recoveryTask = nil
			self.log.info("Rearming global hotkey after \(reason, privacy: .public)")
			self.reconnectMonitoring()
		}
	}

	private func cancelScheduledRecovery() {
		recoveryTask?.cancel()
		recoveryTask = nil
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

	/// Which monitor an event arrived on, which decides what it is allowed to fire.
	private enum ShortcutScope {
		case global
		case local
	}

	private func handleKeyboardShortcuts(event: NSEvent, scope: ShortcutScope) {
		for (shortcut, handlers) in shortcutListeners {
			guard scope == .local || shortcut.deliveredGlobally else { continue }
			let modifiersMatch = event.modifierFlags.contains(shortcut.requiredModifiers)
			let keyCodeMatch = event.keyCode == shortcut.keyCode
			if modifiersMatch && keyCodeMatch {
				log.debug("Firing keyboard shortcut: \(String(describing: shortcut))")
				handlers.values.forEach { $0() }
			}
		}
	}
}

// MARK: - Lifecycle observers

/// Rearming after the events that silently invalidate a monitor: app activation, wake and
/// session unlock.
extension HotKeyManager {
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

// MARK: - System-wide Escape

/// The system-wide monitor's lifecycle.
///
/// It is installed only while something has a live reason to cancel, so an idle Speak reads
/// no key presses in other apps at all.
extension HotKeyManager {
	/// Follows a recording-state publisher so the system-wide Escape listener exists for
	/// exactly as long as there is a recording to cancel.
	///
	/// The sink lives here rather than at the call site so the monitor's lifetime cannot
	/// drift away from the state that justifies it.
	func trackRecordingState(_ publisher: some Publisher<Bool, Never>) {
		recordingStateCancellable = publisher
			.removeDuplicates()
			.sink { [weak self] isRecording in
				// `@Published` fires synchronously on the actor that mutated it, and every
				// mutation of the recording state is already on the main actor.
				MainActor.assumeIsolated {
					self?.setGlobalEscapeNeeded(isRecording, for: .recording)
				}
			}
	}

	/// Adds or drops one reason for the system-wide Escape listener.
	func setGlobalEscapeNeeded(_ needed: Bool, for reason: GlobalEscapeReason) {
		let changed =
			needed
			? globalEscapeReasons.insert(reason).inserted
			: globalEscapeReasons.remove(reason) != nil
		guard changed else { return }
		updateGlobalEscapeMonitor()
	}

	/// Installs the system-wide key-down monitor while something needs Escape and removes it
	/// as soon as nothing does.
	///
	/// Idempotent in both directions, so a burst of transitions cannot stack monitors: a
	/// second `NSEvent` monitor would deliver every key press twice and leak, because only
	/// one token is remembered.
	private func updateGlobalEscapeMonitor() {
		let shouldListen = monitoringRequested && !globalEscapeReasons.isEmpty
		if shouldListen {
			guard globalMonitor == nil else { return }
			globalMonitor = eventMonitoring.addGlobalMonitor(matching: [.keyDown]) { [weak self] event in
				self?.handleKeyboardShortcuts(event: event, scope: .global)
			}
		} else if let globalMonitor {
			eventMonitoring.removeMonitor(globalMonitor)
			self.globalMonitor = nil
		}
	}
}
