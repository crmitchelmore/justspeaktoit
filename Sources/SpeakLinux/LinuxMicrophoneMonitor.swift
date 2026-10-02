import Foundation
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

    init(controller: LinuxAppController) { self.controller = controller }

    func start() throws {
        try LinuxNative.call {
            jsti_audio_device_monitor_start(linuxMicrophonesChanged, Unmanaged.passUnretained(self).toOpaque(), $0, $1)
        }
        lock.withLock { running = true }
    }

    /// No refresh is scheduled after this returns.
    func stop() {
        jsti_audio_device_monitor_stop()
        lock.withLock { running = false }
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
            try? await Task.sleep(nanoseconds: 250_000_000)
            lock.withLock { scheduled = false }
            guard lock.withLock({ running }) else { return }
            _ = LinuxWindow.configureMicrophones(selected: await controller.selectedMicrophone(), synthetic: false)
        }
    }
}

private func linuxMicrophonesChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<LinuxMicrophoneMonitor>.fromOpaque(context).takeUnretainedValue().changed()
}
