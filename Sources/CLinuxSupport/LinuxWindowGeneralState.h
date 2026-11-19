/* General's appearance, Launch at login and automation rows: their state,
 * private to LinuxWindowSettingsPages.c, which builds and applies it; the
 * window self-tests also include it to inspect it. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_GENERAL_STATE_H
#define JSTI_LINUX_WINDOW_GENERAL_STATE_H

#include "LinuxWindowInternal.h"

typedef struct GeneralPage {
    AdwComboRow *appearance_row;
    AdwSwitchRow *login_row;
    AdwSwitchRow *automation_row;
} GeneralPage;

#pragma GCC visibility push(hidden)
GeneralPage *general_page(void);
#pragma GCC visibility pop

#endif
