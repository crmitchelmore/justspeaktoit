import SwiftUI
import UIKit

/// The globe key. A `UIButton` because only UIKit hands the touch event to
/// `handleInputModeList(from:with:)`, which shows the keyboard list on a long
/// press and advances on a tap.
struct InputModeSwitchButton: UIViewRepresentable {
    let action: (UIButton, UIEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "Next keyboard"
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handle(_:event:)),
            for: .allTouchEvents
        )
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}

    final class Coordinator: NSObject {
        let action: (UIButton, UIEvent) -> Void

        init(action: @escaping (UIButton, UIEvent) -> Void) {
            self.action = action
        }

        @objc func handle(_ sender: UIButton, event: UIEvent) {
            action(sender, event)
        }
    }
}
