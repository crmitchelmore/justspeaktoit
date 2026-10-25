import CLinuxSupport
import SpeakDesktopHost

func linuxCancelOperation(_ value: String, holder: LinuxEventContext) {
    let controller = holder.controller
    if value.isEmpty {
        Task { await controller.cancelTranscription() }
        return
    }
    guard let token = UInt64(value), token & 1 == 1 else {
        LinuxHostPlatform.update("Linux supplied an invalid Escape cancellation token.")
        return
    }
    Task {
        await controller.cancelTranscription(fromEscape: true, ifCurrent: {
            jsti_window_escape_is_current(token) == 1
        })
    }
}
