/* Text output, app switching and shortcut rows: their state, owned by LinuxWindowSettingsPages.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_OUTPUT_PAGE_H
#define JSTI_LINUX_WINDOW_OUTPUT_PAGE_H

#include "LinuxWindowInternal.h"

typedef struct OutputPage {
    AdwPreferencesGroup *output_group;
    AdwComboRow *output_row;
    AdwComboRow *app_switch_row;
    GtkLabel *app_switch_help;
    gboolean app_switch_configured;
    AdwSwitchRow *restore_row;
    gboolean can_restore_clipboard;
    AdwActionRow *shortcut_row;
    AdwComboRow *style_row;
} OutputPage;

#pragma GCC visibility push(hidden)
OutputPage *output_page(void);
#pragma GCC visibility pop

#endif
