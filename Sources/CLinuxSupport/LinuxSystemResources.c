#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <string.h>

/*
 * General > "System resources in use" (issue #1473): every resource the app
 * holds right now, why, since when, and a button to let it go. Swift owns the
 * holds (SystemResourceRegistry) and hands this group a finished view through
 * jsti_window_set_system_resources, applied in call order with the window's
 * other setters. Rows are matched by id and updated in place, so a periodic
 * refresh keeps keyboard focus on a row's button.
 */

typedef struct ResourceRow {
    gchar *id;
    gchar *title;
    gchar *reason;
    gchar *caption;
    gchar *release_title;
    gboolean releasing;
} ResourceRow;

typedef struct ResourceView {
    gchar *headline;
    gchar *warning;
    gchar *empty;
    gchar *microphone;
    ResourceRow *rows;
    gint count;
    gboolean can_release_everything;
} ResourceView;

typedef struct ResourceGroup {
    AdwPreferencesGroup *group;
    AdwActionRow *warning;
    GtkListBox *list;
    AdwActionRow *empty;
    GtkLabel *microphone;
    GtkButton *release_everything;
    /* Row id -> AdwActionRow, for rows currently in the list. */
    GHashTable *rows;
} ResourceGroup;

static ResourceGroup resources;
static void (*resources_emit)(int32_t event, const char *text, int32_t index) = jsti_window_emit;

static void on_release(GtkButton *button, gpointer data) {
    (void)data;
    const char *id = g_object_get_data(G_OBJECT(button), "jsti-resource-id");
    if (id != NULL) resources_emit(JSTI_EVENT_SYSTEM_RESOURCE_RELEASE, id, 0);
}

static void on_release_everything(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    resources_emit(JSTI_EVENT_SYSTEM_RESOURCES_RELEASE_ALL, "", 0);
}

static gchar *row_subtitle(const ResourceRow *row) {
    const char *reason = row->reason != NULL ? row->reason : "";
    const char *caption = row->caption != NULL ? row->caption : "";
    return *caption == '\0' ? g_strdup(reason) : g_strdup_printf("%s\n%s", reason, caption);
}

/* Shows a row's text and button. The button is rebuilt only when its title changes. */
static void fill_row(AdwActionRow *widget, const ResourceRow *row) {
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(widget), row->title != NULL ? row->title : "");
    gchar *subtitle = row_subtitle(row);
    adw_action_row_set_subtitle(widget, subtitle);
    g_free(subtitle);
    GtkButton *button = g_object_get_data(G_OBJECT(widget), "jsti-resource-button");
    const char *shown = button != NULL ? gtk_button_get_label(button) : NULL;
    if (g_strcmp0(shown, row->release_title) != 0) {
        if (button != NULL) adw_action_row_remove(widget, GTK_WIDGET(button));
        button = NULL;
        if (row->release_title != NULL) {
            button = GTK_BUTTON(gtk_button_new_with_label(row->release_title));
            gtk_widget_set_valign(GTK_WIDGET(button), GTK_ALIGN_CENTER);
            g_object_set_data_full(G_OBJECT(button), "jsti-resource-id", g_strdup(row->id), g_free);
            g_signal_connect(button, "clicked", G_CALLBACK(on_release), NULL);
            adw_action_row_add_suffix(widget, GTK_WIDGET(button));
        }
        g_object_set_data(G_OBJECT(widget), "jsti-resource-button", button);
    }
    if (button != NULL) {
        /* Unique within the window: several rows may offer the same action. */
        gchar *label = g_strdup_printf("%s: %s", row->release_title, row->title != NULL ? row->title : "");
        gtk_accessible_update_property(GTK_ACCESSIBLE(button), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
        g_free(label);
        gtk_widget_set_sensitive(GTK_WIDGET(button), !row->releasing);
    }
}

static void show_resources(const ResourceView *view) {
    adw_preferences_group_set_description(resources.group, view->headline != NULL ? view->headline : "");
    gtk_widget_set_visible(GTK_WIDGET(resources.warning), view->warning != NULL);
    if (view->warning != NULL) adw_action_row_set_subtitle(resources.warning, view->warning);
    adw_action_row_set_subtitle(resources.empty, view->empty != NULL ? view->empty : "");
    gtk_label_set_text(resources.microphone, view->microphone != NULL ? view->microphone : "");
    gtk_widget_set_sensitive(GTK_WIDGET(resources.release_everything), view->can_release_everything);

    GHashTable *wanted = g_hash_table_new(g_str_hash, g_str_equal);
    for (gint i = 0; i < view->count; i++) {
        if (view->rows[i].id != NULL) g_hash_table_add(wanted, view->rows[i].id);
    }
    GHashTableIter iter;
    gpointer key, value;
    g_hash_table_iter_init(&iter, resources.rows);
    while (g_hash_table_iter_next(&iter, &key, &value)) {
        if (g_hash_table_contains(wanted, key)) continue;
        gtk_list_box_remove(resources.list, GTK_WIDGET(value));
        g_hash_table_iter_remove(&iter);
    }
    g_hash_table_destroy(wanted);
    /* Holds arrive oldest first, so a new one belongs at the end. */
    for (gint i = 0; i < view->count; i++) {
        const ResourceRow *row = &view->rows[i];
        if (row->id == NULL) continue;
        AdwActionRow *widget = g_hash_table_lookup(resources.rows, row->id);
        if (widget == NULL) {
            widget = ADW_ACTION_ROW(adw_action_row_new());
            adw_action_row_set_subtitle_lines(widget, 0);
            gtk_list_box_append(resources.list, GTK_WIDGET(widget));
            g_hash_table_insert(resources.rows, g_strdup(row->id), widget);
        }
        fill_row(widget, row);
    }
}

struct _GtkWidget *jsti_system_resources_group_new(void) {
    resources.group = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(resources.group, "System resources in use");
    adw_preferences_group_set_description(resources.group, "Not holding any system resources");
    resources.rows = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);

    resources.warning = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(
        ADW_PREFERENCES_ROW(resources.warning), "Microphone open, but no feature claims it");
    adw_action_row_set_subtitle_lines(resources.warning, 0);
    adw_action_row_add_prefix(resources.warning, gtk_image_new_from_icon_name("dialog-warning-symbolic"));
    gtk_widget_add_css_class(GTK_WIDGET(resources.warning), "warning");
    gtk_widget_set_visible(GTK_WIDGET(resources.warning), FALSE);
    adw_preferences_group_add(resources.group, GTK_WIDGET(resources.warning));

    resources.list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_list_box_set_selection_mode(resources.list, GTK_SELECTION_NONE);
    gtk_widget_add_css_class(GTK_WIDGET(resources.list), "boxed-list");
    gtk_accessible_update_property(
        GTK_ACCESSIBLE(resources.list), GTK_ACCESSIBLE_PROPERTY_LABEL, "System resources in use", -1);
    resources.empty = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(resources.empty), "Nothing held");
    adw_action_row_set_subtitle_lines(resources.empty, 0);
    gtk_list_box_set_placeholder(resources.list, GTK_WIDGET(resources.empty));
    adw_preferences_group_add(resources.group, GTK_WIDGET(resources.list));

    GtkWidget *footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_set_margin_top(footer, 6);
    resources.microphone = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(resources.microphone, TRUE);
    gtk_label_set_xalign(resources.microphone, 0);
    gtk_widget_set_hexpand(GTK_WIDGET(resources.microphone), TRUE);
    gtk_widget_add_css_class(GTK_WIDGET(resources.microphone), "dim-label");
    gtk_widget_add_css_class(GTK_WIDGET(resources.microphone), "caption");
    resources.release_everything = GTK_BUTTON(gtk_button_new_with_mnemonic("_Release everything"));
    gtk_widget_set_valign(GTK_WIDGET(resources.release_everything), GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(
        GTK_WIDGET(resources.release_everything),
        "Stops recordings, playback and listening. The hotkey keeps working.");
    gtk_widget_set_sensitive(GTK_WIDGET(resources.release_everything), FALSE);
    g_signal_connect(resources.release_everything, "clicked", G_CALLBACK(on_release_everything), NULL);
    gtk_box_append(GTK_BOX(footer), GTK_WIDGET(resources.microphone));
    gtk_box_append(GTK_BOX(footer), GTK_WIDGET(resources.release_everything));
    adw_preferences_group_add(resources.group, footer);
    return GTK_WIDGET(resources.group);
}

static void resource_view_free(gpointer pointer) {
    ResourceView *view = pointer;
    for (gint i = 0; i < view->count; i++) {
        ResourceRow *row = &view->rows[i];
        g_free(row->id);
        g_free(row->title);
        g_free(row->reason);
        g_free(row->caption);
        g_free(row->release_title);
    }
    g_free(view->rows);
    g_free(view->headline);
    g_free(view->warning);
    g_free(view->empty);
    g_free(view->microphone);
    g_free(view);
}

static void resource_view_apply(gpointer pointer) {
    if (resources.group != NULL) show_resources(pointer);
}

int32_t jsti_window_set_system_resources(const JSTISystemResourcesView *view) {
    if (view == NULL || view->row_count < 0 || (view->row_count > 0 && view->rows == NULL)) return -1;
    ResourceView *copy = g_new0(ResourceView, 1);
    copy->headline = g_strdup(view->headline);
    copy->warning = g_strdup(view->warning);
    copy->empty = g_strdup(view->empty);
    copy->microphone = g_strdup(view->microphone);
    copy->can_release_everything = view->can_release_everything != 0;
    copy->count = view->row_count;
    copy->rows = g_new0(ResourceRow, MAX(view->row_count, 1));
    for (gint i = 0; i < view->row_count; i++) {
        const JSTISystemResourceRow *row = &view->rows[i];
        copy->rows[i] = (ResourceRow){
            .id = g_strdup(row->id), .title = g_strdup(row->title), .reason = g_strdup(row->reason),
            .caption = g_strdup(row->caption), .release_title = g_strdup(row->release_title),
            .releasing = row->releasing != 0,
        };
    }
    return jsti_window_post(resource_view_apply, copy, resource_view_free);
}

/* --------------------------------------------------------------- self-test */

typedef struct ResourceEmitted {
    gint calls;
    gint32 event;
    gchar *text;
} ResourceEmitted;

static ResourceEmitted resource_emitted;

static void record_resource_emit(int32_t event, const char *text, int32_t index) {
    (void)index;
    resource_emitted.calls++;
    resource_emitted.event = event;
    g_free(resource_emitted.text);
    resource_emitted.text = g_strdup(text);
}

static GtkButton *row_button(const char *id) {
    AdwActionRow *row = g_hash_table_lookup(resources.rows, id);
    return row != NULL ? g_object_get_data(G_OBJECT(row), "jsti-resource-button") : NULL;
}

static const char *check_resources_group(void) {
    if (jsti_window_set_system_resources(NULL) != -1) return "a missing resources view was accepted";
    ResourceRow rows[] = {
        { .id = (gchar *)"a", .title = (gchar *)"Dictation", .reason = (gchar *)"Recording.",
          .caption = (gchar *)"Microphone · for 2 s", .release_title = (gchar *)"Cancel recording" },
        { .id = (gchar *)"b", .title = (gchar *)"Deepgram live connection", .reason = (gchar *)"Streams.",
          .caption = (gchar *)"Provider connection · for 2 s" },
    };
    show_resources(&(ResourceView){
        .headline = (gchar *)"Microphone in use: Dictation", .rows = rows, .count = 2,
        .can_release_everything = TRUE });
    if (g_hash_table_size(resources.rows) != 2) return "the held resources were not listed";
    GtkButton *cancel = row_button("a");
    if (cancel == NULL || row_button("b") != NULL) return "a release button did not follow its hold";
    if (!gtk_widget_get_sensitive(GTK_WIDGET(resources.release_everything))) {
        return "Release everything was unavailable with a releasable hold";
    }
    g_signal_emit_by_name(cancel, "clicked");
    if (resource_emitted.calls != 1 || resource_emitted.event != JSTI_EVENT_SYSTEM_RESOURCE_RELEASE ||
        g_strcmp0(resource_emitted.text, "a") != 0) {
        return "a row's release did not report its id";
    }
    /* A refresh updates in place: the same button survives and follows "releasing". */
    rows[0].releasing = TRUE;
    rows[0].caption = (gchar *)"Microphone · for 4 s";
    show_resources(&(ResourceView){ .rows = rows, .count = 1 });
    if (row_button("a") != cancel || gtk_widget_get_sensitive(GTK_WIDGET(cancel))) {
        return "a refresh rebuilt a row or left a releasing button enabled";
    }
    if (g_hash_table_size(resources.rows) != 1) return "an ended hold stayed listed";
    if (gtk_widget_get_sensitive(GTK_WIDGET(resources.release_everything))) {
        return "Release everything stayed available with nothing to release";
    }
    show_resources(&(ResourceView){ .warning = (gchar *)"Unclaimed.", .can_release_everything = TRUE });
    if (!gtk_widget_get_visible(GTK_WIDGET(resources.warning))) return "an unclaimed microphone was not shown";
    g_signal_emit_by_name(resources.release_everything, "clicked");
    if (resource_emitted.calls != 2 || resource_emitted.event != JSTI_EVENT_SYSTEM_RESOURCES_RELEASE_ALL) {
        return "Release everything did not report its event";
    }
    return NULL;
}

int32_t jsti_system_resources_self_test(char *error, size_t capacity) {
    if (resources.group == NULL) {
        jsti_set_error(error, capacity, "Window self-test: the system resources group was not built");
        return -1;
    }
    resources_emit = record_resource_emit;
    const char *failure = check_resources_group();
    resources_emit = jsti_window_emit;
    g_clear_pointer(&resource_emitted.text, g_free);
    resource_emitted = (ResourceEmitted){ 0 };
    /* Swift republishes within one poll; until then the group shows nothing held. */
    show_resources(&(ResourceView){ .headline = (gchar *)"Not holding any system resources" });
    if (failure != NULL) {
        jsti_set_error(error, capacity, "Window self-test: %s", failure);
        return -1;
    }
    return 0;
}
