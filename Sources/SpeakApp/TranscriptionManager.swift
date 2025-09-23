// @Implement: This file should manage all transcription related functionality
// It should start transcription 

// @Implement: This protocol is for transcribing whole audio files in one go e.g. sending off to an api for transcription
protocol BatchTranscriber {

}

// @Implement: This protocol is for transcribing live audio streams e.g. using native osx transcription capabilities or streaming transcription apis
protocol LiveTranscriber {

}

// @Implement this implements native osx transcription including request permissions using the permissions Manager class. It should offer apis to pass back the live transcribed text as it comes in as well as access the full string at the end of the transcription. And start and stop transcription. It respects relevant app settings
struct NativeOSXLiveTranscriber: LiveTranscriber {

}

// @Implement: Remote audio transcriber. Impelements the batch transcriber protocol sending off the audio file to openrouter for transcription. It respects relevant app settings and depends on OpenRouterAPIClient
struct RemoteAudioTranscriber: BatchTranscriber { }