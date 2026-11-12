import SpeakCore

/// One snapshot of what the keyboard surface shows: the strip's text and
/// symbol, and the state of the mic, chips and editing keys.
///
/// Read once per render from ``KeyboardViewModel``, so the strip and the
/// control row never disagree about which capture path or phase is on screen.
struct KeyboardSurfaceState {
    enum Phase {
        case direct(KeyboardDictationMachine.State)
        case handoff(KeyboardHandoffController.Presentation, endReason: InstantDictationReadinessEndReason?)
        case blocked(KeyboardLaunchPolicy.BlockReason)
    }

    /// How the strip's status symbol is tinted.
    enum Tone: Equatable {
        case live, success, warning, neutral
    }

    let phase: Phase
    /// The transcript currently streaming on the active path, if any.
    let liveText: String
    let isBusy: Bool
    /// Both quick-switch chips are on the control row.
    let showsBothChips: Bool

    var showsLiveText: Bool {
        !liveText.isEmpty
    }

    var isBlocked: Bool {
        if case .blocked = phase { return true }
        return false
    }

    var stripText: String {
        if showsLiveText {
            return liveText
        }
        switch phase {
        case let .direct(state):
            return KeyboardStatusCopy.direct(state)
        case let .handoff(presentation, endReason):
            return KeyboardStatusCopy.handoff(presentation, endReason: endReason)
        case let .blocked(reason):
            return KeyboardStatusCopy.blocked(reason)
        }
    }

    /// The status symbol is hidden from assistive technology, so VoiceOver
    /// reads the strip as status plus content.
    var stripAccessibilityLabel: String {
        guard showsLiveText else { return stripText }
        return "\(liveStatusDescription). \(stripText)"
    }

    private var liveStatusDescription: String {
        switch phase {
        case let .direct(state):
            switch state {
            case .stopping: return "Finishing dictation"
            case .finished: return "Dictation inserted"
            default: return "Dictating"
            }
        case let .handoff(presentation, _):
            switch presentation {
            case .transcribing: return "Finishing dictation"
            case .inserted: return "Dictation inserted"
            default: return "Dictating"
            }
        case .blocked:
            return "Dictation unavailable"
        }
    }

    var stripSymbol: String {
        switch phase {
        case let .direct(state):
            switch state {
            case .recording, .stopping: return "waveform"
            case .finished: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            default: return "mic"
            }
        case let .handoff(presentation, _):
            switch presentation {
            case .recording, .transcribing: return "waveform"
            case .inserted: return "checkmark.circle.fill"
            case .waitingForApp: return "arrow.up.forward.app"
            case .unavailable, .targetChanged, .error: return "exclamationmark.triangle.fill"
            default: return "mic"
            }
        case .blocked:
            return "lock.trianglebadge.exclamationmark"
        }
    }

    var stripTone: Tone {
        switch stripSymbol {
        case "checkmark.circle.fill": return .success
        case "exclamationmark.triangle.fill", "lock.trianglebadge.exclamationmark": return .warning
        case "waveform": return .live
        default: return .neutral
        }
    }

    var showsCancel: Bool {
        switch phase {
        case let .direct(state):
            return state == .recording || state == .starting
        case let .handoff(presentation, _):
            return presentation == .starting || presentation == .recording || presentation == .transcribing
        case .blocked:
            return false
        }
    }

    // MARK: - Mic and editing keys

    var isActivelyCapturing: Bool {
        switch phase {
        case let .direct(state):
            return state == .recording
        case let .handoff(presentation, _):
            return presentation == .recording
        case .blocked:
            return false
        }
    }

    var micSymbol: String {
        isActivelyCapturing ? "stop.fill" : "mic.fill"
    }

    var micAccessibilityLabel: String {
        isActivelyCapturing ? "Stop dictation" : "Start dictation"
    }

    /// The caption is dropped once both quick-switch chips are on the row, so
    /// the single control row keeps a full-size mic key on the narrowest
    /// supported iPhone instead of wrapping or truncating.
    var micCaption: String? {
        if showsBothChips {
            return nil
        }
        if isActivelyCapturing {
            return "Stop"
        }
        return isBlocked ? nil : "Speak"
    }

    var micShowsProgress: Bool {
        switch phase {
        case let .direct(state):
            return state == .starting || state == .stopping
        case let .handoff(presentation, _):
            return presentation == .starting || presentation == .transcribing
        case .blocked:
            return false
        }
    }

    var micDisabled: Bool {
        switch phase {
        case let .direct(state):
            return state == .stopping
        case let .handoff(presentation, _):
            return presentation == .transcribing || presentation == .waitingForApp
        case .blocked:
            return true
        }
    }

    var controlsDisabled: Bool {
        switch phase {
        case .direct:
            return isBusy
        case let .handoff(presentation, _):
            return presentation == .recording || presentation == .transcribing
        case .blocked:
            return false
        }
    }
}

extension KeyboardViewModel {
    /// The surface for the current mode, read from the path that owns it.
    var surface: KeyboardSurfaceState {
        let phase: KeyboardSurfaceState.Phase
        let liveText: String
        switch mode {
        case .direct:
            phase = .direct(directState)
            liveText = self.liveText
        case .handoff:
            phase = .handoff(handoff.presentation, endReason: handoff.instantEndReason)
            liveText = handoff.liveTranscript
        case let .blocked(reason):
            phase = .blocked(reason)
            liveText = ""
        }
        return KeyboardSurfaceState(
            phase: phase,
            liveText: liveText,
            isBusy: isBusy,
            showsBothChips: languageChipLabel != nil && showsLanguageChip && profileChipLabel != nil
        )
    }
}
