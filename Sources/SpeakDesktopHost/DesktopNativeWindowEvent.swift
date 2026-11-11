import Foundation

/// A window event both native windows report with the same number. Raw
/// values are the `JSTI_EVENT_*` constants in `CWindowsSupport` and
/// `CLinuxSupport`; the hosts' platform tests pin each one to its C constant,
/// so this enum documents the shared event ABI without changing it.
package enum DesktopNativeWindowEvent: Int32, CaseIterable, Sendable {
    case toggleRecording = 1      // text: microphone ID; index: model slot
    case importAudio = 2          // text: path; index: model slot
    case copyTranscript = 3       // text: selected record ID, or empty
    case saveCredential = 4       // text: key; index: model slot
    case selectModel = 5          // index: model slot
    case closing = 6
    case ready = 7
    case selectHistory = 9        // text: record ID
    case retryHistory = 10        // text: record ID
    case exportHistory = 11       // text: record ID (Windows) or destination path (Linux)
    case openHistoryAudio = 12    // text: record ID
    case selectMicrophone = 13    // text: microphone ID
    case cancel = 14
    case searchHistory = 15       // text: query
    case transcriptVersion = 16   // text: record ID
    case playbackToggle = 18      // text: record ID
    case playbackStop = 19
    case refreshModels = 20
    case shortcutDown = 21        // text: microphone ID; index: model slot
    case shortcutUp = 22
    case vocabularyAction = 70    // index: vocabulary kind
    case vocabularyLoad = 71      // index: vocabulary kind
    case vocabularyRecording = 72 // a selected recording's correction snapshot
    case historyFilters = 90      // text: DesktopHistoryFilter JSON
    case historyDelete = 91       // text: newline-separated UUIDs; index: 1 removes owned audio
    case recordingsFolder = 93
    case audioCleanup = 94
    case audioCleanupResponse = 95       // text: confirmation UUID; index: 1 confirms
    case migrationExport = 96            // text: ZIP destination; index: option bits
    case migrationInspect = 97           // text: ZIP source
    case migrationRestore = 98           // text: ZIP source
    case migrationRestoreResponse = 99   // text: preview token; index: choice
    case quickVoice = 110
    case pasteLastHistory = 111
    case speakClipboard = 113
    case speechPause = 116
    case userAbsent = 131
    case historyIssueReport = 150        // text: History UUID
    case issueReportInclude = 151        // text: preview ticket; index: included
    case issueReportCopy = 152
    case issueReportSave = 153
    case issueReportOpen = 154
    case issueReportClose = 155
    case historyLoadMore = 156
    case settingsSearch = 160            // text: query
    case settingsSearchOpen = 161        // index: chosen row

    /// Issue report preview actions that carry a preview ticket.
    package var isIssueReportAction: Bool { (151...155).contains(rawValue) }
}

/// Window events only the Windows window reports.
package enum DesktopNativeWindowsEvent: Int32, CaseIterable, Sendable {
    case error = 8
    case profiles = 17
    case hotKeyDeadline = 23
    case readAloud = 24           // text: record ID
    case automation = 25          // text: "1" allows automation
    case appearance = 26          // text: "0" system, "1" light, "2" dark
    case loginItem = 27           // text: "1" on
    case speakSelectedText = 112
    case voiceEdit = 114
}

/// Window events only the Linux window reports.
package enum DesktopNativeLinuxEvent: Int32, CaseIterable, Sendable {
    case textOutput = 30          // index: method; text: options
    case commandToggle = 31       // --toggle from another process or action
    case shortcutStyle = 32       // index: activation style
    case postProcessing = 33
    case azureResource = 34
    case readAloud = 40           // text: record ID
    case voiceOutput = 41         // index: position in the voice list
    case appearance = 45          // index: 0 system, 1 light, 2 dark
    case loginItem = 46           // index: 1 on
    case automation = 47          // index: 1 allows automation
    case localModelDownload = 50
    case localModelCancel = 51
    case localModelRemove = 52
    case localModelGPU = 53
    case localModelImport = 54    // text: owner/repo newline GGML basename
    case localModelImportCancel = 55
    case cloudSyncApply = 60      // index: option bits; text: passphrase
    case cloudSyncSignIn = 61
    case cloudSyncSignOut = 62
    case cloudSyncNow = 63
    /// Shares 98 with `DesktopNativeWindowEvent.migrationRestore`, which
    /// decodes first, so the window's New recordings folder choice cannot
    /// reach the host until the native constant is renumbered.
    case recordingsLocation = 98
    case actionShortcutEdit = 115
    case apiKeys = 117
    case permissions = 118
    case speakSelectedText = 130
    case profiles = 140
}

/// One decoded window event: shared, host-only, a comparison window event
/// (100-109 and 120-129, forwarded unchanged), or a number this build does
/// not know, which the host ignores rather than guessing at.
package enum DesktopNativeWindowEventCode<HostEvent: RawRepresentable>: Sendable
where HostEvent.RawValue == Int32, HostEvent: Sendable {
    case shared(DesktopNativeWindowEvent)
    case host(HostEvent)
    case comparison(Int32)
    case unknown(Int32)

    package init(_ raw: Int32) {
        if Self.isComparison(raw) {
            self = .comparison(raw)
        } else if let shared = DesktopNativeWindowEvent(rawValue: raw) {
            self = .shared(shared)
        } else if let host = HostEvent(rawValue: raw) {
            self = .host(host)
        } else {
            self = .unknown(raw)
        }
    }

    package static func isComparison(_ raw: Int32) -> Bool { (100...109).contains(raw) || (120...129).contains(raw) }

    /// The number the window sent.
    package var rawValue: Int32 {
        switch self {
        case .shared(let event): return event.rawValue
        case .host(let event): return event.rawValue
        case .comparison(let raw), .unknown(let raw): return raw
        }
    }
}

extension DesktopNativeWindowEventCode: Equatable where HostEvent: Equatable {}
