/* General: the appearance, Launch at login and automation rows,
 * owned by LinuxWindowSettingsPages.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_GENERAL_PAGE_H
#define JSTI_LINUX_WINDOW_GENERAL_PAGE_H

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
