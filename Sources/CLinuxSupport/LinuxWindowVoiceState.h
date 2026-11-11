/* The Voice Output page's actions: their state, private to
 * LinuxWindowSettingsPages.c, which builds and refreshes it; the window
 * self-tests also include it to inspect it. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_VOICE_STATE_H
#define JSTI_LINUX_WINDOW_VOICE_STATE_H

#include "LinuxWindowInternal.h"

typedef struct VoicePage {
    GtkButton *voice_read;
    GtkButton *voice_stop;
    GtkButton *voice_sources;
} VoicePage;

#pragma GCC visibility push(hidden)
VoicePage *voice_page(void);
#pragma GCC visibility pop

#endif
