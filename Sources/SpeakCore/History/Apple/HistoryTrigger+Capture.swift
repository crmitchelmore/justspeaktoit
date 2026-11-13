import Foundation

extension ApplicationHistoryTrigger {
    /// Capture triggers the iPhone can observe, kept in the shared trigger shape
    /// so History stores and displays them like the Mac's hotkey gestures.
    public init(captureTrigger: CaptureTrigger) {
        switch captureTrigger {
        case .inApp:
            self.init(gesture: .uiButton, hotKeyDescription: "In-app button", outputMethod: .none)
        case .control:
            self.init(gesture: .automation, hotKeyDescription: "Control", outputMethod: .none)
        case .shortcut:
            self.init(gesture: .automation, hotKeyDescription: "Shortcut", outputMethod: .none)
        case .keyboard:
            self.init(gesture: .automation, hotKeyDescription: "Keyboard", outputMethod: .none)
        }
    }
}
