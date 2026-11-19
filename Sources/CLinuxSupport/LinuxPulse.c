#include "LinuxSupportInternal.h"
#include "LinuxPulse.h"

/* The shared libpulse connection: see LinuxPulse.h. */

static void context_state(pa_context *context, void *userdata) {
    (void)context;
    pa_threaded_mainloop_signal(userdata, 0);
}

void jsti_pulse_close(JSTIPulse *pulse) {
    if (pulse->loop == NULL) return;
    pa_threaded_mainloop_lock(pulse->loop);
    if (pulse->context != NULL) {
        pa_context_set_state_callback(pulse->context, NULL, NULL);
        pa_context_disconnect(pulse->context);
        pa_context_unref(pulse->context);
        pulse->context = NULL;
    }
    pa_threaded_mainloop_unlock(pulse->loop);
    pa_threaded_mainloop_stop(pulse->loop);
    pa_threaded_mainloop_free(pulse->loop);
    pulse->loop = NULL;
}

int32_t jsti_pulse_open(JSTIPulse *pulse, const char *name, char *error, size_t capacity) {
    pulse->loop = pa_threaded_mainloop_new();
    if (pulse->loop == NULL) {
        jsti_set_error(error, capacity, "Could not start the audio thread.");
        return -1;
    }
    pa_mainloop_api *api = pa_threaded_mainloop_get_api(pulse->loop);
    pa_proplist *properties = pa_proplist_new();
    pa_proplist_sets(properties, PA_PROP_APPLICATION_NAME, "JustSpeakToIt");
    pa_proplist_sets(properties, PA_PROP_APPLICATION_ID, "com.justspeaktoit.JustSpeakToIt");
    pa_proplist_sets(properties, PA_PROP_APPLICATION_ICON_NAME, "com.justspeaktoit.JustSpeakToIt");
    pulse->context = pa_context_new_with_proplist(api, name, properties);
    pa_proplist_free(properties);
    if (pulse->context == NULL) {
        jsti_set_error(error, capacity, "Could not create an audio context.");
        jsti_pulse_close(pulse);
        return -1;
    }
    pa_context_set_state_callback(pulse->context, context_state, pulse->loop);
    pa_threaded_mainloop_lock(pulse->loop);
    if (pa_threaded_mainloop_start(pulse->loop) < 0 ||
        pa_context_connect(pulse->context, NULL, PA_CONTEXT_NOFLAGS, NULL) < 0) {
        pa_threaded_mainloop_unlock(pulse->loop);
        jsti_set_error(
            error, capacity, "The sound server is unavailable (%s). Check that PipeWire or PulseAudio is running.",
            pa_strerror(pa_context_errno(pulse->context)));
        jsti_pulse_close(pulse);
        return -1;
    }
    for (;;) {
        pa_context_state_t state = pa_context_get_state(pulse->context);
        if (state == PA_CONTEXT_READY) return 0;
        if (!PA_CONTEXT_IS_GOOD(state)) {
            int code = pa_context_errno(pulse->context);
            pa_threaded_mainloop_unlock(pulse->loop);
            jsti_set_error(
                error, capacity, "The sound server is unavailable (%s). Check that PipeWire or PulseAudio is running.",
                pa_strerror(code));
            jsti_pulse_close(pulse);
            return -1;
        }
        pa_threaded_mainloop_wait(pulse->loop);
    }
}
