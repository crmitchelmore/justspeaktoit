#if os(macOS)
import AVFoundation
import Foundation
import SpeakCore

/// `speak say` on the Mac: the app's own voices and keys, played and/or
/// written for the caller, without touching the Voice window's player.
extension AppAutomationHandler {
    func automationSpeak(_ speech: AutomationSpeechRequest) async throws -> AutomationResult {
        if speech.play, self.main.activeSession != nil {
            throw AutomationError(
                code: .alreadyRecording, message: "Stop dictation before speaking aloud, or write a file with -o."
            )
        }
        let choice = try AutomationVoiceResolver.resolve(
            speech.voice, in: await self.tts.automationVoices(refresh: false, including: speech.voice.voice)
        )
        let voice = choice.voice.id
        let result: TTSResult
        do {
            result = try await self.tts.synthesizeForAutomation(
                text: speech.text, voice: voice, model: choice.model, format: speech.output?.format ?? .macDefault
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AutomationError(code: .speechFailed, message: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: result.audioURL) }
        do {
            if let output = speech.output {
                try AutomationSpeechAudio.write(result.audioURL, to: output.url, format: output.format)
            }
            if speech.play { try await AutomationSpeechAudio.play(result.audioURL) }
        } catch let error as AutomationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AutomationError(code: .speechFailed, message: error.localizedDescription)
        }
        var reply = AutomationResult(model: choice.model, durationSeconds: result.duration)
        reply.voice = voice
        reply.path = speech.output?.path
        if choice.isFallback {
            reply.notice = "Used the on-device voice because the app's voice (\(self.tts.selectedVoiceID)) "
                + "has no saved key. Choose a voice in the app's Voice settings, or pass --voice."
        }
        return reply
    }

    func automationVoices() async throws -> [AutomationVoice] {
        await self.tts.automationVoices(refresh: true)
    }
}

/// File and playback steps for automation speech.
enum AutomationSpeechAudio {
    /// Publishes `source` at `destination` in `format`, converting when the
    /// provider returned another container. The file appears complete or not at all.
    static func write(_ source: URL, to destination: URL, format: VoiceAudioFormat) throws {
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".speak-\(UUID().uuidString).\(format.fileExtension)")
        do {
            if source.pathExtension.lowercased() == format.fileExtension {
                try FileManager.default.copyItem(at: source, to: staged)
            } else {
                try self.convert(source, to: staged, format: format)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// Re-encodes to WAV or AAC. macOS has no MP3 encoder, so an MP3 request
    /// that the voice cannot meet fails instead of mislabelling another format.
    static func convert(_ source: URL, to destination: URL, format: VoiceAudioFormat) throws {
        var settings: [String: Any]
        switch format {
        case .mp3:
            throw AutomationError(
                code: .speechFailed, message: "This voice cannot produce MP3 audio. Save to a .wav or .m4a file."
            )
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ]
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC]
        }
        let input = try AVAudioFile(forReading: source)
        settings[AVSampleRateKey] = input.fileFormat.sampleRate
        settings[AVNumberOfChannelsKey] = input.fileFormat.channelCount
        let processing = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination, settings: settings,
            commonFormat: processing.commonFormat, interleaved: processing.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: 32_768) else {
            throw AutomationError(code: .speechFailed, message: "Not enough memory to convert the speech audio.")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    /// Plays to the end; cancelling the request stops playback.
    @MainActor
    static func play(_ url: URL) async throws {
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.play() else {
            throw AutomationError(code: .speechFailed, message: "The speech audio could not be played.")
        }
        do {
            while player.isPlaying { try await Task.sleep(for: .milliseconds(50)) }
        } catch {
            player.stop()
            throw error
        }
    }
}
#endif
