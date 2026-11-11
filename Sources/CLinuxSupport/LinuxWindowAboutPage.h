/* The About page: its state, owned by LinuxWindowSettingsPages.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_ABOUT_PAGE_H
#define JSTI_LINUX_WINDOW_ABOUT_PAGE_H

#include "LinuxWindowInternal.h"

typedef struct AboutPage {
    GtkLabel *about_details;
    GtkFlowBox *about_links;
} AboutPage;

#pragma GCC visibility push(hidden)
AboutPage *about_page(void);
#pragma GCC visibility pop

#endif
