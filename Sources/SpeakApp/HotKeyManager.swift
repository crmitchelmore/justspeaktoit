// @Implement this file should manage when hockey events are received and trigger the action functions.
// It's also responsible for configuring what the actual hotkey we're looking for is to app settings.
// Callers should be able to add themselves as  hotkey listeners, and recieve 4 types of events: held, released, single tap, double tap and the timings for those should be read from app settings. Also this file should set those timeings to app settings when asked to.
// This file should also check for accessibility permissions and if not present, call out to the permissions manager to request them.

/* @Context: Tracks a single managed key (Fn) and emits four gestures: singleTap, doubleTap, holdStart, holdEnd.
	•	Provides a handler registry: multiple callbacks per (key, gesture).
	•	Implements recording UX semantics:
	•	holdStart → start
	•	holdEnd → stop
	•	doubleTap toggles start/stop only for sessions that were started by a double-tap (single tap can stop that too).
	•	Works globally via a CGEvent tap and survives temporary tap disables (auto-reenables).
	•	Has fallbacks when Fn isn’t seen by CGEvent:
	•	Global NSEvent monitors (flagsChanged, keyDown, keyUp)
	•	A lightweight poller that samples NSEvent.modifierFlags at ~200 ms to catch state drift.
	•	Exposes tunables:
	•	holdThreshold (default ~350 ms)
	•	doubleTapWindow (default ~400 ms)
	•	Ships with timestamped debug logging.

How the gestures are derived (behavioural rules)
	•	On first down: arm a timer for holdThreshold. If still down when it fires → emit holdStart (once).
	•	On up:
	•	If a hold happened → emit holdEnd.
	•	Else, compare to last up:
	•	If now - lastUp <= doubleTapWindow → doubleTap.
	•	Else → singleTap and update lastUp.

Permissions & environment (macOS specifics)
	•	Needs Accessibility and Input Monitoring for reliable global capture.
	•	CGEvent tap is .listenOnly at .cghidEventTap / .headInsertEventTap so it doesn’t interfere with normal input.
	•	Fn is a weird modifier:
	•	On some keyboards/OS versions it does not appear in CGEvent flags consistently.
	•	Sometimes Fn only shows up during other keypresses, or only via NSEvent.modifierFlags.
	•	Hence the layered fallbacks.

Fallback strategy (why it exists)
	•	Global NSEvent monitors: catch Fn as .function in modifierFlags on flagsChanged/keyDown/keyUp.
	•	Polling every ~200 ms: detect silent transitions or missed edges by sampling NSEvent.modifierFlags.
	•	Fallbacks are always-on when starting, then CGEvent tap is attempted; both can co-exist safely.

State & race-proofing (gotchas)
	•	Use a single source of truth for “is Fn down” to avoid double-firing when both tap and monitors fire.
	•	Debounce double-tap with the last-up timestamp; reset it on a confirmed double-tap.
	•	holdStart must only fire once per press; guard with a holdFired flag.
	•	Timers & threads: gesture firing and logs are marshalled to the main queue to avoid UI races.
	•	Tap disabled events (tapDisabledByTimeout / tapDisabledByUserInput) happen; re-enable the tap.
	•	Don’t assume CGEvent flags use the same bit for Fn as NSEvent (.maskSecondaryFn vs .function).
	•	Listen-only taps won’t consume events (good), but they still need permissions and a runloop source.
	•	Polling can see stale modifierFlags; that’s why it’s only used as a heuristic to reconcile state changes.
	•	Beware sleep/wake, Fast User Switching, or Mission Control: taps can die; schedule retries.

Timing knobs (practical defaults)
	•	holdThreshold: 300–400 ms (350 ms sweet spot).
	•	doubleTapWindow: 300–500 ms (start at 400 ms).
	•	pollInterval: 150–250 ms if you enable a poller (200 ms is a good compromise; faster = more CPU).

Integration contract (what another app needs, not your internals)
	•	API shape to mirror:
	•	register(key: ManagedKey, gesture: Gesture, handler: () -> Void)
	•	startMonitoring() / stopMonitoring()
	•	Expose holdThreshold / doubleTapWindow as settings.
	•	Usage pattern:
	•	On app start → startMonitoring()
	•	Register handlers (e.g., start/stop recording, show UI, etc.).
	•	Show a clear permissions checklist if tap creation fails; prompt user to enable Accessibility/Input Monitoring, then allow manual retry.

Edge cases to test (don’t skip these)
	•	Quick taps near the doubleTapWindow boundary (both sides).
	•	Holding slightly shorter than holdThreshold (should not fire hold).
	•	Holding slightly longer than holdThreshold (must fire hold once).
	•	Double-tap followed by single tap → should stop a double-tap-started session.
	•	Fn held while pressing other keys (does detection stay stable?).
	•	After sleep/wake and after toggling permissions in Settings.
	•	External keyboards vs built-in; different layouts.

Minimal diagnostics another team should implement
	•	Timestamped log entries for: tap creation, tap disabled/reenabled, each gesture fired, fallback activations, and permission failures.
	•	A small on-screen indicator (or status item) that lights up on Fn down for sanity checks.

If you want, I can turn this into a short README snippet or a checklist you can drop into their repo. */
import AppKit
import Foundation
import os.log

enum HotKeyGesture: String, CaseIterable, Identifiable {
	case holdStart
	case holdEnd
	case singleTap
	case doubleTap

	var id: String { rawValue }
}

struct HotKeyListenerToken: Hashable {
	fileprivate let id: UUID
	fileprivate let gesture: HotKeyGesture
}

// swiftlint:disable:next type_body_length
@MainActor
final class HotKeyManager: ObservableObject {
	private let permissionsManager: PermissionsManager
	private let appSettings: AppSettings
	private let log = Logger(subsystem: "com.github.speakapp", category: "HotKeyManager")

	private var listeners: [HotKeyGesture: [UUID: () -> Void]] = [:]
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private var holdTimer: DispatchSourceTimer?
	private var pollTimer: Timer?
	private var pendingSingleTapWorkItem: DispatchWorkItem?

	private var isKeyDown = false
	private var holdFired = false
	private var lastReleaseUptime: TimeInterval = 0

	private let pollInterval: TimeInterval = 0.2

	init(permissionsManager: PermissionsManager, appSettings: AppSettings) {
		self.permissionsManager = permissionsManager
		self.appSettings = appSettings
	}

	func startMonitoring() {
		guard globalMonitor == nil else { return }

		Task { [weak self] in
			guard let self else { return }
			for permission in [PermissionType.accessibility, .inputMonitoring] {
				let status = await MainActor.run { self.permissionsManager.status(for: permission) }
				if !status.isGranted {
					_ = await self.permissionsManager.request(permission)
				}
			}
		}

		globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
			[weak self] event in
			self?.handle(event: event)
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) {
			[weak self] event in
			self?.handle(event: event)
			return event
		}

		pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
			[weak self] _ in
			guard let self else { return }
			Task { @MainActor in
				self.pollModifierFlags()
			}
		}
		if let pollTimer {
			RunLoop.main.add(pollTimer, forMode: .common)
		}
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
		holdTimer?.cancel()
		holdTimer = nil
		pollTimer?.invalidate()
		pollTimer = nil
		pendingSingleTapWorkItem?.cancel()
		pendingSingleTapWorkItem = nil
		isKeyDown = false
		holdFired = false
	}

	@discardableResult
	func register(gesture: HotKeyGesture, handler: @escaping () -> Void) -> HotKeyListenerToken {
		let identifier = UUID()
		var handlers = listeners[gesture, default: [:]]
		handlers[identifier] = handler
		listeners[gesture] = handlers
		return HotKeyListenerToken(id: identifier, gesture: gesture)
	}

	func unregister(_ token: HotKeyListenerToken) {
		listeners[token.gesture]?[token.id] = nil
	}

	func updateTiming(holdThreshold: TimeInterval, doubleTapWindow: TimeInterval) {
		appSettings.holdThreshold = holdThreshold
		appSettings.doubleTapWindow = doubleTapWindow
	}

	private func handle(event: NSEvent) {
		guard event.modifierFlags.contains(.function) else {
			if isKeyDown {
				handleKeyRelease(source: "event")
			}
			return
		}

		switch event.type {
		case .flagsChanged, .keyDown:
			handleKeyPress(source: "event")
		case .keyUp:
			handleKeyRelease(source: "event")
		default:
			break
		}
	}

	private func pollModifierFlags() {
		let flags = NSEvent.modifierFlags
		if flags.contains(.function) {
			handleKeyPress(source: "poll")
		} else if isKeyDown {
			handleKeyRelease(source: "poll")
		}
	}

	private func handleKeyPress(source: StaticString) {
		guard !isKeyDown else { return }
		log.debug("Fn down via \(source)")
		isKeyDown = true
		holdFired = false
		pendingSingleTapWorkItem?.cancel()
		scheduleHoldTimer()
	}

	private func handleKeyRelease(source: StaticString) {
		guard isKeyDown else { return }
		log.debug("Fn up via \(source)")
		isKeyDown = false
		holdTimer?.cancel()
		holdTimer = nil

		let now = ProcessInfo.processInfo.systemUptime
		if holdFired {
			holdFired = false
			fire(.holdEnd)
			lastReleaseUptime = now
			return
		}

		let elapsed = now - lastReleaseUptime
		if elapsed <= appSettings.doubleTapWindow {
			pendingSingleTapWorkItem?.cancel()
			pendingSingleTapWorkItem = nil
			fire(.doubleTap)
			lastReleaseUptime = 0
		} else {
			let workItem = DispatchWorkItem { [weak self] in
				self?.fire(.singleTap)
			}
			pendingSingleTapWorkItem = workItem
			DispatchQueue.main.asyncAfter(deadline: .now() + appSettings.doubleTapWindow) {
				[weak workItem] in
				guard let workItem, !workItem.isCancelled else { return }
				workItem.perform()
			}
			lastReleaseUptime = now
		}
	}

	private func scheduleHoldTimer() {
		let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
		timer.schedule(deadline: .now() + appSettings.holdThreshold)
		timer.setEventHandler { [weak self] in
			guard let self, self.isKeyDown, !self.holdFired else { return }
			self.holdFired = true
			self.fire(.holdStart)
		}
		holdTimer = timer
		timer.resume()
	}

	private func fire(_ gesture: HotKeyGesture) {
		log.debug("Firing gesture: \(gesture.rawValue)")
		listeners[gesture]?.values.forEach { handler in
			handler()
		}
	}
}
