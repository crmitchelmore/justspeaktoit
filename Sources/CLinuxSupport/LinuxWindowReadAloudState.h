/* Read aloud's voice picker: its state, private to LinuxWindowReadAloud.c; the
 * window self-tests also include it to inspect it. The History card's Read
 * aloud button belongs to the History page. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_READ_ALOUD_STATE_H
#define JSTI_LINUX_WINDOW_READ_ALOUD_STATE_H

#include "LinuxWindowInternal.h"

typedef struct ReadAloud {
    AdwComboRow *voice_row;
    GtkStringList *voices;
    AdwComboRow *favorite_row;
    GtkStringList *favorite_names;
    GtkButton *favorite_button;
    GPtrArray *identifiers;
    GArray *favorite_ranks;
    GArray *favorite_indices;
    JSTIVoicePickerCallback picker_callback;
    void *picker_context;
    gboolean favorite_pending;
    gboolean favorite_executable;
} ReadAloud;

#pragma GCC visibility push(hidden)
ReadAloud *read_aloud_state(void);
#pragma GCC visibility pop

#endif
