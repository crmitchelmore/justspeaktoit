#include "LinuxSupportInternal.h"
#include "LinuxPulse.h"

/* History recording playback: one libpulse playback stream per player, which
 * drains and reports FINISHED once every sample is written. */

struct jsti_player {
    JSTIPulse pulse;
    pa_stream *stream;
    int16_t *samples;
    size_t count;
    size_t written;
    uint32_t rate;
    gint state;
    gboolean draining;
    pa_operation *drain;
};

static void player_drained(pa_stream *stream, int success, void *data) {
    (void)stream; (void)success;
    jsti_player *player = data;
    g_atomic_int_set(&player->state, JSTI_PLAYER_FINISHED);
}

static void player_write(pa_stream *stream, size_t requested, void *data) {
    jsti_player *player = data;
    size_t remaining = (player->count - player->written) * sizeof(int16_t);
    size_t length = MIN(requested, remaining);
    if (length > 0) {
        pa_stream_write(stream, player->samples + player->written, length, NULL, 0, PA_SEEK_RELATIVE);
        player->written += length / sizeof(int16_t);
    }
    if (player->written >= player->count && !player->draining) {
        player->draining = TRUE;
        player->drain = pa_stream_drain(stream, player_drained, player);
    }
}

static void player_state(pa_stream *stream, void *data) {
    jsti_player *player = data;
    if (pa_stream_get_state(stream) == PA_STREAM_FAILED) g_atomic_int_set(&player->state, JSTI_PLAYER_FAILED);
    pa_threaded_mainloop_signal(player->pulse.loop, 0);
}

jsti_player *jsti_player_create(
    const int16_t *samples, size_t count, uint32_t sample_rate, char *error, size_t capacity) {
    if (count == 0 || sample_rate < 8000 || sample_rate > 48000) {
        jsti_set_error(error, capacity, "This recording has no playable audio.");
        return NULL;
    }
    jsti_player *player = g_new0(jsti_player, 1);
    player->samples = g_memdup2(samples, count * sizeof(int16_t));
    player->count = count;
    player->rate = sample_rate;
    if (jsti_pulse_open(&player->pulse, "JustSpeakToIt playback", error, capacity) != 0) {
        g_free(player->samples);
        g_free(player);
        return NULL;
    }
    pa_sample_spec spec = { .format = PA_SAMPLE_S16LE, .rate = sample_rate, .channels = 1 };
    player->stream = pa_stream_new(player->pulse.context, "History recording", &spec, NULL);
    if (player->stream != NULL) {
        pa_stream_set_write_callback(player->stream, player_write, player);
        pa_stream_set_state_callback(player->stream, player_state, player);
    }
    if (player->stream == NULL || pa_stream_connect_playback(player->stream, NULL, NULL, 0, NULL, NULL) < 0) {
        pa_threaded_mainloop_unlock(player->pulse.loop);
        jsti_set_error(error, capacity, "Could not open the audio output.");
        jsti_player_destroy(player);
        return NULL;
    }
    for (;;) {
        pa_stream_state_t state = pa_stream_get_state(player->stream);
        if (state == PA_STREAM_READY) break;
        if (!PA_STREAM_IS_GOOD(state)) {
            pa_threaded_mainloop_unlock(player->pulse.loop);
            jsti_set_error(error, capacity, "Could not open the audio output.");
            jsti_player_destroy(player);
            return NULL;
        }
        pa_threaded_mainloop_wait(player->pulse.loop);
    }
    pa_threaded_mainloop_unlock(player->pulse.loop);
    return player;
}

int32_t jsti_player_set_paused(jsti_player *player, int32_t paused) {
    gint state = g_atomic_int_get(&player->state);
    if (state == JSTI_PLAYER_FINISHED || state == JSTI_PLAYER_FAILED) return -1;
    pa_threaded_mainloop_lock(player->pulse.loop);
    pa_operation *operation = pa_stream_cork(player->stream, paused ? 1 : 0, NULL, NULL);
    if (operation != NULL) pa_operation_unref(operation);
    g_atomic_int_set(&player->state, paused ? JSTI_PLAYER_PAUSED : JSTI_PLAYER_PLAYING);
    pa_threaded_mainloop_unlock(player->pulse.loop);
    return 0;
}

double jsti_player_position(jsti_player *player) {
    if (g_atomic_int_get(&player->state) == JSTI_PLAYER_FINISHED) return (double)player->count / player->rate;
    pa_usec_t time = 0;
    pa_threaded_mainloop_lock(player->pulse.loop);
    int result = pa_stream_get_time(player->stream, &time);
    pa_threaded_mainloop_unlock(player->pulse.loop);
    if (result < 0) return 0;
    return MIN((double)time / 1e6, (double)player->count / player->rate);
}

int32_t jsti_player_state(jsti_player *player) { return g_atomic_int_get(&player->state); }

void jsti_player_destroy(jsti_player *player) {
    if (player == NULL) return;
    if (player->pulse.loop != NULL) {
        pa_threaded_mainloop_lock(player->pulse.loop);
        if (player->drain != NULL) {
            /* A cancelled operation never calls back into freed state. */
            pa_operation_cancel(player->drain);
            pa_operation_unref(player->drain);
            player->drain = NULL;
        }
        if (player->stream != NULL) {
            pa_stream_set_write_callback(player->stream, NULL, NULL);
            pa_stream_set_state_callback(player->stream, NULL, NULL);
            pa_stream_disconnect(player->stream);
            pa_stream_unref(player->stream);
            player->stream = NULL;
        }
        pa_threaded_mainloop_unlock(player->pulse.loop);
        jsti_pulse_close(&player->pulse);
    }
    g_free(player->samples);
    g_free(player);
}
