import Foundation
import Combine
import os.log

@MainActor
public final class AutoCorrectionEngine: ObservableObject {
  @Published public private(set) var candidates: [AutoCorrectionCandidate] = []
  public let domain: AutoCorrectionDomain

  public init(
    store: AutoCorrectionStoring, lexiconService: PersonalLexiconService,
    promotionThreshold: @escaping () -> Int
  ) {
    domain = AutoCorrectionDomain(
      store: store, lexiconService: lexiconService.domain, promotionThreshold: promotionThreshold
    )
    domain.onChange = { [weak self] in self?.candidates = $0 }
    let log = SpeakLogger.logger(category: "AutoCorrectionEngine")
    domain.onError = { error in
      log.error("Auto-correction operation failed: \(error.localizedDescription, privacy: .public)")
    }
  }
  public func waitUntilLoaded() async { await domain.waitUntilLoaded() }
  public func recordEdit(original: String, edited: String, app: String?) async throws {
    try await domain.recordEdit(original: original, edited: edited, app: app)
  }
  public func promoteCandidate(_ candidate: AutoCorrectionCandidate) async throws {
    try await domain.promoteCandidate(candidate)
  }
  public func dismissCandidate(id: UUID) async throws { try await domain.dismissCandidate(id: id) }
  public func removeCandidate(id: UUID) async throws { try await domain.removeCandidate(id: id) }
  public func clearAllCandidates() async throws { try await domain.clearAllCandidates() }
  public func reloadAfterMigration() async { await domain.reloadAfterMigration() }
}
