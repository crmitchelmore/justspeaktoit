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

/// Bridges the hotkey engine and app-local shortcuts. Global Escape monitoring
/// exists only while dictation or Voice Edit has a reason to cancel.
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
	private var activationRecoveryPending = false
	private var keyReleaseToken: HotKeyPressListenerToken?
	private var permissionRequestTask: Task<Void, Never>?
	private var globalEscapeReasons: Set<GlobalEscapeReason> = []
	private var recordingStateCancellable: AnyCancellable?
	private var isRecording = false

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
		keyReleaseToken = engine.registerPress { [weak self] event in
			guard event.phase == .released else { return }
			// The edge precedes holdEnd; reconcile after the detector finishes it.
			Task { @MainActor in self?.resumeDeferredActivationRecovery() }
		}
		registerLifecycleObservers()
	}

	deinit {
		recoveryTask?.cancel()
		permissionRequestTask?.cancel()
		// Monitors outlive their owner unless explicitly removed.
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

    func startMonitoring(requestPermission: Bool = true) {
        monitoringRequested = true
        installMonitoring(requestPermission: requestPermission)
    }

	private func installMonitoring(requestPermission: Bool) {
		guard !engine.isMonitoring, localMonitor == nil else {
			refreshMonitoringState()
			return
		}

		if requestPermission && appSettings.hasConfiguredGlobalHotKey {
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

		// App-local shortcuts stay available independently of global Escape.
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
		if appSettings.hasConfiguredGlobalHotKey { engine.start(for: hotKey) }
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

	/// Rearms the binding, balancing any active hold with holdEnd.
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
			if appSettings.hasConfiguredGlobalHotKey { engine.start(for: hotKey) }
			refreshMonitoringState()
		}
	}

	private func refreshMonitoringState() {
		guard monitoringRequested, appSettings.hasConfiguredGlobalHotKey else {
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

	private var captureBlocksActivationRecovery: Bool {
		isRecording || engine.isKeyDown || engine.gestureDetector.isHoldInProgress
			|| globalEscapeReasons.contains(.voiceEdit)
	}

	/// Only the newest lifecycle recovery may rearm; explicit changes retire it.
	private func scheduleRecovery(reason: String, preservesActiveCapture: Bool = false) {
		guard monitoringRequested else { return }
		recoveryTask?.cancel()
		activationRecoveryPending = false
		recoveryTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: .milliseconds(500))
			guard !Task.isCancelled, let self, self.monitoringRequested else { return }
			self.recoveryTask = nil
			// Reconnecting emits holdEnd, so defer activation until capture ends.
			if preservesActiveCapture, self.captureBlocksActivationRecovery {
				self.activationRecoveryPending = true
				return
			}
			self.log.info("Rearming global hotkey after \(reason, privacy: .public)")
			self.reconnectMonitoring()
		}
	}

	private func resumeDeferredActivationRecovery() {
		guard activationRecoveryPending, !captureBlocksActivationRecovery else { return }
		scheduleRecovery(reason: "deferred app activation", preservesActiveCapture: true)
	}

	private func cancelScheduledRecovery() {
		recoveryTask?.cancel()
		recoveryTask = nil
		activationRecoveryPending = false
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
		// Exact match, not `contains`: `contains` made ⌘R fire on ⌃⌘R and ⇧⌘R too. Escape
		// opts out and matches whatever is held — see `ignoresModifiers`.
		let pressedModifiers = event.modifierFlags.intersection(KeyboardShortcut.trackedModifiers)
		for (shortcut, handlers) in shortcutListeners {
			guard scope == .local || shortcut.deliveredGlobally else { continue }
			let modifiersMatch =
				shortcut.ignoresModifiers
				|| pressedModifiers
					== shortcut.requiredModifiers.intersection(KeyboardShortcut.trackedModifiers)
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
					self?.scheduleRecovery(reason: "app activation", preservesActiveCapture: true)
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

/// An idle Speak reads no key presses in other apps.
extension HotKeyManager {
	/// Keeps recording state and the Escape listener in sync with the cancellation preference.
	func trackRecordingState(_ publisher: some Publisher<Bool, Never>) {
		recordingStateCancellable = publisher
			.removeDuplicates()
			.combineLatest(appSettings.$cancelRecordingOnEscape.removeDuplicates())
			.sink { [weak self] isRecording, cancelOnEscape in
				// Recording and preference changes are main-actor mutations.
				MainActor.assumeIsolated {
					guard let self else { return }
					self.isRecording = isRecording
					self.setGlobalEscapeNeeded(isRecording && cancelOnEscape, for: .recording)
					self.resumeDeferredActivationRecovery()
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
		resumeDeferredActivationRecovery()
	}

	/// Installs exactly one system-wide Escape monitor while needed, removing it when idle.
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
