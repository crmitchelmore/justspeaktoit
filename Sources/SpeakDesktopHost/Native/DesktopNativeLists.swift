import Foundation
import SpeakCore
import SpeakDesktop

/// A native window page, numbered as `JSTI_PAGE_*` in both `CWindowsSupport`
/// and `CLinuxSupport`. The hosts' platform tests pin each raw value to its
/// C constant.
package enum DesktopNativePage: Int32, CaseIterable, Sendable {
    case dashboard = 0
    case history
    case voiceOutput
    case general
    case transcription
    case postProcessing
    case corrections
    case pronunciation
    case profiles
    case keyboard
    case cloudSync
    case about

    /// The page a settings search destination opens. Corrections and
    /// Pronunciation are sidebar pages of their own on both hosts.
    package init(_ destination: DesktopSettingsDestination) {
        switch destination {
        case .general: self = .general
        case .transcription: self = .transcription
        case .postProcessing: self = .postProcessing
        case .voiceOutput: self = .voiceOutput
        case .corrections: self = .corrections
        case .pronunciation: self = .pronunciation
        case .profiles: self = .profiles
        case .keyboard: self = .keyboard
        case .cloudSync: self = .cloudSync
        case .about: self = .about
        }
    }
}

/// Lists handed to a native window as C row arrays. Each host passes its C
/// module's row initializer and setter, so the row contents and string
/// lifetimes are defined once.
package enum DesktopNativeLists {
    package typealias CString = UnsafePointer<CChar>?

    /// The settings search box shows at most this many results.
    package static let maximumSettingsSearchResults = 50

    /// Builds one row per item with strings that outlive `call`, then passes the rows to it.
    package static func withRows<Item, Row, Result>(
        _ items: some Sequence<Item>, row: (Item, DesktopNativeStrings) -> Row,
        call: (UnsafePointer<Row>?, Int) -> Result
    ) -> Result {
        let strings = DesktopNativeStrings()
        let rows = items.map { row($0, strings) }
        return withExtendedLifetime(strings) { rows.withUnsafeBufferPointer { call($0.baseAddress, $0.count) } }
    }

    /// Shows the About page's details and links.
    package static func configureAbout<Link>(
        for platform: DesktopAboutInformation.Platform, link: (CString, CString) -> Link,
        configure: (CString, UnsafePointer<Link>?, Int) -> Int32
    ) throws {
        let details = DesktopAboutInformation.current().details(for: platform)
        let result = withRows(AppInformationLink.allCases, row: { item, strings in
            link(strings.add(item.title), strings.add(item.url.absoluteString))
        }, call: { links, count in configure(details, links, count) })
        guard result == 0 else {
            throw DesktopHostError(message: "The About information could not be configured.")
        }
    }

    /// Shows History's model filter rows and the selected filter; false when the window refused it.
    package static func historyFilters<Model>(
        models: [String], selection: DesktopHistoryFilter, model: (CString, CString, Int32) -> Model,
        set: (UnsafePointer<Model>?, Int, Int32, CString, CString) -> Int32
    ) -> Bool {
        withRows(models, row: { identifier, strings in
            model(
                strings.add(identifier), strings.add(DesktopHistorySearch.modelDisplayName(for: identifier)),
                selection.models.contains(identifier) ? 1 : 0
            )
        }, call: { rows, count in
            set(rows, count, selection.errorsOnly ? 1 : 0, selection.fromDay, selection.throughDay)
        }) == 0
    }

    /// Shows the first results of a settings search; false when the window refused them.
    package static func settingsSearchResults<Row>(
        _ results: [DesktopSettingsSearchSession.Row], row: (CString, CString, CString) -> Row,
        set: (UnsafePointer<Row>?, Int) -> Int32
    ) -> Bool {
        withRows(results.prefix(maximumSettingsSearchResults), row: { result, strings in
            row(strings.add(result.title), strings.add(result.detail), strings.add(result.identifier))
        }, call: set) == 0
    }

    /// The C callback that wraps a typed draft's selection in SSML markup:
    /// input, output, capacity, leading UTF-16 offset, leading scalar offset.
    package typealias MarkupWrap = @convention(c) (
        CString, UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?
    ) -> Int32

    /// Shows the SSML helper's canonical examples; false when the window refused them.
    package static func voiceMarkupHelper<Example>(
        enabled: Bool, example: (CString, CString) -> Example,
        set: (Int32, UnsafePointer<Example>?, Int, MarkupWrap?) -> Int32
    ) -> Bool {
        withRows(VoiceSynthesisMarkup.examples, row: { item, strings in
            example(strings.add(item.text), strings.add(item.description))
        }, call: { examples, count in
            set(enabled ? 1 : 0, examples, count) { input, output, capacity, utf16, scalars in
                VoiceSynthesisMarkup.writeWrappedText(
                    input, output: output, capacity: capacity, leadingUTF16: utf16, leadingScalars: scalars
                )
            }
        }) == 0
    }
}
