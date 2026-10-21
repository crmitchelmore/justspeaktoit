import CWindowsSupport
import SpeakDesktopHost

extension WindowsHostPlatform {
    package static func voiceEditEscape(_ active: Bool) {
        if jsti_window_set_voice_edit_escape(active ? 1 : 0) != 0 {
            update("Could not apply Voice Edit Escape cancellation.", transcript: nil, state: -1)
        }
    }
}

func windowsCancelOperation(_ value: String, holder: WindowsEventContext) {
    let controller = holder.controller
    if value.isEmpty {
        Task { await controller.cancelTranscription() }
        return
    }
    guard let token = UInt64(value), token & 1 == 1 else {
        WindowsHostPlatform.update(
            "Windows supplied an invalid Escape cancellation token.", transcript: nil, state: -1
        )
        return
    }
    Task {
        await controller.cancelTranscription(fromEscape: true, ifCurrent: {
            jsti_window_global_escape_is_current(token) == 1
        })
    }
}
