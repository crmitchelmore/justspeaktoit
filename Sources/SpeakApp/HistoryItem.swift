//@Implement This represents the full details of an item to write to the history, and it includes:
// - What models were used
// - The raw transcription
// - Any post-processing transcription
// - The duration of the recording
// - The cost of the model
// - A link to the persisted audio file
// - Any raw network requests and responses? In sequence. 
// Timestamps for each step
// The events that started and stopped the recording, where the output was pasted to (if possible) and how it was pasted using accessibility or clipboard. Which hotkey and hotkey type of event started the recording.
// History items should also be able to store errors to any of the above data whilst retaining all useful information so that it can be presented as part of the history view.
