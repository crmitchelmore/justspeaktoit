/* Model and microphone pickers: their state, owned by LinuxWindowModels.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_MODELS_PAGE_H
#define JSTI_LINUX_WINDOW_MODELS_PAGE_H

#include "LinuxWindowInternal.h"

typedef struct ModelsPage {
    GtkStringList *model_names;
    GArray *model_slots;
    Models *model_catalog;
    gint32 preferred_model_slots[4];
    AdwComboRow *model_row;
    GtkLabel *catalog_status;
    GtkButton *catalog_refresh;
    AdwPasswordEntryRow *key_row;
    /* Shown while an Azure model is selected: live routes need the endpoint. */
    AdwEntryRow *azure_row;
    GtkStringList *microphone_names;
    GPtrArray *microphone_ids;
    AdwComboRow *microphone_row;
} ModelsPage;

#pragma GCC visibility push(hidden)
ModelsPage *models_page(void);
#pragma GCC visibility pop

#endif
