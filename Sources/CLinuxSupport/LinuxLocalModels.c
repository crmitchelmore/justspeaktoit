#include "LinuxSupportInternal.h"

#include <adwaita.h>

/*
 * The Local models group of the main window: one row per on-device model with
 * its size and state, Download (or Resume download), Cancel and Remove, and a
 * GPU switch when the runtime has a GPU backend. Like the rest of the window
 * it owns no state: buttons report events 50-53 and Swift pushes each change
 * back through jsti_window_set_local_models. Rows are updated in place, so a
 * progress update never replaces a button under the pointer.
 */

typedef struct LocalRow {
    AdwActionRow *row;
    GtkButton *download;
    GtkButton *cancel;
    GtkButton *remove;
} LocalRow;

typedef struct LocalModels {
    GPtrArray *names;
    GPtrArray *details;
    GPtrArray *abouts;
    GArray *states;
    gchar *status;
    gint32 gpu;
} LocalModels;

static struct {
    AdwPreferencesGroup *group;
    AdwSwitchRow *gpu;
    GArray *rows;
    gboolean suppress;
    /* The last update from Swift, restored after the self-test. */
    LocalModels *current;
} local;

/* Replaced by the self-test to observe events without reaching Swift. */
static void (*emit_event)(gint32 event, const char *text, gint32 index) = jsti_window_emit;

static void on_action(GtkButton *button, gpointer data) {
    gint32 index = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "jsti-row"));
    emit_event(GPOINTER_TO_INT(data), "", index);
}

static void on_gpu(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (!local.suppress) emit_event(JSTI_EVENT_LOCAL_MODEL_GPU, "", adw_switch_row_get_active(local.gpu) ? 1 : 0);
}

static GtkButton *action_button(const char *label, gint32 event, gint32 index) {
    GtkButton *button = GTK_BUTTON(gtk_button_new_with_label(label));
    gtk_widget_set_valign(GTK_WIDGET(button), GTK_ALIGN_CENTER);
    g_object_set_data(G_OBJECT(button), "jsti-row", GINT_TO_POINTER(index));
    g_signal_connect(button, "clicked", G_CALLBACK(on_action), GINT_TO_POINTER(event));
    return button;
}

struct _GtkWidget *jsti_local_models_group_new(void) {
    local.group = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(local.group, "Local models");
    adw_preferences_group_set_description(local.group, "Checking the on-device speech runtime…");
    local.rows = g_array_new(FALSE, TRUE, sizeof(LocalRow));
    local.gpu = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(local.gpu), "Use a Vulkan GPU when available");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(local.gpu), "Applies when the speech runtime next starts");
    gtk_widget_set_visible(GTK_WIDGET(local.gpu), FALSE);
    g_signal_connect(local.gpu, "notify::active", G_CALLBACK(on_gpu), NULL);
    adw_preferences_group_add(local.group, GTK_WIDGET(local.gpu));
    return GTK_WIDGET(local.group);
}

static void rebuild_rows(guint count) {
    for (guint index = 0; index < local.rows->len; index++) {
        adw_preferences_group_remove(local.group, GTK_WIDGET(g_array_index(local.rows, LocalRow, index).row));
    }
    g_array_set_size(local.rows, 0);
    /* The GPU switch stays below the models. */
    g_object_ref(local.gpu);
    adw_preferences_group_remove(local.group, GTK_WIDGET(local.gpu));
    for (guint index = 0; index < count; index++) {
        LocalRow row = {
            .row = ADW_ACTION_ROW(adw_action_row_new()),
            .download = action_button("Download", JSTI_EVENT_LOCAL_MODEL_DOWNLOAD, (gint32)index),
            .cancel = action_button("Cancel", JSTI_EVENT_LOCAL_MODEL_CANCEL, (gint32)index),
            .remove = action_button("Remove", JSTI_EVENT_LOCAL_MODEL_REMOVE, (gint32)index),
        };
        adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row.row), FALSE);
        adw_action_row_add_suffix(row.row, GTK_WIDGET(row.download));
        adw_action_row_add_suffix(row.row, GTK_WIDGET(row.cancel));
        adw_action_row_add_suffix(row.row, GTK_WIDGET(row.remove));
        adw_preferences_group_add(local.group, GTK_WIDGET(row.row));
        g_array_append_val(local.rows, row);
    }
    adw_preferences_group_add(local.group, GTK_WIDGET(local.gpu));
    g_object_unref(local.gpu);
}

static void apply_row(LocalRow *row, const char *name, const char *detail, const char *about, gint32 state) {
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row->row), name);
    adw_action_row_set_subtitle(row->row, detail);
    gtk_widget_set_tooltip_text(GTK_WIDGET(row->row), about);
    gtk_button_set_label(row->download, state == JSTI_LOCAL_MODEL_PARTIAL ? "Resume download" : "Download");
    gtk_widget_set_visible(GTK_WIDGET(row->download),
                           state == JSTI_LOCAL_MODEL_NOT_INSTALLED || state == JSTI_LOCAL_MODEL_PARTIAL);
    gtk_widget_set_visible(GTK_WIDGET(row->cancel), state == JSTI_LOCAL_MODEL_DOWNLOADING);
    /* A paused download's bytes can be removed too; a removal in progress
     * keeps its button, disabled, until it finishes. */
    gtk_widget_set_visible(GTK_WIDGET(row->remove), state == JSTI_LOCAL_MODEL_PARTIAL ||
                           state == JSTI_LOCAL_MODEL_INSTALLED || state == JSTI_LOCAL_MODEL_REMOVING);
    gtk_widget_set_sensitive(GTK_WIDGET(row->remove), state != JSTI_LOCAL_MODEL_REMOVING);
}

static void local_models_free(gpointer pointer) {
    LocalModels *models = pointer;
    if (models == NULL) return;
    g_ptr_array_unref(models->names);
    g_ptr_array_unref(models->details);
    g_ptr_array_unref(models->abouts);
    g_array_unref(models->states);
    g_free(models->status);
    g_free(models);
}

static LocalModels *local_models_new(const char *status, gint32 gpu) {
    LocalModels *models = g_new0(LocalModels, 1);
    models->names = g_ptr_array_new_with_free_func(g_free);
    models->details = g_ptr_array_new_with_free_func(g_free);
    models->abouts = g_ptr_array_new_with_free_func(g_free);
    models->states = g_array_new(FALSE, TRUE, sizeof(gint32));
    models->status = g_strdup(status != NULL ? status : "");
    models->gpu = gpu;
    return models;
}

static void local_models_add(LocalModels *models, const char *name, const char *detail, const char *about,
                             gint32 state) {
    g_ptr_array_add(models->names, g_strdup(name != NULL ? name : ""));
    g_ptr_array_add(models->details, g_strdup(detail != NULL ? detail : ""));
    g_ptr_array_add(models->abouts, g_strdup(about != NULL ? about : ""));
    g_array_append_val(models->states, state);
}

static LocalModels *local_models_dup(const LocalModels *source) {
    LocalModels *copy = local_models_new(source->status, source->gpu);
    for (guint index = 0; index < source->states->len; index++) {
        local_models_add(copy, g_ptr_array_index(source->names, index), g_ptr_array_index(source->details, index),
                         g_ptr_array_index(source->abouts, index), g_array_index(source->states, gint32, index));
    }
    return copy;
}

static void show(const LocalModels *models) {
    local.suppress = TRUE;
    adw_preferences_group_set_description(local.group, models->status);
    if (local.rows->len != models->states->len) rebuild_rows(models->states->len);
    for (guint index = 0; index < models->states->len; index++) {
        apply_row(&g_array_index(local.rows, LocalRow, index), g_ptr_array_index(models->names, index),
                  g_ptr_array_index(models->details, index), g_ptr_array_index(models->abouts, index),
                  g_array_index(models->states, gint32, index));
    }
    gtk_widget_set_visible(GTK_WIDGET(local.gpu), models->gpu >= 0);
    adw_switch_row_set_active(local.gpu, models->gpu == 1);
    local.suppress = FALSE;
}

static void local_models_apply(gpointer pointer) {
    if (local.group == NULL) return;
    LocalModels *models = pointer;
    show(models);
    local_models_free(local.current);
    local.current = local_models_dup(models);
}

int32_t jsti_window_set_local_models(
    const JSTILocalModelRow *rows, size_t count, const char *runtime_status, int32_t gpu) {
    if (count > 0 && rows == NULL) return -1;
    LocalModels *models = local_models_new(runtime_status, gpu);
    for (size_t index = 0; index < count; index++) {
        local_models_add(models, rows[index].name, rows[index].detail, rows[index].about, rows[index].state);
    }
    return jsti_window_post(local_models_apply, models, local_models_free);
}

/* ---------------------------------------------------------- self-test */

static struct {
    gint32 event;
    gint32 index;
    guint count;
} recorded;

static void record_event(gint32 event, const char *text, gint32 index) {
    (void)text;
    recorded.event = event;
    recorded.index = index;
    recorded.count++;
}

static gboolean clicked_reports(GtkButton *button, gint32 event, gint32 index) {
    guint before = recorded.count;
    g_signal_emit_by_name(button, "clicked");
    return recorded.count == before + 1 && recorded.event == event && recorded.index == index;
}

static const char *check_states(void) {
    LocalRow *rows = (LocalRow *)(void *)local.rows->data;
    if (local.rows->len != 5) return "the rows were not built";
    if (!gtk_widget_get_visible(GTK_WIDGET(rows[0].download)) || gtk_widget_get_visible(GTK_WIDGET(rows[0].remove)) ||
        gtk_widget_get_visible(GTK_WIDGET(rows[0].cancel))) return "a model that is not downloaded offers the wrong actions";
    if (g_strcmp0(gtk_button_get_label(rows[1].download), "Resume download") != 0 ||
        !gtk_widget_get_visible(GTK_WIDGET(rows[1].remove))) return "a paused download cannot be resumed or removed";
    if (!gtk_widget_get_visible(GTK_WIDGET(rows[2].cancel)) || gtk_widget_get_visible(GTK_WIDGET(rows[2].download)) ||
        gtk_widget_get_visible(GTK_WIDGET(rows[2].remove))) return "a running download cannot only be cancelled";
    if (!gtk_widget_get_visible(GTK_WIDGET(rows[3].remove)) || gtk_widget_get_visible(GTK_WIDGET(rows[3].download)) ||
        !gtk_widget_get_sensitive(GTK_WIDGET(rows[3].remove))) return "a downloaded model cannot only be removed";
    if (gtk_widget_get_sensitive(GTK_WIDGET(rows[4].remove)) || gtk_widget_get_visible(GTK_WIDGET(rows[4].download)))
        return "a model being removed still offers actions";
    if (g_strcmp0(adw_action_row_get_subtitle(rows[2].row), "Downloading 42% of 75 MB") != 0)
        return "a row does not show its state";
    if (gtk_widget_get_visible(GTK_WIDGET(local.gpu))) return "the GPU switch shows without a GPU backend";
    if (!clicked_reports(rows[1].download, JSTI_EVENT_LOCAL_MODEL_DOWNLOAD, 1) ||
        !clicked_reports(rows[2].cancel, JSTI_EVENT_LOCAL_MODEL_CANCEL, 2) ||
        !clicked_reports(rows[3].remove, JSTI_EVENT_LOCAL_MODEL_REMOVE, 3)) return "a button reported the wrong event";
    return NULL;
}

static const char *check_gpu(void) {
    if (!gtk_widget_get_visible(GTK_WIDGET(local.gpu)) || !adw_switch_row_get_active(local.gpu))
        return "the GPU switch does not show the saved choice";
    guint before = recorded.count;
    adw_switch_row_set_active(local.gpu, FALSE);
    if (recorded.count != before + 1 || recorded.event != JSTI_EVENT_LOCAL_MODEL_GPU || recorded.index != 0)
        return "turning the GPU off was not reported";
    return NULL;
}

int32_t jsti_local_models_self_test(char *error, size_t capacity) {
    if (local.group == NULL) {
        jsti_set_error(error, capacity, "Window self-test: the Local models group was not created");
        return -1;
    }
    LocalModels *saved = local.current != NULL ? local_models_dup(local.current) : NULL;
    emit_event = record_event;
    const JSTILocalModelRow rows[] = {
        { "Model A", "75 MB · Not downloaded", "About A", JSTI_LOCAL_MODEL_NOT_INSTALLED },
        { "Model B", "75 MB · 10% downloaded, paused", "About B", JSTI_LOCAL_MODEL_PARTIAL },
        { "Model C", "Downloading 42% of 75 MB", "About C", JSTI_LOCAL_MODEL_DOWNLOADING },
        { "Model D", "75 MB · Downloaded and verified", "About D", JSTI_LOCAL_MODEL_INSTALLED },
        { "Model E", "75 MB · Removing…", "About E", JSTI_LOCAL_MODEL_REMOVING },
    };
    LocalModels *models = local_models_new("Self-test runtime", -1);
    for (size_t index = 0; index < G_N_ELEMENTS(rows); index++) {
        local_models_add(models, rows[index].name, rows[index].detail, rows[index].about, rows[index].state);
    }
    show(models);
    const char *failure = check_states();
    if (failure == NULL) {
        models->gpu = 1;
        show(models);
        failure = check_gpu();
    }
    local_models_free(models);
    emit_event = jsti_window_emit;
    if (saved != NULL) {
        show(saved);
        local_models_free(saved);
    }
    if (failure != NULL) {
        jsti_set_error(error, capacity, "Window self-test: %s", failure);
        return -1;
    }
    return 0;
}
