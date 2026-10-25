import ApplicationServices
import Foundation
import XCTest

@testable import SpeakApp

/// Models selected-text replacement without reading or modifying another app.
final class FakeStreamingTextField: StreamingTextField {
    var value: String
    var selection: CFRange
    var valueIsReadable = true
    var selectedRangeIsReadable = true
    var setSelectedRangeResult: AXError = .success
    var setSelectedTextResult: AXError = .success

    /// The range that was selected at the moment each replacement was attempted,
    /// with the text it tried to write. One entry per attempted AX write.
    private(set) var selectedTextWrites: [(range: CFRange, text: String)] = []
    private(set) var selectedRangeWrites: [CFRange] = []
    var onSelectionWrite: (() -> Void)?

    init(value: String = "", selection: CFRange = CFRange(location: 0, length: 0)) {
        self.value = value
        self.selection = selection
    }

    func readValue() -> String? {
        self.valueIsReadable ? self.value : nil
    }

    func readSelectedRange() -> CFRange? {
        self.selectedRangeIsReadable ? self.selection : nil
    }

    func setSelectedRange(_ range: CFRange) -> AXError {
        self.selectedRangeWrites.append(range)
        guard self.setSelectedRangeResult == .success else { return self.setSelectedRangeResult }
        self.selection = range
        onSelectionWrite?()
        return .success
    }

    func setSelectedText(_ text: String) -> AXError {
        self.selectedTextWrites.append((self.selection, text))
        guard self.setSelectedTextResult == .success else { return self.setSelectedTextResult }
        let current = self.value as NSString
        guard self.selection.location >= 0, self.selection.length >= 0,
              self.selection.location + self.selection.length <= current.length
        else { return .failure }
        self.value = current.replacingCharacters(
            in: NSRange(location: self.selection.location, length: self.selection.length),
            with: text
        )
        self.selection = CFRange(location: self.selection.location + text.utf16.count, length: 0)
        return .success
    }
}

enum LiveTextInserterTestFactory {
    @MainActor
    static func make(
        field: FakeStreamingTextField, policy: AppSettings.AppSwitchDelivery = .originalApp,
        strategy: LiveTextInserter.InsertionStrategy = .rangedStreaming
    ) -> LiveTextInserter {
        let defaults = UserDefaults(suiteName: "com.speakapp.tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.appSwitchDelivery = policy
        let inserter = LiveTextInserter(
            permissionsManager: PermissionsManager(statusProvider: { _ in .granted }),
            appSettings: settings
        )
        inserter.streamingFieldProvider = { field }
        inserter.streamingVerificationDelay = 0
        inserter.begin(
            target: TextOutputTarget(
                processIdentifier: 123,
                applicationName: "TextEdit",
                bundleIdentifier: "com.apple.TextEdit",
                applicationLaunchDate: nil,
                focusedElement: nil
            ),
            strategy: strategy
        )
        return inserter
    }

}
