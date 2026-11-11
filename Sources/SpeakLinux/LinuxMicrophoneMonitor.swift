import Foundation
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// Refreshes the microphone list when the sound server reports a source or
/// default change. Bursts coalesce into one enumeration off the audio thread;
/// the saved choice (or its "unavailable" row) is kept, and a recording keeps
/// the device it started with.
final class LinuxMicrophoneMonitor: @unchecked Sendable {
    private let controller: LinuxAppController
    private let lock = NSLock()
    private var scheduled = false
    private var running = false
    private var callbacks: NativeCallbackContext<LinuxMicrophoneMonitor>?

    init(controller: LinuxAppController) { self.controller = controller }

    func start() throws {
        let callbacks = NativeCallbackContext(self)
        do {
            try LinuxNative.call { jsti_audio_device_monitor_start(linuxMicrophonesChanged, callbacks.pointer, $0, $1) }
        } catch {
            callbacks.release()
            throw error
        }
        lock.withLock {
            self.callbacks = callbacks
            running = true
        }
    }

    /// No refresh is scheduled after this returns.
    func stop() {
        // No native callback runs once the monitor has stopped.
        jsti_audio_device_monitor_stop()
        let callbacks = lock.withLock {
            running = false
            defer { self.callbacks = nil }
            return self.callbacks
        }
        callbacks?.release()
    }

    fileprivate func changed() {
        let schedule = lock.withLock { () -> Bool in
            guard running, !scheduled else { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        let controller = controller
        Task.detached { [self] in
            await controller.connectionWarmEnvironmentChanged()
            try? await Task.sleep(nanoseconds: 250_000_000)
            lock.withLock { scheduled = false }
            guard lock.withLock({ running }) else { return }
            let warning = LinuxWindow.configureMicrophones(
                selected: await controller.selectedMicrophone(), synthetic: false
            )
            await controller.setMicrophoneWarning(warning)
        }
    }
}

private func linuxMicrophonesChanged(_ context: UnsafeMutableRawPointer?) {
    NativeCallbackContext<LinuxMicrophoneMonitor>.resolve(context)?.changed()
}
