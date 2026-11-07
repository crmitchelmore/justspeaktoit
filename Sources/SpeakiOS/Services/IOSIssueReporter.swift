#if os(iOS)
import Combine
import Foundation
import SpeakCore
import UIKit

/// History uses stored safe request values; legacy facts stay unknown.
/// Live failures can instead supply an already frozen, run-owned safe snapshot.
enum IOSIssueReporter {
    static func snapshot(for item: iOSHistoryItem) -> IOSIssueReportSnapshot {
        var failures = item.requestFailure.map { [$0] } ?? []
        // Legacy error presence may describe another phase. Keep both facts;
        // these bounded observations can overlap and are not request counts.
        if item.errorMessage != nil { failures.append(.init(domain: .unknown)) }
        return IOSIssueReportSnapshot(
            context: item.requestContext, recordedModels: [.project(item.model)], observedHandoff: nil,
            failures: failures
        )
    }

    static func failedRequest() -> IOSIssueReportSnapshot {
        IOSIssueReportSnapshot(hasFailure: true)
    }
}

struct IOSIssueReportSnapshot {
    let full: IssueDiagnosticReport
    let withoutDetails: IssueDiagnosticReport

    init(hasFailure: Bool, recordedModels: [RequestDiagnosticContext.ModelSelection] = []) {
        self.init(context: nil, recordedModels: recordedModels, observedHandoff: nil,
                  requestFailure: hasFailure ? .init(domain: .unknown) : nil)
    }

    init(
        context: RequestDiagnosticContext?, recordedModels: [RequestDiagnosticContext.ModelSelection] = [],
        observedHandoff: RequestDiagnosticContext?, requestFailure: RequestDiagnosticContext.Failure?
    ) {
        self.init(context: context, recordedModels: recordedModels, observedHandoff: observedHandoff,
                  failures: requestFailure.map { [$0] } ?? [])
    }

    init(
        context: RequestDiagnosticContext?, recordedModels: [RequestDiagnosticContext.ModelSelection] = [],
        observedHandoff: RequestDiagnosticContext?, failures: [RequestDiagnosticContext.Failure]
    ) {
        self.full = IssueDiagnosticReport(
            context: context, recordedModels: recordedModels, failures: failures, observedHandoff: observedHandoff
        )
        self.withoutDetails = IssueDiagnosticReport(
            context: context, recordedModels: recordedModels, failures: failures,
            omittedSections: Set(IssueDiagnosticReport.Section.allCases), observedHandoff: observedHandoff
        )
    }
}

/// Pure projection of values already consumed by this run. No settings, errors,
/// credentials, provider strings, request text or reverse locale mapping enter it.
enum IOSRequestDiagnosticProjection {
    static func admission(
        _ configuration: EffectiveCaptureConfiguration, keyboardProfile: Bool
    ) -> RequestDiagnosticContext {
        let origin: RequestDiagnosticContext.Origin
        if keyboardProfile || configuration.modelOrigin != configuration.languageOrigin
            || configuration.modelOrigin != configuration.destinationOrigin {
            origin = .unknown
        } else {
            switch configuration.modelOrigin {
            case .global: origin = .global
            case .focus: origin = .focusOverride
            case .explicit: origin = .explicitOverride
            }
        }
        let destination: RequestDiagnosticContext.Destination
        switch HardwareTriggerDestination(rawValue: configuration.destinationID) {
        case .historyOnly: destination = .history
        case .clipboard, .clipboardAndPostProcess: destination = .clipboard
        case .auto, .none: destination = .unknown
        }
        return RequestDiagnosticContext(
            model: .project(configuration.modelID), mode: configuration.usesBatch ? .batch : .live,
            origin: origin, language: .project(configuration.languageIdentifier), destination: destination
        )
    }

    static func foreground(modelID: String) -> RequestDiagnosticContext {
        // Only this selected value was captured at the existing read boundary.
        RequestDiagnosticContext(model: .project(modelID))
    }

    static func handoff(_ resolution: IOSTranscriptionSession.Resolution) -> RequestDiagnosticContext {
        // A default local session call is not remote acceptance or proof of its
        // wrapped provider, language conversion, advanced flags or final budget.
        RequestDiagnosticContext(
            provenance: .observedHandoff, model: .project(resolution.modelID),
            mode: resolution.isBatch ? .batch : .live
        )
    }
}

/// One active run and one published error episode, never a journal/attempt map.
/// Retiring current state must not replace the snapshot of a still-visible error.
struct IOSRequestDiagnosticState {
    private var runID: UUID?
    private var context: RequestDiagnosticContext?
    private var handoff: RequestDiagnosticContext?
    private var terminalFailure: RequestDiagnosticContext.Failure?
    private var failedRunID: UUID?
    private var failedRunSnapshot: IOSIssueReportSnapshot?
    private var publicationToken: UUID?
    private var publishedSnapshot: IOSIssueReportSnapshot?

    mutating func begin(_ run: UUID) {
        runID = run
        context = nil
        handoff = nil
        terminalFailure = nil
        failedRunID = nil
        failedRunSnapshot = nil
    }

    mutating func admit(_ value: RequestDiagnosticContext, run: UUID) {
        guard runID == run, value.provenance == .admission else { return }
        context = value
    }

    func admission(for run: UUID?) -> RequestDiagnosticContext? {
        guard let run, runID == run else { return nil }
        return RequestDiagnosticContext.admissionOnly(context)
    }

    func failure(for run: UUID?) -> RequestDiagnosticContext.Failure? {
        guard let run, runID == run else { return nil }
        return terminalFailure
    }

    mutating func observe(_ resolution: IOSTranscriptionSession.Resolution, run: UUID, defaultSession: Bool) {
        guard runID == run, defaultSession else { return }
        handoff = IOSRequestDiagnosticProjection.handoff(resolution)
    }

    @discardableResult
    mutating func freezeFailure(_ failure: RequestDiagnosticContext.Failure, run: UUID?) -> IOSIssueReportSnapshot? {
        guard let run, runID == run else { return nil }
        terminalFailure = failure
        let snapshot = IOSIssueReportSnapshot(context: context, observedHandoff: handoff, requestFailure: failure)
        failedRunID = run
        failedRunSnapshot = snapshot
        return snapshot
    }

    mutating func publish(_ snapshot: IOSIssueReportSnapshot?, token: UUID?) {
        publicationToken = token
        publishedSnapshot = token == nil ? nil : snapshot ?? IOSIssueReporter.failedRequest()
    }

    func snapshot(for token: UUID?) -> IOSIssueReportSnapshot {
        guard let token, publicationToken == token else { return IOSIssueReporter.failedRequest() }
        return publishedSnapshot ?? IOSIssueReporter.failedRequest()
    }

    func failedStartSnapshot(for run: UUID?) -> IOSIssueReportSnapshot {
        guard let run, failedRunID == run else { return IOSIssueReporter.failedRequest() }
        return failedRunSnapshot ?? IOSIssueReporter.failedRequest()
    }

    mutating func discardFailure(_ run: UUID) {
        guard failedRunID == run else { return }
        failedRunID = nil
        failedRunSnapshot = nil
    }

    mutating func retire(_ run: UUID?) {
        guard let run, runID == run else { return }
        runID = nil
        context = nil
        handoff = nil
        terminalFailure = nil
    }
}

/// Presentation-local ownership only. No persistent History/session identity
/// or source row is retained by this controller or sent in its report.
@MainActor
final class IOSIssueReportController: ObservableObject, Identifiable {
    struct Dependencies {
        var copy: @MainActor (String) -> Bool
        var open: @MainActor (URL) async -> Bool

        static var live: Self {
            Self(copy: { TranscriptClipboard.shared.copy($0) }, open: { await UIApplication.shared.open($0) })
        }
    }

    struct Export: Identifiable {
        let id = UUID()
        let document: IOSIssueReportDocument
    }

    enum ExportOutcome { case saved, cancelled, failed }
    enum Status: Equatable {
        case copied, copyFailed, opened, browserFailed, browserUnavailable, exported, exportCancelled, exportFailed

        var message: String {
            switch self {
            case .copied: return "Draft copied."
            case .copyFailed: return "Could not copy the draft. Try again."
            case .opened: return "GitHub opened. Nothing has been attached or submitted."
            case .browserFailed: return "Could not open GitHub. You can copy the draft instead."
            case .browserUnavailable: return "This draft cannot fit in a browser link. Copy it into a new GitHub issue."
            case .exported: return "Diagnostics saved. Attach the JSON yourself in GitHub."
            case .exportCancelled: return "Export cancelled."
            case .exportFailed: return "Could not save diagnostics. Try another destination."
            }
        }
    }

    let id = UUID()
    @Published private(set) var report: IssueDiagnosticReport
    @Published private(set) var includesDiagnostics = true
    @Published private(set) var pendingExport: Export?
    @Published private(set) var isOpening = false
    @Published private(set) var status: Status?
    private let snapshot: IOSIssueReportSnapshot
    private let dependencies: Dependencies
    private var isClosed = false
    var isExporting: Bool { pendingExport != nil }

    convenience init(snapshot: IOSIssueReportSnapshot) {
        self.init(snapshot: snapshot, dependencies: .live)
    }

    init(snapshot: IOSIssueReportSnapshot, dependencies: Dependencies) {
        self.snapshot = snapshot
        self.report = snapshot.full
        self.dependencies = dependencies
    }

    func setIncludesDiagnostics(_ included: Bool) {
        guard !isClosed, !isExporting, !isOpening else { return }
        includesDiagnostics = included
        report = included ? snapshot.full : snapshot.withoutDetails
        status = nil
    }

    func cancel() {
        isClosed = true
        pendingExport = nil
        // A system-admitted export or browser open cannot be retracted here.
        // Never delete the user's file or claim that cancellation did so.
    }

    func copyDraft() {
        guard !isClosed, !isExporting, !isOpening else { return }
        status = dependencies.copy(report.body) ? .copied : .copyFailed
    }

    func openGitHub() async {
        guard !isClosed, !isExporting, !isOpening, !Task.isCancelled else { return }
        guard let url = report.issueURL else { status = .browserUnavailable; return }
        isOpening = true
        defer { isOpening = false }
        let opened = await dependencies.open(url)
        guard !isClosed, !Task.isCancelled else { return }
        status = opened ? .opened : .browserFailed
    }

    @discardableResult
    func beginExport() -> Export? {
        guard !isClosed, !isExporting, !isOpening, !Task.isCancelled else { return nil }
        let export = Export(document: IOSIssueReportDocument(report: report))
        pendingExport = export
        status = nil
        return export
    }

    func completeExport(_ identifier: UUID, outcome: ExportOutcome) {
        guard !isClosed, pendingExport?.id == identifier else { return }
        pendingExport = nil
        switch outcome {
        case .saved: status = .exported
        case .cancelled: status = .exportCancelled
        case .failed: status = .exportFailed
        }
    }
}
#endif
