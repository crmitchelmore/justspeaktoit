/* The model catalogue, model preferences and microphones. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowDashboardPage.h"
#include "LinuxWindowModelsPage.h"

static ModelsPage models_state;
ModelsPage *models_page(void) { return &models_state; }

guint model_mode(gboolean local, gboolean live) { return (local ? 2 : 0) + (live ? 1 : 0); }

static gint compare_order(gconstpointer left, gconstpointer right, gpointer orders) {
    gint32 a = g_array_index((GArray *)orders, gint32, ((const Slot *)left)->global);
    gint32 b = g_array_index((GArray *)orders, gint32, ((const Slot *)right)->global);
    return a - b;
}

static Models *models_copy(const JSTIModelRow *rows, size_t count, gint32 selected) {
    Models *models = g_new0(Models, 1);
    models->slots = g_array_new(FALSE, TRUE, sizeof(Slot));
    models->names = g_ptr_array_new_with_free_func(g_free);
    models->selected = selected;
    GArray *orders = g_array_sized_new(FALSE, TRUE, sizeof(gint32), (guint)count);
    for (size_t index = 0; index < count; index++) {
        g_array_append_val(orders, rows[index].display_order);
        if (rows[index].display_order < 0) continue;
        Slot slot = { .id = g_strdup(rows[index].id), .global = (gint32)index, .live = rows[index].is_live != 0 };
        g_array_append_val(models->slots, slot);
    }
    g_array_sort_with_data(models->slots, compare_order, orders);
    for (guint index = 0; index < models->slots->len; index++) {
        const JSTIModelRow *row = &rows[g_array_index(models->slots, Slot, index).global];
        g_ptr_array_add(models->names, row->is_live ? g_strdup_printf("Live · %s", row->name) : g_strdup(row->name));
    }
    g_array_unref(orders);
    return models;
}

void models_free(gpointer pointer) {
    Models *models = pointer;
    for (guint index = 0; index < models->slots->len; index++) g_free(g_array_index(models->slots, Slot, index).id);
    g_array_unref(models->slots);
    g_ptr_array_unref(models->names);
    g_free(models->status);
    g_free(models);
}

void filter_models(gint32 keep) {
    Models *models = models_page()->model_catalog;
    if (models == NULL) return;
    gboolean local = jsti_model_filters_local(), live = jsti_model_filters_live();
    ui.suppress = TRUE;
    if (models_page()->model_slots != NULL) {
        for (guint index = 0; index < models_page()->model_slots->len; index++) g_free(g_array_index(models_page()->model_slots, Slot, index).id);
        g_array_unref(models_page()->model_slots);
    }
    models_page()->model_slots = g_array_new(FALSE, TRUE, sizeof(Slot));
    GPtrArray *names = g_ptr_array_new();
    guint position = GTK_INVALID_LIST_POSITION;
    for (guint index = 0; index < models->slots->len; index++) {
        Slot slot = g_array_index(models->slots, Slot, index);
        if (g_str_has_prefix(slot.id, "local/") != local || slot.live != live) continue;
        Slot copy = { .id = g_strdup(slot.id), .global = slot.global, .live = slot.live };
        g_array_append_val(models_page()->model_slots, copy);
        g_ptr_array_add(names, g_ptr_array_index(models->names, index));
        if (slot.global == keep) position = models_page()->model_slots->len - 1;
    }
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(models_page()->model_names));
    g_ptr_array_add(names, NULL);
    gtk_string_list_splice(models_page()->model_names, 0, existing, (const char *const *)names->pdata);
    g_ptr_array_unref(names);
    adw_combo_row_set_selected(models_page()->model_row, position != GTK_INVALID_LIST_POSITION ? position :
                               (models_page()->model_slots->len > 0 ? 0 : GTK_INVALID_LIST_POSITION));
    refresh_azure_row();
    ui.suppress = FALSE;
    refresh_setup();
}

void on_model_filter(gboolean local, gboolean live) {
    guint mode = model_mode(local, live);
    filter_models(models_page()->preferred_model_slots[mode]);
    gint32 selected = selected_model_slot();
    if (selected >= 0) {
        models_page()->preferred_model_slots[mode] = selected;
        emit(JSTI_EVENT_SELECT_MODEL, "", selected);
    }
}

static void models_apply(gpointer pointer) {
    Models *models = pointer;
    gint32 keep = models->selected >= 0 ? models->selected : selected_model_slot();
    if (models_page()->model_catalog != NULL) models_free(models_page()->model_catalog);
    models_page()->model_catalog = g_new0(Models, 1);
    models_page()->model_catalog->slots = g_array_new(FALSE, TRUE, sizeof(Slot));
    models_page()->model_catalog->names = g_ptr_array_new_with_free_func(g_free);
    for (guint index = 0; index < models->slots->len; index++) {
        Slot slot = g_array_index(models->slots, Slot, index);
        Slot copy = { .id = g_strdup(slot.id), .global = slot.global, .live = slot.live };
        g_array_append_val(models_page()->model_catalog->slots, copy);
        g_ptr_array_add(models_page()->model_catalog->names, g_strdup(g_ptr_array_index(models->names, index)));
        if (slot.global == keep) {
            gboolean local = g_str_has_prefix(slot.id, "local/");
            jsti_model_filters_select(local, slot.live);
            models_page()->preferred_model_slots[model_mode(local, slot.live)] = keep;
        }
    }
    filter_models(keep);
    if (models->status != NULL) gtk_label_set_text(models_page()->catalog_status, models->status);
    gtk_widget_set_sensitive(GTK_WIDGET(models_page()->catalog_refresh), !models->refreshing);
}

void apply_models(const JSTIModelRow *rows, size_t count, gint32 selected) {
    Models *models = models_copy(rows, count, selected);
    models_apply(models);
    models_free(models);
}

int32_t jsti_window_set_model_catalog(
    const JSTIModelRow *rows, size_t count, int32_t selected, const char *status, int32_t refreshing) {
    Models *models = models_copy(rows, count, selected);
    models->status = g_strdup(status);
    models->refreshing = refreshing != 0;
    return post(models_apply, models, models_free);
}

void model_preferences_apply(gpointer pointer) {
    memcpy(models_page()->preferred_model_slots, pointer, sizeof(models_page()->preferred_model_slots));
}

int32_t jsti_window_set_preferred_models(int32_t batch, int32_t live, int32_t local, int32_t local_live) {
    if (batch < -1 || live < -1 || local < -1 || local_live < -1) return -1;
    const gint32 values[] = { batch, live, local, local_live };
    return post(model_preferences_apply, g_memdup2(values, sizeof(values)), g_free);
}

void local_model_preferences_apply(gpointer pointer) {
    const gint32 *values = pointer;
    guint active = model_mode(jsti_model_filters_local(), jsti_model_filters_live());
    for (guint i = 0; i < 2; ++i) {
        if (values[i] < 0 || active == i + 2) continue;
        gboolean found = FALSE;
        for (guint j = 0; models_page()->model_catalog != NULL && j < models_page()->model_catalog->slots->len; ++j) {
            Slot slot = g_array_index(models_page()->model_catalog->slots, Slot, j);
            if (slot.global == values[i] && slot.live == (i != 0) && g_str_has_prefix(slot.id, "local/")) {
                found = TRUE;
                break;
            }
        }
        if (found) models_page()->preferred_model_slots[i + 2] = values[i];
        else gtk_label_set_text(dashboard_page()->status, "Saved Local model choice is unavailable. Reopen the app before switching modes.");
    }
}

int32_t jsti_window_set_local_model_preferences(int32_t batch, int32_t live) {
    if (batch < -1 || live < -1) return -1;
    const gint32 values[] = { batch, live };
    return post(local_model_preferences_apply, g_memdup2(values, sizeof(values)), g_free);
}

typedef struct Microphones {
    GPtrArray *ids;
    GPtrArray *names;
    gchar *selected;
} Microphones;

static void microphones_free(gpointer pointer) {
    Microphones *microphones = pointer;
    g_ptr_array_unref(microphones->ids);
    g_ptr_array_unref(microphones->names);
    g_free(microphones->selected);
    g_free(microphones);
}

static void microphones_apply(gpointer pointer) {
    Microphones *microphones = pointer;
    ui.suppress = TRUE;
    g_ptr_array_set_size(models_page()->microphone_ids, 0);
    guint position = 0;
    for (guint index = 0; index < microphones->ids->len; index++) {
        const char *id = g_ptr_array_index(microphones->ids, index);
        g_ptr_array_add(models_page()->microphone_ids, g_strdup(id));
        if (g_strcmp0(id, microphones->selected) == 0) position = index;
    }
    guint existing = g_list_model_get_n_items(G_LIST_MODEL(models_page()->microphone_names));
    g_ptr_array_add(microphones->names, NULL);
    gtk_string_list_splice(models_page()->microphone_names, 0, existing, (const char *const *)microphones->names->pdata);
    g_ptr_array_set_size(microphones->names, microphones->names->len - 1);
    adw_combo_row_set_selected(models_page()->microphone_row, position);
    ui.suppress = FALSE;
    refresh_setup();
}

int32_t jsti_window_set_microphones(
    const char *const *ids, const char *const *names, size_t count, const char *selected) {
    Microphones *microphones = g_new0(Microphones, 1);
    microphones->ids = g_ptr_array_new_with_free_func(g_free);
    microphones->names = g_ptr_array_new_with_free_func(g_free);
    for (size_t index = 0; index < count; index++) {
        g_ptr_array_add(microphones->ids, g_strdup(ids[index]));
        g_ptr_array_add(microphones->names, g_strdup(names[index]));
    }
    microphones->selected = g_strdup(selected);
    return post(microphones_apply, microphones, microphones_free);
}
