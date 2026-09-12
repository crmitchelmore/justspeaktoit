import AppKit
import Foundation

// The vocabulary of `HotKeyManager`'s key-event monitoring: which shortcuts exist, why the
// system-wide listener is up, what state monitoring is in, and the seam it all goes through.

enum KeyboardShortcut: Hashable, CaseIterable {
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

	/// Escape cancels whatever else is held down.
	///
	/// The recording hotkey can itself be a modifier chord (⌥Space, say), and a hold keeps
	/// that chord physically down for the whole recording, so the Escape that cancels it
	/// arrives carrying ⌥. Matching Escape against an empty modifier set would never fire.
	var ignoresModifiers: Bool {
		switch self {
		case .escape:
			return true
		case .commandR:
			return false
		}
	}

	/// The modifiers a shortcut may specify. Both sides of a match are clamped to these, so
	/// a case that returned an untracked flag could not silently never fire.
	static let trackedModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

	/// Whether a key press in another app may fire this shortcut.
	///
	/// Escape has to: the point of dictation is that you are typing into somebody else's
	/// window, so the key that cancels it arrives there. ⌘R only retries the post-processing
	/// of a finished session, which is an app-context action — it stays on the local monitor
	/// so ⌘R keeps meaning reload in Safari and run in Xcode.
	var deliveredGlobally: Bool {
		switch self {
		case .commandR:
			return false
		case .escape:
			return true
		}
	}
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

/// Why the system-wide Escape listener is needed right now.
///
/// Escape is only ever a cancel, so outside a live capture there is nothing for it to
/// cancel and no reason to be reading every key press in every app.
enum GlobalEscapeReason: Hashable {
	/// A dictation recording is running.
	case recording
	/// A voice edit is in flight; its Escape also has to arrive from the app being edited.
	case voiceEdit
}

/// The `NSEvent` monitor calls `HotKeyManager` makes, behind a seam.
///
/// `NSEvent`'s monitor API is static and needs a real event stream, so without this a test
/// cannot see whether the system-wide monitor is installed.
protocol KeyEventMonitoring: AnyObject {
	func addGlobalMonitor(
		matching mask: NSEvent.EventTypeMask,
		handler: @escaping (NSEvent) -> Void
	) -> Any?
	func addLocalMonitor(
		matching mask: NSEvent.EventTypeMask,
		handler: @escaping (NSEvent) -> NSEvent?
	) -> Any?
	func removeMonitor(_ monitor: Any)
}

/// The production implementation: AppKit's process-wide event monitors.
final class NSEventKeyMonitoring: KeyEventMonitoring {
	func addGlobalMonitor(
		matching mask: NSEvent.EventTypeMask,
		handler: @escaping (NSEvent) -> Void
	) -> Any? {
		NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
	}

	func addLocalMonitor(
		matching mask: NSEvent.EventTypeMask,
		handler: @escaping (NSEvent) -> NSEvent?
	) -> Any? {
		NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
	}

	func removeMonitor(_ monitor: Any) {
		NSEvent.removeMonitor(monitor)
	}
}
