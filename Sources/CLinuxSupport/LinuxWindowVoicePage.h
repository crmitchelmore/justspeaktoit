/* The Voice Output page's actions: its state, owned by LinuxWindowSettingsPages.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_VOICE_PAGE_H
#define JSTI_LINUX_WINDOW_VOICE_PAGE_H

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
