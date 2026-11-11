import Foundation
import SpeakCore
import SpeakDesktop

/// The Windows and Linux side of "System resources in use" (issue #1473): one
/// monitor and one conversion to C rows. Each platform supplies only its
/// microphone probe and the C structs its window header declares.
package enum DesktopNativeSystemResources {
    /// One row's strings, borrowed from a `DesktopNativeStrings` arena.
    package struct Row {
        package let id: UnsafePointer<CChar>
        package let title: UnsafePointer<CChar>
        package let reason: UnsafePointer<CChar>
        package let caption: UnsafePointer<CChar>
        /// nil when the hold has no release button.
        package let releaseTitle: UnsafePointer<CChar>?
        package let releasing: Int32
    }

    /// The card's strings, borrowed from the same arena as its rows.
    package struct View {
        package let headline: UnsafePointer<CChar>
        package let warning: UnsafePointer<CChar>?
        package let empty: UnsafePointer<CChar>
        package let microphone: UnsafePointer<CChar>
        package let canReleaseEverything: Int32
    }

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

    /// Converts `presentation` to native rows and hands them to `present`. Every
    /// pointer stays valid until `present` returns, and no longer.
    package static func withNative<NativeRow>(
        _ presentation: DesktopSystemResources.Presentation,
        row makeRow: (Row) -> NativeRow,
        present body: (View, UnsafeBufferPointer<NativeRow>) -> Void
    ) {
        let strings = DesktopNativeStrings()
        let rows = presentation.rows.map { row in
            makeRow(Row(
                id: strings.add(row.id), title: strings.add(row.title), reason: strings.add(row.reason),
                caption: strings.add(row.caption), releaseTitle: row.releaseTitle.map(strings.add),
                releasing: row.releasing ? 1 : 0
            ))
        }
        let view = View(
            headline: strings.add(presentation.headline), warning: presentation.warning.map(strings.add),
            empty: strings.add(presentation.empty), microphone: strings.add(presentation.microphone),
            canReleaseEverything: presentation.canReleaseEverything ? 1 : 0
        )
        withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { body(view, $0) }
        }
    }
}
