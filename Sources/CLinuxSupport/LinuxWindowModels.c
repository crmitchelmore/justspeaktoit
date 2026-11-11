/* The model catalogue, model preferences and microphones: the Transcription
 * Model group and the General Microphone group. Owns ModelsPage
 * (LinuxWindowModelsState.h). */
#include "LinuxWindowModelsState.h"

static ModelsPage models_state;
ModelsPage *models_page(void) { return &models_state; }

guint model_mode(gboolean local, gboolean live) { return (local ? 2 : 0) + (live ? 1 : 0); }

gint32 selected_model_slot(void) {
    guint position = adw_combo_row_get_selected(models_page()->model_row);
    if (models_page()->model_slots == NULL || position == GTK_INVALID_LIST_POSITION || position >= models_page()->model_slots->len) {
        return -1;
    }
    return g_array_index(models_page()->model_slots, Slot, position).global;
}

const char *selected_microphone(void) {
    guint position = adw_combo_row_get_selected(models_page()->microphone_row);
    if (models_page()->microphone_ids == NULL || position == GTK_INVALID_LIST_POSITION || position >= models_page()->microphone_ids->len) {
        return "";
    }
    return g_ptr_array_index(models_page()->microphone_ids, position);
}

/* The Azure resource row belongs to Azure models only. */
static void refresh_azure_row(void) {
    guint position = adw_combo_row_get_selected(models_page()->model_row);
    gboolean azure = models_page()->model_slots != NULL && position != GTK_INVALID_LIST_POSITION && position < models_page()->model_slots->len
        && g_str_has_prefix(g_array_index(models_page()->model_slots, Slot, position).id, "azure/");
    gtk_widget_set_visible(GTK_WIDGET(models_page()->azure_row), azure);
    /* On-device models (canonical "local/" identifiers) need no API key. */
    gboolean local = models_page()->model_slots != NULL && position != GTK_INVALID_LIST_POSITION && position < models_page()->model_slots->len
        && g_str_has_prefix(g_array_index(models_page()->model_slots, Slot, position).id, "local/");
    gtk_widget_set_visible(GTK_WIDGET(models_page()->key_row), !local);
}


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
        else gtk_label_set_text(ui.status, "Saved Local model choice is unavailable. Reopen the app before switching modes.");
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

static void on_model(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    refresh_azure_row();
    refresh_setup();
    gint32 slot = selected_model_slot();
    if (!ui.suppress && slot >= 0) {
        guint mode = model_mode(jsti_model_filters_local(), jsti_model_filters_live());
        models_page()->preferred_model_slots[mode] = slot;
    }
    if (slot >= 0) emit(JSTI_EVENT_SELECT_MODEL, "", slot);
}

static void on_azure_apply(AdwEntryRow *row, gpointer data) {
    (void)data;
    emit(JSTI_EVENT_AZURE_RESOURCE, gtk_editable_get_text(GTK_EDITABLE(row)), 0);
}

static void on_microphone(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    refresh_setup();
    emit(JSTI_EVENT_SELECT_MICROPHONE, selected_microphone(), 0);
}

static void on_key_apply(AdwEntryRow *row, gpointer data) {
    (void)data;
    const char *key = gtk_editable_get_text(GTK_EDITABLE(row));
    emit(JSTI_EVENT_SAVE_KEY, key, selected_model_slot());
    gtk_editable_set_text(GTK_EDITABLE(row), "");
}

static void on_refresh(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    emit(JSTI_EVENT_REFRESH_MODELS, "", 0);
}

GtkWidget *models_group(void) {
    GtkWidget *models = group("Model");
    jsti_model_filters_add(models, on_model_filter);
    models_page()->model_names = gtk_string_list_new(NULL);
    models_page()->model_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(models_page()->model_row), "Transcription model");
    adw_combo_row_set_model(models_page()->model_row, G_LIST_MODEL(models_page()->model_names));
    adw_combo_row_set_enable_search(models_page()->model_row, TRUE);
    g_signal_connect(models_page()->model_row, "notify::selected", G_CALLBACK(on_model), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(models_page()->model_row));

    models_page()->key_row = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(models_page()->key_row), "API key for the selected provider");
    adw_entry_row_set_show_apply_button(ADW_ENTRY_ROW(models_page()->key_row), TRUE);
    g_signal_connect(models_page()->key_row, "apply", G_CALLBACK(on_key_apply), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(models_page()->key_row));

    /* Recorded audio falls back to the key's region; live Azure needs this. */
    models_page()->azure_row = ADW_ENTRY_ROW(adw_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(models_page()->azure_row),
                                  "Azure Speech resource endpoint (https://…cognitiveservices.azure.com)");
    adw_entry_row_set_show_apply_button(models_page()->azure_row, TRUE);
    adw_entry_row_set_input_purpose(models_page()->azure_row, GTK_INPUT_PURPOSE_URL);
    g_signal_connect(models_page()->azure_row, "apply", G_CALLBACK(on_azure_apply), NULL);
    gtk_widget_set_visible(GTK_WIDGET(models_page()->azure_row), FALSE);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), GTK_WIDGET(models_page()->azure_row));

    GtkWidget *catalog = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_set_margin_top(catalog, 8);
    models_page()->catalog_status = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(models_page()->catalog_status, TRUE);
    gtk_label_set_xalign(models_page()->catalog_status, 0);
    gtk_widget_set_hexpand(GTK_WIDGET(models_page()->catalog_status), TRUE);
    gtk_widget_add_css_class(GTK_WIDGET(models_page()->catalog_status), "dim-label");
    models_page()->catalog_refresh = GTK_BUTTON(gtk_button_new_with_label("Refresh models"));
    g_signal_connect(models_page()->catalog_refresh, "clicked", G_CALLBACK(on_refresh), NULL);
    gtk_box_append(GTK_BOX(catalog), GTK_WIDGET(models_page()->catalog_status));
    gtk_box_append(GTK_BOX(catalog), GTK_WIDGET(models_page()->catalog_refresh));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(models), catalog);
    return models;
}

GtkWidget *microphone_group(void) {
    GtkWidget *microphone = group("Microphone");
    models_page()->microphone_names = gtk_string_list_new(NULL);
    models_page()->microphone_ids = g_ptr_array_new_with_free_func(g_free);
    models_page()->microphone_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(models_page()->microphone_row), "Preferred microphone");
    adw_combo_row_set_model(models_page()->microphone_row, G_LIST_MODEL(models_page()->microphone_names));
    g_signal_connect(models_page()->microphone_row, "notify::selected", G_CALLBACK(on_microphone), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(microphone), GTK_WIDGET(models_page()->microphone_row));
    return microphone;
}

static void azure_apply(gpointer data) {
    ui.suppress = TRUE;
    gtk_editable_set_text(GTK_EDITABLE(models_page()->azure_row), data != NULL ? data : "");
    ui.suppress = FALSE;
}

int32_t jsti_window_set_azure_resource(const char *endpoint) {
    return post(azure_apply, g_strdup(endpoint != NULL ? endpoint : ""), g_free);
}

void models_refresh_actions(gboolean idle) {
    gtk_widget_set_sensitive(GTK_WIDGET(models_page()->model_row), idle);
    jsti_model_filters_set_idle(idle);
    gtk_widget_set_sensitive(GTK_WIDGET(models_page()->microphone_row), idle);
}

const char *models_model_name(void) { return combo_row_text(models_page()->model_row); }
const char *models_microphone_name(void) { return combo_row_text(models_page()->microphone_row); }

void models_close(void) {
    if (models_page()->model_catalog != NULL) { models_free(models_page()->model_catalog); models_page()->model_catalog = NULL; }
}
