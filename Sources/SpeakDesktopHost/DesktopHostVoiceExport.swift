import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    /// The path and text were captured together before opening the native save
    /// dialog. Export never plays or changes a recording or its transcript.
    package func exportVoiceSource(
        _ snapshot: VoiceOutputSourceSnapshot, path: String, retainedAudio: Data? = nil,
        synthesize: @escaping @Sendable (
            VoiceOutputSourceSnapshot, DesktopSpeechSelection, @Sendable () async throws -> String
        ) async throws -> Data = { snapshot, selection, credential in
            try await DesktopSpeechSynthesis().synthesize(
                snapshot, voice: selection.voice, options: selection.options,
                accountInventory: selection.accountInventory, sonioxRegion: selection.sonioxRegion,
                language: selection.language, credential: credential
            )
        },
        publish: @escaping @Sendable (Data, URL) async throws -> Void = {
            try await DesktopVoicePlaybackFile.writeExport($0, to: $1)
        }
    ) {
        startVoiceExport(snapshot, path: path, retained: retainedAudio.map { .init(data: $0, format: .wav) },
                         synthesize: synthesize, publish: publish)
    }

    package func exportRetainedVoiceAudio(
        _ snapshot: VoiceOutputSourceSnapshot, audio: VoiceGeneratedAudio, path: String
    ) {
        startVoiceExport(snapshot, path: path, retained: .init(data: audio.data, format: audio.format),
            synthesize: { _, _, _ in throw VoiceAudioFormatError.invalidContainer },
            publish: { try await DesktopVoicePlaybackFile.writeExport($0, to: $1) })
    }

    // Retained bypass and fresh synthesis share one owned publication boundary.
    // swiftlint:disable:next function_body_length
    private func startVoiceExport(
        _ snapshot: VoiceOutputSourceSnapshot, path: String, retained: VoiceExportPayload?,
        synthesize: @escaping @Sendable (
            VoiceOutputSourceSnapshot, DesktopSpeechSelection, @Sendable () async throws -> String
        ) async throws -> Data,
        publish: @escaping @Sendable (Data, URL) async throws -> Void
    ) {
        guard !closed, canUseHistory else { return }
        let destination: URL
        let format: VoiceAudioFormat
        do {
            destination = try voiceExportDestination(path)
            format = try VoiceAudioFormat.storedValue(destination.pathExtension.lowercased())
            guard retained == nil || retained?.format == format else {
                throw DesktopHostError(
                    message: "Choose .\(retained?.format.fileExtension ?? "") for this retained result.")
            }
        } catch { update(error.localizedDescription); return }
        let selection: DesktopSpeechSelection?
        let conversionID: UUID?
        do {
            selection = retained == nil ? try currentVoiceSelection() : nil
            conversionID = retained == nil ? try admitVoiceAudioConversion(format) : nil
        } catch {
            update(error.localizedDescription); return
        }
        stopReadAloud()
        playback.stop(announcing: false)
        let ticket = playbackRequests.begin()
        let effects = effects
        update(selection.map { "Synthesizing \(format.displayName) with \($0.voice.name). Stop cancels export…" } ??
            "Exporting retained voice audio. No synthesis request is sent. Stop cancels export…")
        voiceOutputRecordID = snapshot.recordID
        let usage = retained == nil
            ? beginVoiceUsage(operation: .export, source: snapshot.source, recordID: snapshot.recordID) : nil
        let accountWork = beginAccountVoiceWork(selection, ticket: ticket)
        activeOperations += 1
        readAloudState.exportTask = Task {
            defer {
                self.finishVoiceAudioConversion(conversionID)
                self.finishAccountVoiceOperation(accountWork, usage: usage)
            }
            do {
                let bytes: Data
                if let retained { bytes = retained.data } else if let selection {
                    try await Platform.requireVoiceAudioFormat(format, sampleRate: selection.sampleRate)
                    try Task.checkCancellation()
                    guard !self.closed, self.playbackRequests.isCurrent(ticket) else { return }
                    let wav = try await VoiceSynthesisUsage.$capture.withValue(usage?.capture) {
                        let prepared = try await self.prepareVoiceSynthesisSource(
                            snapshot, selection: selection, ticket: ticket)
                        return try await synthesize(prepared, selection) {
                            try await Self.readVoiceSynthesisKey(
                                effects: effects, name: selection.voice.apiKeyIdentifier)
                        }
                    }
                    try Task.checkCancellation()
                    guard !self.closed, self.playbackRequests.isCurrent(ticket) else { return }
                    let canonical = try VoiceGeneratedAudio(validating: wav, sampleRate: selection.sampleRate)
                    let audio = try await Platform.encodeVoiceAudio(canonical, format: format)
                    guard audio.format == format, audio.sampleRate == selection.sampleRate else {
                        throw VoiceAudioFormatError.invalidContainer
                    }
                    bytes = audio.data
                } else {
                    throw VoiceSynthesisConfigurationError.unsupportedVoice
                }

                try Task.checkCancellation()
                guard !self.closed, self.playbackRequests.isCurrent(ticket) else { return }
                // No partial destination is ever published. A failed synthesis or
                // cancellation before this commit leaves any existing file intact.
                try await publish(bytes, destination)
                self.finishVoiceExport(ticket, status: retained == nil
                    ? "Voice audio exported as \(format.displayName)."
                    : "Retained voice audio exported as \(format.displayName); no synthesis request was sent.")
            } catch is CancellationError {
                self.finishVoiceExport(ticket, status: "Voice export cancelled.")
            } catch {
                self.finishVoiceExport(ticket, status: "Voice export failed: \(error.localizedDescription)")
            }
        }
    }

    package func voiceExportDestination(_ path: String) throws -> URL {
        let destination = URL(fileURLWithPath: path)
        guard !path.isEmpty, !path.utf8.contains(0),
              VoiceAudioFormat(rawValue: destination.pathExtension.lowercased()) != nil else {
            throw DesktopHostError(message: "Choose an MP3, M4A or WAV file for voice export.")
        }

        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        #if os(Windows)
        let candidate = resolved.lowercased()
        let protectedRoot = root.lowercased()
        #else
        let candidate = resolved
        let protectedRoot = root
        #endif
        guard candidate != protectedRoot, !candidate.hasPrefix(protectedRoot + "/"),
              !candidate.hasPrefix(protectedRoot + "\\") else {
            throw DesktopHostError(message: "Choose an export location outside the app's data folder.")
        }
        return destination
    }

    private func finishVoiceExport(_ ticket: DesktopPlaybackRequests.Ticket, status: String) {
        guard !closed, playbackRequests.isCurrent(ticket) else { return }
        readAloudState.exportTask = nil
        voiceOutputRecordID = nil
        guard !busy, recording == nil else { return }
        update(status)
    }
}

private struct VoiceExportPayload: Sendable {
    let data: Data
    let format: VoiceAudioFormat
}
