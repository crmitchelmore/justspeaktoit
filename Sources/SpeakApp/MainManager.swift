// @Implement: This file should manage all recording related functionality
// It depends on hotkey manager. Based on the config from app settings it should decide when to start and stop recording.
// It should also depend on audio file manager to process and store the recorded audio file
// IT also has the ability to pass the live audio to the transcription manager for native osx live transcription
// This file is also responsible for checking and requesting microphone permissions using the permissions manager
// When a complete recording, transcribing, post processing etc cycle is complete this file should write a HistoryItem to the history manager.
// This file also depends on the Post Processing Manager. If app settings say post processing should happen, it hands off the raw transcription to the Post Processing Manager and receives it back when complete.
// This file should use the text output to perform the output once all of the steps have been finished.
// This file also takes the HUD Manager as a dependency and calls the lifecycle events on the HUD Manager for it to be updated.
