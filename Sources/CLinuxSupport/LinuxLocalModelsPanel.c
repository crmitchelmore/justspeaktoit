#include "LinuxWindowInternal.h"

/*
 * On-device models: one row per downloadable whisper.cpp model with a single
 * action for its state, the runtime status line and the GPU preference.
 * Swift owns downloads, verification and removal; rows only report clicks.
 */

typedef struct LocalPanel {
    AdwPreferencesGroup *group;
    GtkLabel *status;
    AdwSwitchRow *gpu_row;
    GPtrArray *rows; /* AdwActionRow* owned by the group */
    gboolean idle;
} LocalPanel;

static LocalPanel local = { .idle = TRUE };

static void on_gpu(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    jsti_window_emit(JSTI_EVENT_LOCAL_GPU, "", adw_switch_row_get_active(local.gpu_row) ? 1 : 0);
}

static void on_action(GtkButton *button, gpointer data) {
    const char *action = g_object_get_data(G_OBJECT(button), "jsti-action");
    jsti_window_emit(JSTI_EVENT_LOCAL_MODEL, action != NULL ? action : "", GPOINTER_TO_INT(data));
}

void jsti_window_local_models_build(AdwPreferencesPage *page) {
    local.group = ADW_PREFERENCES_GROUP(jsti_window_group("On-device models"));
    adw_preferences_group_set_description(
        local.group, "Transcribe without sending audio anywhere, using whisper.cpp on this computer. "
                     "Download a model, then choose it in the model list.");
    local.status = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(local.status, TRUE);
    gtk_label_set_xalign(local.status, 0);
    gtk_widget_add_css_class(GTK_WIDGET(local.status), "dim-label");
    gtk_widget_set_margin_bottom(GTK_WIDGET(local.status), 6);
    adw_preferences_group_add(local.group, GTK_WIDGET(local.status));
    local.gpu_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(local.gpu_row), "Use the GPU when available (Vulkan)");
    g_signal_connect(local.gpu_row, "notify::active", G_CALLBACK(on_gpu), NULL);
    adw_preferences_group_add(local.group, GTK_WIDGET(local.gpu_row));
    local.rows = g_ptr_array_new();
    adw_preferences_page_add(page, local.group);
}

void jsti_window_local_models_refresh(gboolean idle) {
    local.idle = idle;
    if (local.rows == NULL) return;
    for (guint index = 0; index < local.rows->len; index++) {
        GtkWidget *button = g_object_get_data(G_OBJECT(g_ptr_array_index(local.rows, index)), "jsti-button");
        const char *action = button != NULL ? g_object_get_data(G_OBJECT(button), "jsti-action") : NULL;
        /* Cancelling a download stays possible while the app is busy. */
        if (button != NULL) gtk_widget_set_sensitive(button, idle || g_strcmp0(action, "cancel") == 0);
    }
}

typedef struct LocalView {
    GPtrArray *names, *details, *abouts;
    GArray *states;
    gchar *status;
    gboolean use_gpu;
} LocalView;

static void local_view_free(gpointer pointer) {
    LocalView *view = pointer;
    g_ptr_array_unref(view->names);
    g_ptr_array_unref(view->details);
    g_ptr_array_unref(view->abouts);
    g_array_unref(view->states);
    g_free(view->status);
    g_free(view);
}

static void local_view_apply(gpointer pointer) {
    LocalView *view = pointer;
    jsti_window_set_suppressed(TRUE);
    gtk_label_set_text(local.status, view->status != NULL ? view->status : "");
    adw_switch_row_set_active(local.gpu_row, view->use_gpu);
    for (guint index = 0; index < local.rows->len; index++) {
        adw_preferences_group_remove(local.group, GTK_WIDGET(g_ptr_array_index(local.rows, index)));
    }
    g_ptr_array_set_size(local.rows, 0);
    for (guint index = 0; index < view->names->len; index++) {
        GtkWidget *row = adw_action_row_new();
        adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row), FALSE);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), g_ptr_array_index(view->names, index));
        adw_action_row_set_subtitle(ADW_ACTION_ROW(row), g_ptr_array_index(view->details, index));
        gtk_widget_set_tooltip_text(row, g_ptr_array_index(view->abouts, index));
        gint32 state = g_array_index(view->states, gint32, index);
        const char *label = "Download", *action = "download";
        switch (state) {
        case JSTI_LOCAL_MODEL_PARTIAL: label = "Resume"; break;
        case JSTI_LOCAL_MODEL_DOWNLOADING: label = "Cancel"; action = "cancel"; break;
        case JSTI_LOCAL_MODEL_INSTALLED: label = "Remove"; action = "remove"; break;
        default: break;
        }
        GtkWidget *button = gtk_button_new_with_label(label);
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER);
        if (state == JSTI_LOCAL_MODEL_INSTALLED) gtk_widget_add_css_class(button, "destructive-action");
        g_object_set_data(G_OBJECT(button), "jsti-action", (gpointer)action);
        g_signal_connect(button, "clicked", G_CALLBACK(on_action), GINT_TO_POINTER((gint)index));
        adw_action_row_add_suffix(ADW_ACTION_ROW(row), button);
        g_object_set_data(G_OBJECT(row), "jsti-button", button);
        adw_preferences_group_add(local.group, row);
        g_ptr_array_add(local.rows, row);
    }
    jsti_window_set_suppressed(FALSE);
    jsti_window_local_models_refresh(local.idle);
}

int32_t jsti_window_set_local_models(
    const JSTILocalModelRow *rows, size_t count, const char *status, int32_t use_gpu) {
    if (count > 0 && rows == NULL) return -1;
    LocalView *view = g_new0(LocalView, 1);
    view->names = g_ptr_array_new_with_free_func(g_free);
    view->details = g_ptr_array_new_with_free_func(g_free);
    view->abouts = g_ptr_array_new_with_free_func(g_free);
    view->states = g_array_new(FALSE, TRUE, sizeof(gint32));
    for (size_t index = 0; index < count; index++) {
        g_ptr_array_add(view->names, g_strdup(rows[index].name != NULL ? rows[index].name : ""));
        g_ptr_array_add(view->details, g_strdup(rows[index].detail != NULL ? rows[index].detail : ""));
        g_ptr_array_add(view->abouts, g_strdup(rows[index].about != NULL ? rows[index].about : ""));
        g_array_append_val(view->states, rows[index].state);
    }
    view->status = g_strdup(status);
    view->use_gpu = use_gpu != 0;
    return jsti_window_post(local_view_apply, view, local_view_free);
}
