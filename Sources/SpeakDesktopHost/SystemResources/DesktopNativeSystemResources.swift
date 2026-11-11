import Foundation
import SpeakCore
import SpeakDesktop

/// The Windows and Linux side of "System resources in use" (issue #1473): one
/// monitor and one conversion to C rows. Each platform supplies only its
/// microphone probe and the C structs its window header declares.
package enum DesktopNativeSystemResources {
    package typealias Text = UnsafePointer<CChar>?

    /// `capturing` is the native probe: 1 when this process records from the
    /// microphone, 0 when it does not, anything else when the OS cannot say.
    package static func monitor(
        osName: String,
        capturing: @escaping @Sendable () -> Int32,
        show: @escaping @Sendable (DesktopSystemResources.Presentation) -> Void
    ) -> DesktopSystemResourcesMonitor {
        DesktopSystemResourcesMonitor(
            osName: osName,
            probe: { microphoneOpen(capturing()) },
            publish: show,
            report: log
        )
    }

    package static func microphoneOpen(_ capturing: Int32) -> Bool? {
        switch capturing {
        case 1: true
        case 0: false
        default: nil
        }
    }

    package static func log(_ line: String) {
        FileHandle.standardError.write(Data("System resources: \(line)\n".utf8))
    }

    /// Hands `presentation` to the window as the platform's C structs, built by
    /// their memberwise initialisers: a row is (id, title, reason, caption,
    /// release title or nil, releasing) and the card is (headline, warning or
    /// nil, empty, microphone, rows, row count, can release everything).
    /// Every string lives until `set` returns.
    package static func show<NativeRow, NativeView>(
        _ presentation: DesktopSystemResources.Presentation,
        row: (Text, Text, Text, Text, Text, Int32) -> NativeRow,
        view: (Text, Text, Text, Text, UnsafePointer<NativeRow>?, Int32, Int32) -> NativeView,
        set: (UnsafePointer<NativeView>?) -> Int32
    ) {
        let strings = DesktopNativeStrings()
        let rows = presentation.rows.map {
            row(
                strings.add($0.id), strings.add($0.title), strings.add($0.reason), strings.add($0.caption),
                $0.releaseTitle.map(strings.add), $0.releasing ? 1 : 0
            )
        }
        withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { buffer in
                var card = view(
                    strings.add(presentation.headline), presentation.warning.map(strings.add),
                    strings.add(presentation.empty), strings.add(presentation.microphone),
                    buffer.baseAddress, Int32(buffer.count), presentation.canReleaseEverything ? 1 : 0
                )
                _ = set(&card)
            }
        }
    }
}
