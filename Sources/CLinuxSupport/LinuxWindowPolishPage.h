/* The Post-processing page: its state, owned by LinuxWindowPolish.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_POLISH_PAGE_H
#define JSTI_LINUX_WINDOW_POLISH_PAGE_H

#include "LinuxWindowInternal.h"

typedef struct PolishPage {
    AdwSwitchRow *polish_row;
    AdwComboRow *polish_model_row;
    GtkStringList *polish_models;
    AdwComboRow *polish_location_row;
    GPtrArray *polish_catalog;
    GArray *polish_slots;
    gint32 polish_local_index;
    gint32 polish_remote_selected;
    gint32 polish_local_selected;
    gchar *polish_local_notice;
    GtkTextView *polish_prompt_row;
    AdwPasswordEntryRow *polish_key_row;
    AdwSwitchRow *polish_directives_row;
    AdwSwitchRow *polish_tags_row;
    /* Remote models before the first local one; G_MAXUINT until the catalogue arrives. */
    guint polish_remote_count;
    GtkWidget *polish_local_group;
} PolishPage;

#pragma GCC visibility push(hidden)
PolishPage *polish_page(void);
#pragma GCC visibility pop

#endif
