import SpeakCore

extension SharedClientLiveController {
  /// Lists the provider socket in Settings › System resources in use (issue
  /// #1471). It has no release button: it closes with the dictation.
  func replaceConnectionHold(for route: LiveTranscriptionRoute?) {
    connectionHold?.end()
    connectionHold = route.map { route in
      SystemResourceRegistry.shared.acquire(
        kind: .providerConnection, title: "\(route.provider.displayName) live connection",
        reason: "Streams the dictation in progress for live text. Closes when the dictation ends.",
        owner: "SharedClientLiveController", detail: route.modelID
      )
    }
  }
}
