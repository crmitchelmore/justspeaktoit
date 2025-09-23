// @Implement: This is the view that shows a floating indicator at the bottom middle of the screen. This should be a minimal view but must be engaging and informative to the users. It should have a cool animated graphic for each phase.
// - Recording: Show in red and how long recording is for with a cool icon as well as animation
// - Transcribing: If the operation is a batch request, this is the transcribing phase waiting for the raw transcription to return
// - Post Processing: This is the call to an LLM to clean up the transcription and also is be optional based on app settings
// - Error: IF any phase errors show the error message.