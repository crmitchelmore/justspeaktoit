import Foundation
import SpeakDesktopHost
import SpeakLinuxPlatform

// History playback and Read aloud share one player, so only one is ever
// audible and Play/Pause and Stop act on either.
extension LinuxAudioPlayback: DesktopHostPlayback, DesktopHostSpeechPlayback {}

extension LinuxVoiceOutput: DesktopHostVoiceOutput {}
