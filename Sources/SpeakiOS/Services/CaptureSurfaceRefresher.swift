#if os(iOS)
import WidgetKit
#endif

/// Identifies the existing installed control in both the app and extension.
public enum CaptureSurfaceKind {
    public static let transcriptionControl = "com.justspeaktoit.ios.JustSpeakToItWidgetExtension"
}

enum CaptureSurfaceRefresher {
    static func reloadRecordingControl(ofKind kind: String) {
        #if os(iOS)
        if #available(iOS 18, *) {
            ControlCenter.shared.reloadControls(ofKind: kind)
        }
        #endif
    }
}
