/* The sidebar's Ctrl+digit shortcuts: their state, private to
 * LinuxWindowNavigation.c; the window self-tests also include it to inspect
 * it. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_NAVIGATION_STATE_H
#define JSTI_LINUX_WINDOW_NAVIGATION_STATE_H

#include "LinuxWindowInternal.h"

typedef struct SidebarShortcuts {
    gint digits[JSTI_PAGE_COUNT];
    GtkWidget *hints[JSTI_PAGE_COUNT];
    gboolean configured;
} SidebarShortcuts;

#pragma GCC visibility push(hidden)
SidebarShortcuts *sidebar_shortcuts_state(void);
#pragma GCC visibility pop

#endif
