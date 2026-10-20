#include "LinuxSupportInternal.h"
#include <adwaita.h>

static struct {
    AdwComboRow *source, *mode;
    gboolean suppress, idle, remote_live, local_live;
    void (*changed)(gboolean local, gboolean live);
} filters;

gboolean jsti_model_filters_local(void) { return adw_combo_row_get_selected(filters.source) == 1; }
gboolean jsti_model_filters_live(void) {
    return adw_combo_row_get_selected(filters.mode) == 1;
}
gboolean jsti_model_filters_preferred_live(gboolean local) {
    return local ? filters.local_live : filters.remote_live;
}

void jsti_model_filters_set_idle(gboolean idle) {
    filters.idle = idle;
    gtk_widget_set_sensitive(GTK_WIDGET(filters.source), idle);
    gtk_widget_set_sensitive(GTK_WIDGET(filters.mode), idle);
}

void jsti_model_filters_select(gboolean local, gboolean live) {
    filters.suppress = TRUE;
    adw_combo_row_set_selected(filters.source, local ? 1 : 0);
    if (local) filters.local_live = live;
    else filters.remote_live = live;
    adw_combo_row_set_selected(filters.mode, live ? 1 : 0);
    jsti_model_filters_set_idle(filters.idle);
    filters.suppress = FALSE;
}

static void on_source(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (filters.suppress) return;
    gboolean local = jsti_model_filters_local();
    jsti_model_filters_select(local, local ? filters.local_live : filters.remote_live);
    if (filters.changed) filters.changed(local, jsti_model_filters_live());
}

static void on_mode(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    if (filters.suppress) return;
    gboolean local = jsti_model_filters_local(), live = jsti_model_filters_live();
    if (local) filters.local_live = live;
    else filters.remote_live = live;
    if (filters.changed) filters.changed(local, live);
}

void jsti_model_filters_add(struct _GtkWidget *group, void (*changed)(gboolean local, gboolean live)) {
    const char *sources[] = {"Remote", "Local", NULL};
    const char *modes[] = {"Batch", "Live", NULL};
    GtkStringList *source_names = gtk_string_list_new(sources), *mode_names = gtk_string_list_new(modes);
    filters.source = ADW_COMBO_ROW(adw_combo_row_new());
    filters.mode = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(filters.source), "Source");
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(filters.mode), "Mode");
    adw_combo_row_set_model(filters.source, G_LIST_MODEL(source_names));
    adw_combo_row_set_model(filters.mode, G_LIST_MODEL(mode_names));
    g_object_unref(source_names); g_object_unref(mode_names);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(filters.source));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(filters.mode));
    filters.changed = changed;
    filters.idle = TRUE;
    g_signal_connect(filters.source, "notify::selected", G_CALLBACK(on_source), NULL);
    g_signal_connect(filters.mode, "notify::selected", G_CALLBACK(on_mode), NULL);
}

static struct { guint count; gboolean local, live; } recorded;
static void record_change(gboolean local, gboolean live) {
    recorded.count++;
    recorded.local = local;
    recorded.live = live;
}

int32_t jsti_model_filters_self_test(char *error, size_t capacity) {
    gboolean local = jsti_model_filters_local(), live = jsti_model_filters_live();
    gboolean idle = filters.idle, remote_live = filters.remote_live, local_live = filters.local_live;
    void (*changed)(gboolean, gboolean) = filters.changed;
    filters.changed = record_change;
    guint before = recorded.count;
    jsti_model_filters_select(TRUE, FALSE);
    jsti_model_filters_select(FALSE, FALSE);
    jsti_model_filters_set_idle(TRUE);
    gboolean quiet = recorded.count == before;
    adw_combo_row_set_selected(filters.mode, 1);
    gboolean remote = recorded.count == before + 1 && !recorded.local && recorded.live &&
        gtk_widget_get_sensitive(GTK_WIDGET(filters.mode));
    adw_combo_row_set_selected(filters.source, 1);
    gboolean local_batch = recorded.count == before + 2 && recorded.local && !recorded.live &&
        jsti_model_filters_local() && !jsti_model_filters_live() &&
        gtk_widget_get_sensitive(GTK_WIDGET(filters.mode));
    adw_combo_row_set_selected(filters.mode, 1);
    gboolean local_live_selected = recorded.count == before + 3 && recorded.local && recorded.live &&
        jsti_model_filters_local() && jsti_model_filters_live();
    adw_combo_row_set_selected(filters.source, 0);
    gboolean remote_remembered = recorded.count == before + 4 && !recorded.local && recorded.live;
    adw_combo_row_set_selected(filters.mode, 0);
    adw_combo_row_set_selected(filters.source, 1);
    gboolean local_remembered = recorded.count == before + 6 && recorded.local && recorded.live;
    jsti_model_filters_set_idle(FALSE);
    gboolean busy = !gtk_widget_get_sensitive(GTK_WIDGET(filters.source)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(filters.mode));
    jsti_model_filters_set_idle(TRUE);
    busy = busy && gtk_widget_get_sensitive(GTK_WIDGET(filters.source)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(filters.mode));
    jsti_model_filters_select(local, live);
    filters.remote_live = remote_live;
    filters.local_live = local_live;
    jsti_model_filters_set_idle(idle);
    filters.changed = changed;
    if (!quiet || !remote || !local_batch || !local_live_selected || !remote_remembered || !local_remembered || !busy) {
        jsti_set_error(error, capacity, "Model filters did not preserve independent Local/Remote Batch/Live modes.");
        return -1;
    }
    return 0;
}
