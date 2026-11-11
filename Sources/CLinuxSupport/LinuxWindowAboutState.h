/* The About page: its state, private to LinuxWindowSettingsPages.c, which
 * builds and applies it; the window self-tests also include it to inspect it.
 * GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_ABOUT_STATE_H
#define JSTI_LINUX_WINDOW_ABOUT_STATE_H

#include "LinuxWindowInternal.h"

typedef struct AboutPage {
    GtkLabel *about_details;
    GtkFlowBox *about_links;
} AboutPage;

#pragma GCC visibility push(hidden)
AboutPage *about_page(void);
#pragma GCC visibility pop

#endif
