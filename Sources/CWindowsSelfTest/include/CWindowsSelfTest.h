#ifndef JSTI_WINDOWS_SELF_TEST_H
#define JSTI_WINDOWS_SELF_TEST_H
/* Native self-tests behind SpeakWindows.exe --self-test and --ui-smoke-test.
 * They live in their own target so CWindowsSupport holds product code only.
 * The executable still links them: the bundle verifier and the Windows
 * workflows qualify the exact shipped binary by running them. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Call on the UI thread from READY in smoke-test mode. Verifies native control
 * bounds, history updates/events, search/filter selection handling, transcript
 * variant action identities, an invisible settings Apply round-trip and the Text
 * output dialog: every choice through its controls, Cancel/Escape/Enter,
 * keyboard order, minimum bounds and its modal loop blocking recording.
 * Restores history and text output configuration afterwards; never uses
 * microphone, clipboard or credentials. */
int jsti_window_self_test(char *error, size_t error_capacity);

/* Deterministic native checks on app-owned synthetic hidden controls with
 * injected foreground, clipboard and keystroke seams: caret/selection
 * insertion, surrogate pairs, stale identity, password/read-only refusal,
 * UI Automation value/paste paths, timeouts and worker cleanup. Never sends
 * real input, touches the system clipboard or inserts into another app. */
int jsti_text_output_self_test(char *error, size_t error_capacity);

/* Deterministic checks on short low-amplitude synthetic WAV files in a unique
 * temporary directory, without any endpoint: fixed queue, input pinning and
 * limits, Media Foundation exact/converted decode, decoded-sample bound,
 * duration, cancellation of a stalled read, and the production render loop
 * driven by a synthetic engine: exact output bytes with no trailing silence,
 * source-position accounting through pause/resume/cancel/drain, pause before
 * start, event timeout, start failure, immediate completion, refused second
 * start, callback self-destroy refusal, and release of the pinned source.
 * Needs Media Foundation. Never uses recordings, credentials or a speaker. */
int jsti_audio_playback_self_test(char *error, size_t error_capacity);

/* Uses a unique temporary directory and synthetic bytes only; verifies ACLs,
 * directory repair, existing-file preservation and junction refusal. */
int jsti_private_storage_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
