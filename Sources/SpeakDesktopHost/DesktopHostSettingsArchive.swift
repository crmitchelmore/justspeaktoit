import SpeakCore

/// Archive-only presence tracking: a model slot is projected only when it was
/// stored or explicitly chosen, never when catalogue preparation filled it.
extension DesktopHostController.Settings {
    package var archiveModel: String? { archiveModelKeys.contains("model") ? self.model : nil }
    package var archiveBatchModel: String? { archiveModelKeys.contains("batchModel") ? self.batchModel : nil }
    package var archiveLiveModel: String? { archiveModelKeys.contains("liveModel") ? self.liveModel : nil }
    package var archiveLocalModel: String? { archiveModelKeys.contains("localModel") ? self.localModel : nil }

    package mutating func preservingArchiveModelPresence<T>(_ update: (inout Self) throws -> T) rethrows -> T {
        let explicit = archiveModelKeys
        defer { archiveModelKeys = explicit }
        return try update(&self)
    }

    mutating func captureArchivePresence(_ all: [String: AnyCodable]) {
        archiveModelKeys = Set(all.keys).intersection(["model", "batchModel", "liveModel", "localModel"])
    }

    mutating func noteArchiveWrite<Value>(
        _ keyPath: WritableKeyPath<SettingsValues, Value>
    ) {
        if keyPath == \SettingsValues.model { archiveModelKeys.insert("model") }
        if keyPath == \SettingsValues.batchModel { archiveModelKeys.insert("batchModel") }
        if keyPath == \SettingsValues.liveModel { archiveModelKeys.insert("liveModel") }
        if keyPath == \SettingsValues.localModel { archiveModelKeys.insert("localModel") }
    }
}
