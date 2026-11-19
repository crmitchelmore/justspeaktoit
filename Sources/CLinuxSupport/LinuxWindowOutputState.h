/* Text output, app switching and shortcut rows: their state. Private to
 * LinuxWindowOutput.c; the window self-tests also include it to inspect it.
 * Every other unit uses the functions in LinuxWindowOutputPage.h. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_OUTPUT_STATE_H
#define JSTI_LINUX_WINDOW_OUTPUT_STATE_H

#include "LinuxWindowOutputPage.h"

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
