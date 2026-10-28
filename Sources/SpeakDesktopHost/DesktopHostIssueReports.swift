import Foundation
import SpeakCore
import SpeakDesktop

/// Only generated allowlisted artifacts cross the native preview boundary.
package struct DesktopHostIssueReportPreview: Sendable {
    package let ticket: UUID
    package let report: IssueDiagnosticReport
    package let includesDiagnostics: Bool
    package let isExporting: Bool
    package let status: DesktopHostIssueReportStatus?
}

package enum DesktopHostIssueReportStatus: Equatable, Sendable {
    case copied, exported, opened, copyFailed, exportFailed, browserFailed, browserUnavailable

    package var message: String {
        switch self {
        case .copied: return "Draft copied."
        case .exported: return "Diagnostics saved. Attach the JSON yourself in GitHub."
        case .opened: return "GitHub opened. Nothing has been attached or submitted."
        case .copyFailed: return "Could not copy the draft. Try saving the JSON instead."
        case .exportFailed: return "Could not save diagnostics. Try another destination."
        case .browserFailed: return "Could not open GitHub. You can copy the draft instead."
        case .browserUnavailable: return "This draft cannot fit in a browser link. Copy it into a new GitHub issue."
        }
    }
}

package enum DesktopHostIssueReportExportOutcome: Equatable, Sendable {
    case saved, retiredAfterAdmission, cancelled, failed, unavailable
}

/// Hosts install these only when their native preview is implemented. Construction has no effects.
package struct DesktopHostIssueReportActions: Sendable {
    package let present: @Sendable (DesktopHostIssueReportPreview) -> Bool
    package let dismiss: @Sendable (UUID) -> Void
    package let chooseDestination: @Sendable (String) async -> URL?
    package let copy: @Sendable (String) throws -> Void
    package let open: @Sendable (URL) -> Bool

    package init(
        present: @escaping @Sendable (DesktopHostIssueReportPreview) -> Bool,
        dismiss: @escaping @Sendable (UUID) -> Void,
        chooseDestination: @escaping @Sendable (String) async -> URL?,
        copy: @escaping @Sendable (String) throws -> Void,
        open: @escaping @Sendable (URL) -> Bool
    ) {
        self.present = present
        self.dismiss = dismiss
        self.chooseDestination = chooseDestination
        self.copy = copy
        self.open = open
    }
}

/// The lock covers only admission state, never actor suspension or filesystem I/O.
final class DesktopHostIssueReportExportLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var admitted = false

    func retire() { lock.withLock { active = false } }

    func admit() -> Bool {
        lock.withLock {
            guard active, !admitted else { return false }
            admitted = true
            return true
        }
    }
}

struct DesktopHostIssueReportSession: Sendable {
    let ticket = UUID()
    let full: IssueDiagnosticReport
    let removed: IssueDiagnosticReport
    let actions: DesktopHostIssueReportActions
    var includesDiagnostics = true
    var exportLease: DesktopHostIssueReportExportLease?
    var status: DesktopHostIssueReportStatus?

    init(record: DesktopRecordingStore.Record, actions: DesktopHostIssueReportActions) {
        let models = [record.modelIdentifier, record.postProcessingModelIdentifier].compactMap { $0 }
            .map { RequestDiagnosticContext.ModelSelection.project($0) }
        var failures: [RequestDiagnosticContext.Failure] = []
        if record.failure != nil { failures.append(.init(stage: .request, domain: .unknown)) }
        if record.postProcessingFailure != nil { failures.append(.init(stage: .postProcessing, domain: .unknown)) }
        // Native desktop records have no canonical request slots. Never reconstruct
        // them from current settings, result payloads or opaque migration metadata.
        full = IssueDiagnosticReport(recordedModels: models, failures: failures)
        removed = IssueDiagnosticReport(omittedSections: Set(IssueDiagnosticReport.Section.allCases))
        self.actions = actions
    }

    var preview: DesktopHostIssueReportPreview {
        .init(ticket: ticket, report: includesDiagnostics ? full : removed,
              includesDiagnostics: includesDiagnostics, isExporting: exportLease != nil, status: status)
    }
}

extension DesktopHostController {
    /// Actual native adapters remain unavailable until their platform installs actions.
    @discardableResult
    package func beginIssueReport(_ identifier: String) -> UUID? {
        beginIssueReport(identifier, using: Platform.issueReportActions)
    }

    /// The same owner/admission path accepts owned effects in portable tests.
    @discardableResult
    func beginIssueReport(_ identifier: String, using actions: DesktopHostIssueReportActions?) -> UUID? {
        retireIssueReport()
        guard canUseHistory, !Task.isCancelled, let id = UUID(uuidString: identifier),
              selectedHistoryID == id, isVisible(id), let record = history[id] else { return nil }
        guard let actions else {
            update("Issue report preview is unavailable on this host.")
            return nil
        }
        let session = DesktopHostIssueReportSession(record: record, actions: actions)
        issueReportSession = session
        guard actions.present(session.preview) else {
            retireIssueReport()
            update("Issue report preview is unavailable on this host.")
            return nil
        }
        return session.ticket
    }

    package func setIssueReportIncludesDiagnostics(_ included: Bool, ticket: UUID) {
        guard !closed, !Task.isCancelled, issueReportSession?.ticket == ticket,
              issueReportSession?.exportLease == nil else { return }
        issueReportSession?.includesDiagnostics = included
        issueReportSession?.status = nil
        publishIssueReport(ticket)
    }

    package func cancelIssueReport(_ ticket: UUID) {
        guard issueReportSession?.ticket == ticket else { return }
        retireIssueReport()
    }

    func retireIssueReport() {
        guard let session = issueReportSession else { return }
        issueReportSession = nil
        session.exportLease?.retire()
        session.actions.dismiss(session.ticket)
    }

    package func copyIssueReport(_ ticket: UUID) {
        guard !closed, !Task.isCancelled, let session = issueReportSession, session.ticket == ticket else { return }
        do {
            try session.actions.copy(session.preview.report.body)
            issueReportSession?.status = .copied
        } catch { issueReportSession?.status = .copyFailed }
        publishIssueReport(ticket)
    }

    package func openIssueReport(_ ticket: UUID) {
        guard !closed, !Task.isCancelled, let session = issueReportSession, session.ticket == ticket else { return }
        guard let url = session.preview.report.issueURL, Self.isIssueDraftURL(url) else {
            issueReportSession?.status = .browserUnavailable
            publishIssueReport(ticket)
            return
        }
        issueReportSession?.status = session.actions.open(url) ? .opened : .browserFailed
        publishIssueReport(ticket)
    }

    @discardableResult
    package func exportIssueReport(_ ticket: UUID) async -> DesktopHostIssueReportExportOutcome {
        guard !closed, !Task.isCancelled, let session = issueReportSession, session.ticket == ticket,
              session.exportLease == nil else { return Task.isCancelled ? .cancelled : .unavailable }
        let lease = DesktopHostIssueReportExportLease()
        let json = session.preview.report.jsonString
        issueReportSession?.exportLease = lease
        publishIssueReport(ticket)
        defer {
            lease.retire()
            if issueReportSession?.ticket == ticket {
                issueReportSession?.exportLease = nil
                publishIssueReport(ticket)
            }
        }
        return await withTaskCancellationHandler {
            guard !closed, !Task.isCancelled, issueReportSession?.ticket == ticket else { return .cancelled }
            guard let destination = await session.actions.chooseDestination(IssueDiagnosticReport.attachmentFilename),
                  !closed, !Task.isCancelled, issueReportSession?.ticket == ticket else { return .cancelled }
            do {
                // The store preserves its canonical History/audio path refusal.
                // Retirement before admission refuses a queued write; an atomic
                // write already admitted may finish and cannot be recalled.
                let saved = try await store.exportTranscriptSnapshot(
                    json, to: destination, admitting: { lease.admit() })
                guard saved else { return .cancelled }
                guard !closed, !Task.isCancelled, issueReportSession?.ticket == ticket else {
                    return .retiredAfterAdmission
                }
                issueReportSession?.status = .exported
                return .saved
            } catch {
                guard !closed, !Task.isCancelled, issueReportSession?.ticket == ticket else { return .cancelled }
                issueReportSession?.status = .exportFailed
                return .failed
            }
        } onCancel: { lease.retire() }
    }

    private func publishIssueReport(_ ticket: UUID) {
        guard !closed, let session = issueReportSession, session.ticket == ticket else { return }
        if !session.actions.present(session.preview) { retireIssueReport() }
    }

    private static func isIssueDraftURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.host == "github.com" && parts.port == nil
            && parts.user == nil && parts.password == nil && parts.fragment == nil
            && parts.path == "/crmitchelmore/justspeaktoit/issues/new"
    }
}
