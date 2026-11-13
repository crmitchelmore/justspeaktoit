#if os(iOS)
import Foundation
import UIKit

/// Names the running device in user-facing copy, so iPad never reads
/// "this iPhone" or promises a Dynamic Island it does not have (#1598).
///
/// `scripts/ios/check-device-copy.py` fails on new hard-coded "iPhone" or
/// "Dynamic Island" strings in `Sources/SpeakiOS`; route copy through here.
enum DeviceCopy {
    /// "iPhone", "iPad", "Mac" or "device".
    @MainActor static var name: String {
        name(for: UIDevice.current.userInterfaceIdiom, isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac)
    }

    /// "this iPhone", "this iPad", "this Mac" or "this device".
    @MainActor static var thisDevice: String { "this \(name)" }

    /// "your iPhone", "your iPad", "your Mac" or "your device".
    @MainActor static var yourDevice: String { "your \(name)" }

    /// Where a Live Activity appears, completing "Shows … ".
    @MainActor static var liveActivityPlacement: String {
        liveActivityPlacement(for: UIDevice.current.userInterfaceIdiom)
    }

    static func name(for idiom: UIUserInterfaceIdiom, isiOSAppOnMac: Bool = false) -> String {
        if isiOSAppOnMac { return "Mac" }
        switch idiom {
        case .phone: return "iPhone"
        case .pad: return "iPad"
        default: return "device"
        }
    }

    /// Only iPhones have a Dynamic Island, and not every iPhone, so the iPhone
    /// wording stays conditional rather than guessing from the model.
    static func liveActivityPlacement(for idiom: UIUserInterfaceIdiom) -> String {
        idiom == .phone
            ? "on the Lock Screen and, on supported iPhones, in the Dynamic Island"
            : "on the Lock Screen"
    }
}
#endif
