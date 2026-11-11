import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    /// Target, profile and text output are fixed when recording starts; a
    /// later settings change applies only to later recordings.
    package struct Recording {
        package let capture: any DesktopRecordingCapture
        package let context: DesktopCaptureContext
        package let file: PCMRecordingFile
        package let handsFree: Bool
        package var record: DesktopRecordingStore.Record
        package let target: Platform.InsertionTarget?
        package let live: DesktopLiveSession?
        package let profile: DesktopProfileSession
        package let options: DesktopHostRecordingConfiguration
        package let textOutput: Platform.TextOutputOptions
        /// What started this session; a shortcut gesture stops only its own kind.
        package let trigger: HotKeySessionTrigger
    }

    package struct StoppedRecording: Sendable {
        package let record: DesktopRecordingStore.Record
        package let duration: TimeInterval
        package let target: Platform.InsertionTarget?
        package let live: DesktopLiveSession?
        package let profile: DesktopProfileSession
        /// Legacy-path snapshot; owned dictation freezes its inputs in `input`.
        package var options: DesktopHostRecordingConfiguration?
        package let textOutput: Platform.TextOutputOptions
        package var input: DesktopHostRecordingInput?
        package var output: DesktopHostRecordingOutput<Platform> { .init(options: textOutput, target: target) }
        /// Frozen at Record; nil only for directly constructed finishes.
        package var voiceCommands: DesktopHostVoiceCommandPolicy? { input?.voiceCommands ?? options?.voiceCommands }
    }
}
