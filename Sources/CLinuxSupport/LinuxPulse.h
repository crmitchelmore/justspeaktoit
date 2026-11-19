/* Private to the libpulse units (LinuxCapture.c, LinuxPlayback.c,
 * LinuxAudioDevices.c and LinuxAudioDeviceMonitor.c): one threaded main loop
 * and its context. On current desktops libpulse reaches PipeWire through
 * pipewire-pulse; in Flatpak it needs --socket=pulseaudio. Each owner opens
 * its own connection, so their lifetimes never depend on one another. */
#ifndef JSTI_LINUX_PULSE_H
#define JSTI_LINUX_PULSE_H
#include <pulse/pulseaudio.h>
#include <stddef.h>
#include <stdint.h>

#pragma GCC visibility push(hidden)

typedef struct JSTIPulse {
    pa_threaded_mainloop *loop;
    pa_context *context;
} JSTIPulse;

/* Connects and waits for READY. Leaves the loop locked on success; on failure
 * writes `error` and leaves nothing open. */
int32_t jsti_pulse_open(JSTIPulse *pulse, const char *name, char *error, size_t capacity);
/* Disconnects, stops and frees the loop. Call with the loop unlocked. Safe on
 * a connection that never opened. */
void jsti_pulse_close(JSTIPulse *pulse);

#pragma GCC visibility pop

#endif
