#include "LinuxSupportInternal.h"
#include <adwaita.h>

typedef struct CleanupRow {
    AdwActionRow *row;
    GtkButton *download, *cancel, *remove;
} CleanupRow;
typedef struct CleanupUpdate {
    GPtrArray *ids, *names, *details;
    GArray *states;
    char *status;
    JSTILocalCleanupCallback callback;
    void *context;
} CleanupUpdate;
static struct {
    AdwPreferencesGroup *group;
    AdwEntryRow *repository, *filename;
    GArray *rows;
    JSTILocalCleanupCallback callback;
    void *context;
} cleanup;

typedef struct Removal {
    char *identifier;
    JSTILocalCleanupCallback callback;
    void *context;
} Removal;

static void remove_confirmed(GObject *source, GAsyncResult *result, gpointer pointer) {
    Removal *removal = pointer;
    GError *error = NULL;
    int selected = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, &error);
    if (error != NULL) {
        if (!g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_DISMISSED)
            && !g_error_matches(error, GTK_DIALOG_ERROR, GTK_DIALOG_ERROR_CANCELLED)) {
            jsti_window_update(error->message, NULL, -1);
        }
        g_error_free(error);
    } else if (selected == 1 && removal->callback == cleanup.callback && removal->context == cleanup.context) {
        removal->callback(2, removal->identifier, "", "", removal->context);
    }
    g_free(removal->identifier);
    g_free(removal);
}

static void action(GtkButton *button, gpointer data) {
    const gint32 kind = GPOINTER_TO_INT(data);
    const char *identifier = g_object_get_data(G_OBJECT(button), "cleanup-id");
    if (cleanup.callback == NULL || identifier == NULL) {
        jsti_window_update("Local cleanup controls are not connected.", NULL, -1); return;
    }
    if (kind == 2) {
        GtkAlertDialog *dialog = gtk_alert_dialog_new("Remove these downloaded GGUF weights?");
        gtk_alert_dialog_set_detail(dialog, "The model reference, selection and History are retained.");
        const char *buttons[] = {"Cancel", "Remove weights", NULL};
        gtk_alert_dialog_set_buttons(dialog, buttons);
        gtk_alert_dialog_set_cancel_button(dialog, 0);
        gtk_alert_dialog_set_default_button(dialog, 0);
        Removal *removal = g_new0(Removal, 1);
        removal->identifier = g_strdup(identifier);
        removal->callback = cleanup.callback;
        removal->context = cleanup.context;
        gtk_alert_dialog_choose(dialog, GTK_WINDOW(gtk_widget_get_root(GTK_WIDGET(button))),
            NULL, remove_confirmed, removal);
        g_object_unref(dialog);
    } else cleanup.callback(kind, identifier, "", "", cleanup.context);
}

static GtkButton *button(const char *label, gint32 kind) {
    GtkButton *value = GTK_BUTTON(gtk_button_new_with_label(label));
    gtk_widget_set_valign(GTK_WIDGET(value), GTK_ALIGN_CENTER);
    g_signal_connect(value, "clicked", G_CALLBACK(action), GINT_TO_POINTER(kind));
    return value;
}

static void import_reference(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (cleanup.callback == NULL) {
        jsti_window_update("Local cleanup controls are not connected.", NULL, -1); return;
    }
    cleanup.callback(4, "", gtk_editable_get_text(GTK_EDITABLE(cleanup.repository)),
        gtk_editable_get_text(GTK_EDITABLE(cleanup.filename)), cleanup.context);
}

struct _GtkWidget *jsti_local_cleanup_group_new(void) {
    cleanup.group = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(cleanup.group, "Downloaded local LLMs");
    adw_preferences_group_set_description(cleanup.group,
        "Import pins public metadata; Download verifies weights. Native CPU inference stays in process. "
        "Runtime installation is supplied by the app package, not a Python sidecar.");
    cleanup.rows = g_array_new(FALSE, TRUE, sizeof(CleanupRow));
    cleanup.repository = ADW_ENTRY_ROW(adw_entry_row_new());
    cleanup.filename = ADW_ENTRY_ROW(adw_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cleanup.repository), "Hugging Face owner/repository");
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(cleanup.filename), "Unsplit GGUF filename");
    adw_preferences_group_add(cleanup.group, GTK_WIDGET(cleanup.repository));
    adw_preferences_group_add(cleanup.group, GTK_WIDGET(cleanup.filename));
    GtkWidget *import = gtk_button_new_with_label("Import immutable GGUF reference");
    g_signal_connect(import, "clicked", G_CALLBACK(import_reference), NULL);
    adw_preferences_group_add(cleanup.group, import);
    GtkButton *cancel = button("Cancel model operation", 3);
    g_object_set_data_full(G_OBJECT(cancel), "cleanup-id", g_strdup(""), g_free);
    adw_preferences_group_add(cleanup.group, GTK_WIDGET(cancel));
    return GTK_WIDGET(cleanup.group);
}

static void apply(gpointer pointer) {
    CleanupUpdate *update = pointer;
    if (cleanup.group == NULL) return;
    cleanup.callback = update->callback; cleanup.context = update->context;
    adw_preferences_group_set_description(cleanup.group, update->status);
    while (cleanup.rows->len > update->ids->len) {
        CleanupRow row = g_array_index(cleanup.rows, CleanupRow, cleanup.rows->len - 1);
        adw_preferences_group_remove(cleanup.group, GTK_WIDGET(row.row));
        g_array_set_size(cleanup.rows, cleanup.rows->len - 1);
    }
    while (cleanup.rows->len < update->ids->len) {
        CleanupRow row = {
            .row = ADW_ACTION_ROW(adw_action_row_new()),
            .download = button("Download", 1), .cancel = button("Cancel", 3), .remove = button("Remove", 2)
        };
        adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row.row), FALSE);
        adw_action_row_set_subtitle_lines(row.row, 0);
        adw_action_row_add_suffix(row.row, GTK_WIDGET(row.download));
        adw_action_row_add_suffix(row.row, GTK_WIDGET(row.cancel));
        adw_action_row_add_suffix(row.row, GTK_WIDGET(row.remove));
        adw_preferences_group_add(cleanup.group, GTK_WIDGET(row.row));
        g_array_append_val(cleanup.rows, row);
    }
    for (guint i = 0; i < update->ids->len; ++i) {
        CleanupRow *row = &g_array_index(cleanup.rows, CleanupRow, i);
        const gint32 state = g_array_index(update->states, gint32, i);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row->row), g_ptr_array_index(update->names, i));
        adw_action_row_set_subtitle(row->row, g_ptr_array_index(update->details, i));
        GtkButton *buttons[] = {row->download, row->cancel, row->remove};
        for (size_t j = 0; j < 3; ++j) {
            g_object_set_data_full(G_OBJECT(buttons[j]), "cleanup-id", g_strdup(g_ptr_array_index(update->ids, i)), g_free);
        }
        gtk_button_set_label(row->download, state == 1 ? "Resume download" : "Download");
        gtk_widget_set_visible(GTK_WIDGET(row->download), state == 0 || state == 1);
        gtk_widget_set_visible(GTK_WIDGET(row->cancel), state == 2);
        gtk_widget_set_visible(GTK_WIDGET(row->remove), state == 1 || state == 3);
    }
}

static void free_update(gpointer pointer) {
    CleanupUpdate *update = pointer;
    g_ptr_array_unref(update->ids); g_ptr_array_unref(update->names); g_ptr_array_unref(update->details);
    g_array_unref(update->states); g_free(update->status); g_free(update);
}

int32_t jsti_window_set_local_cleanup(
    const JSTILocalCleanupRow *rows, size_t count, const char *status, JSTILocalCleanupCallback callback, void *context) {
    if ((!rows && count) || count > 128 || !status || !callback) return -1;
    CleanupUpdate *update = g_new0(CleanupUpdate, 1);
    update->ids = g_ptr_array_new_with_free_func(g_free);
    update->names = g_ptr_array_new_with_free_func(g_free);
    update->details = g_ptr_array_new_with_free_func(g_free);
    update->states = g_array_new(FALSE, FALSE, sizeof(gint32));
    update->status = g_strdup(status); update->callback = callback; update->context = context;
    for (size_t i = 0; i < count; ++i) {
        if (!rows[i].identifier || !rows[i].name || !rows[i].detail) { free_update(update); return -1; }
        g_ptr_array_add(update->ids, g_strdup(rows[i].identifier));
        g_ptr_array_add(update->names, g_strdup(rows[i].name));
        g_ptr_array_add(update->details, g_strdup(rows[i].detail));
        g_array_append_val(update->states, rows[i].state);
    }
    return jsti_window_post(apply, update, free_update);
}
