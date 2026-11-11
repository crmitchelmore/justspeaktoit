import SpeakCore
import AVFoundation
import AppKit
import Foundation

/// The diagnostic context a session keeps for its History entry and issue report.
extension MainManager {
  static func retainBatchDiagnostic(
    _ receipt: TranscriptionManager.BatchDiagnosticReceipt, for session: ActiveSession, activeSession: ActiveSession?
  ) {
    guard activeSession === session, !Task.isCancelled, let context = session.diagnosticContext else { return }
    var handoff = context.observedHandoff
    var failure = context.requestFailure
    switch receipt {
    case .handoff(let observed):
      guard observed.provenance == .observedHandoff else { return }
      handoff = observed
    case .failure(let observed):
      failure = observed
    }
    session.diagnosticContext = HistoryDiagnosticContext(
      capturedAt: context.capturedAt, appVersion: context.appVersion, appBuild: context.appBuild,
      operatingSystem: context.operatingSystem, processIdentifier: context.processIdentifier,
      microphonePermission: context.microphonePermission, inputDeviceName: context.inputDeviceName,
      providerLabel: context.providerLabel, latencyTier: context.latencyTier,
      transcriptionMode: context.transcriptionMode, transcriptionModel: context.transcriptionModel,
      postProcessingModel: context.postProcessingModel, speedMode: context.speedMode,
      requestContext: context.requestContext, observedHandoff: handoff, requestFailure: failure,
      postProcessingObservation: context.postProcessingObservation
    )
  }

  static func retainPostProcessingDiagnostic(
    _ observation: RequestDiagnosticContext.PostProcessingObservation,
    for session: ActiveSession, activeSession: ActiveSession?
  ) {
    guard activeSession === session, !Task.isCancelled, let context = session.diagnosticContext else { return }
    session.diagnosticContext = HistoryDiagnosticContext(
      capturedAt: context.capturedAt, appVersion: context.appVersion, appBuild: context.appBuild,
      operatingSystem: context.operatingSystem, processIdentifier: context.processIdentifier,
      microphonePermission: context.microphonePermission, inputDeviceName: context.inputDeviceName,
      providerLabel: context.providerLabel, latencyTier: context.latencyTier,
      transcriptionMode: context.transcriptionMode, transcriptionModel: context.transcriptionModel,
      postProcessingModel: context.postProcessingModel, speedMode: context.speedMode,
      requestContext: context.requestContext, observedHandoff: context.observedHandoff,
      requestFailure: context.requestFailure, postProcessingObservation: observation
    )
  }

  func makeRecordingSummary(from url: URL, fallbackDuration: TimeInterval)
    -> RecordingSummary {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? fallbackDuration
    let resolvedDuration = duration.isFinite && duration > 0 ? duration : fallbackDuration
    let startedAt = (attributes[.creationDate] as? Date) ?? Date()
    return RecordingSummary(
      id: UUID(),
      url: url,
      startedAt: startedAt,
      duration: resolvedDuration,
      fileSize: fileSize
    )
  }

  func makeHistoryDiagnosticContext(includeRequestedContext: Bool = false) -> HistoryDiagnosticContext {
    let health = captureHealth.snapshot()
    let info = Bundle.main.infoDictionary
    let appVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let appBuild = info?["CFBundleVersion"] as? String ?? "unknown"
    let microphonePermission: String
    switch health.microphonePermission {
    case .granted:
      microphonePermission = "granted"
    case .denied:
      microphonePermission = "denied"
    case .notDetermined:
      microphonePermission = "notDetermined"
    }

    return HistoryDiagnosticContext(
      appVersion: appVersion,
      appBuild: appBuild,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      processIdentifier: Int(ProcessInfo.processInfo.processIdentifier),
      microphonePermission: microphonePermission,
      inputDeviceName: health.inputDeviceName,
      providerLabel: health.providerLabel,
      latencyTier: health.latencyTier.displayName,
      transcriptionMode: appSettings.effectiveTranscriptionModeDisplayName,
      transcriptionModel: captureHealth.currentTranscriptionModelIdentifier,
      postProcessingModel: appSettings.postProcessingModel,
      speedMode: appSettings.speedMode.displayName,
      requestContext: includeRequestedContext ? Self.requestedDiagnosticContext(settings: appSettings) : nil
    )
  }

  func attachFailureDiagnostics(to session: ActiveSession) {
    Self.attachFailureDiagnostics(to: session) {
      self.makeHistoryDiagnosticContext(includeRequestedContext: false)
    }
  }

  static func attachFailureDiagnostics(to session: ActiveSession, fallback: () -> HistoryDiagnosticContext) {
    // Delayed failure handling must keep this session's admission, not today's settings.
    if session.diagnosticContext == nil { session.diagnosticContext = fallback() }
    let description = "Diagnostic snapshot captured for issue report"
    if !session.events.contains(where: { $0.kind == .error && $0.description == description }) {
      session.events.append(HistoryEvent(kind: .error, description: description))
    }
  }

  static func requestedDiagnosticContext(settings: AppSettings) -> RequestDiagnosticContext {
    let mode: RequestDiagnosticContext.Mode
    let model: String
    let streaming: Bool
    switch settings.transcriptionMode {
    case .liveNative:
      mode = .live
      model = settings.liveTranscriptionModel
      streaming = true
    case .batchRemote:
      mode = .batch
      model = settings.batchTranscriptionModel
      streaming = false
    case .localModel:
      mode = .local
      streaming = settings.localTranscriptionMode == .streaming
      model = streaming ? settings.localStreamingModelSource : settings.localTranscriptionModel
    }
    let destination: RequestDiagnosticContext.Destination
    switch settings.textOutputMethod {
    case .clipboardOnly: destination = .clipboard
    case .accessibilityOnly: destination = .accessibility
    case .smart: destination = .unknown // Smart routing has not chosen an output transport yet.
    }
    let seconds = settings.liveModelCapabilities.postStopFinalizeBudget
    let budget = settings.transcriptionMode == .liveNative && seconds.isFinite && (0...86_400).contains(seconds)
      ? Int((seconds * 1_000).rounded()) : nil
    return RequestDiagnosticContext(
      provenance: .admission, model: .project(model),
      postProcessingModel: .project(ModelCatalog.resolvedPostProcessingModel(settings.postProcessingModel)),
      // This helper has no owner-supplied override receipt; never infer one from UI/global state.
      mode: mode, origin: .unknown,
      language: .project(settings.preferredLocaleIdentifier), destination: destination,
      options: .init(
        postProcessingEnabled: settings.postProcessingEnabled,
        diarizationEnabled: streaming && model.hasPrefix("modulate/")
          ? settings.modulateSpeakerDiarizationEnabled : nil,
        streamingEnabled: streaming, finalizationBudgetMilliseconds: budget
      )
    )
  }
}
