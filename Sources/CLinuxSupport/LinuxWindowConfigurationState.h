/* The dictation preferences form and settings-search reveal: their state,
 * private to LinuxWindowConfiguration.c; the window self-tests also include it
 * to inspect them. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_CONFIGURATION_STATE_H
#define JSTI_LINUX_WINDOW_CONFIGURATION_STATE_H

#include "LinuxWindowInternal.h"

typedef struct ConfigurationState {
    GPtrArray *rows;
    GPtrArray *choices;
    GArray *booleans;
    GArray *overlay_settings;
    GArray *hands_free_settings;
    GArray *enabled_by_fields;
    GtkWidget *recovery_group;
    AdwComboRow *recovery_row;
    guint recovery_count;
    gchar *revision;
    JSTIConfigurationCallback callback;
    void *context;
} ConfigurationState;

/* Settings search: the revealed row, its pending scroll and its highlight. */
typedef struct Reveal {
    GtkWidget *target;
    guint tick;
    guint frames;
    guint highlight;
} Reveal;

#pragma GCC visibility push(hidden)
ConfigurationState *configuration_state(void);
Reveal *reveal_state(void);
#pragma GCC visibility pop

#endif
