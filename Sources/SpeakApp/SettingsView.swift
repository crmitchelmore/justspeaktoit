// @Implement: This view allows management of all settings within the app settings class. Each logical grouping of settings should have it's own segment in a tab bar at the top of the view. All settings should be immediately persisted through the AppSettings class when they are changed. Break down the view in to smaller components for easier management.
// - API key management
// - General configuration
// - Model selection
// - Transcription configuration (e.g. whether it should use post-processing or not)
// - Post-processing configuration
// - Hotkey management and configuration: This should allow selection of a hotkey (default should be the fn key) probably a library is a good choice
// - Permission management: Call from permissions manager to see and ask for permissions and allow the user to validate easily for each one if it was correctly granted.
// And then any other sections you think are relevant. This should be presented in a concise but user-friendly format.