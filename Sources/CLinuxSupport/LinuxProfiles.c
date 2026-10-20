#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

typedef struct {
    GtkWidget *root, *controls, *fields[10];
    GtkListBox *list;
    GtkDropDown *active;
    GtkLabel *status, *notes;
    GPtrArray *rows, *choices[10], *active_ids;
    gchar *token, *last_payload;
    gint selected;
    gboolean filling, busy, select_new, fixture;
} Profiles;
static Profiles *editor;

static gchar *escape(const char *value) { return g_uri_escape_string(value, NULL, TRUE); }
static void append(GString *payload, const char *value) {
    gchar *encoded = escape(value);
    g_string_append_c(payload, '\t'); g_string_append(payload, encoded); g_free(encoded);
}
static void pending(Profiles *e, gboolean busy) {
    e->busy = busy; gtk_widget_set_sensitive(e->controls, !busy);
}
static void deliver(Profiles *e, const char *payload) {
    pending(e, TRUE);
    gtk_label_set_text(e->status, "Applying profile change...");
    if (e->fixture) {
        g_free(e->last_payload); e->last_payload = g_strdup(payload);
    } else jsti_window_emit(JSTI_EVENT_PROFILES, payload, 0);
}
static const char *selected_id(Profiles *e) {
    return e->selected >= 0 && (guint)e->selected < e->rows->len
        ? ((gchar **)g_ptr_array_index(e->rows, (guint)e->selected))[1] : "";
}
static gchar *action_payload(Profiles *e, const char *action, const char *id) {
    GString *result = g_string_new(e->token != NULL ? e->token : "");
    append(result, action); append(result, id);
    return g_string_free(result, FALSE);
}
static const char *choice(Profiles *e, guint field) {
    guint index = gtk_drop_down_get_selected(GTK_DROP_DOWN(e->fields[field]));
    return index < e->choices[field]->len ? g_ptr_array_index(e->choices[field], index) : "!";
}
static gchar *text(GtkWidget *widget) {
    if (GTK_IS_EDITABLE(widget)) return g_strdup(gtk_editable_get_text(GTK_EDITABLE(widget)));
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget));
    GtkTextIter first, last; gtk_text_buffer_get_bounds(buffer, &first, &last);
    return gtk_text_buffer_get_text(buffer, &first, &last, FALSE);
}
static void set_text(GtkWidget *widget, const char *value) {
    if (GTK_IS_EDITABLE(widget)) gtk_editable_set_text(GTK_EDITABLE(widget), value);
    else gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget)), value, -1);
}
static gboolean is_choice(guint field) { return field == 2 || field == 3 || field == 4 || field >= 7; }
static void choose(Profiles *e, guint field, const char *value) {
    guint selected = GTK_INVALID_LIST_POSITION;
    for (guint i = 0; i < e->choices[field]->len; ++i)
        if (g_strcmp0(g_ptr_array_index(e->choices[field], i), value) == 0) { selected = i; break; }
    gtk_drop_down_set_selected(GTK_DROP_DOWN(e->fields[field]), selected);
}
static void fill(Profiles *e, gchar **row) {
    for (guint i = 0; i < 10; ++i) {
        const char *value = row != NULL ? row[i + 2] : "";
        if (is_choice(i)) choose(e, i, value);
        else set_text(e->fields[i], value);
    }
    gtk_label_set_text(e->notes, row != NULL ? row[12] : "New profile: unspecified overrides use app settings.");
}
static void selected(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    (void)list; Profiles *e = data;
    if (e->filling) return;
    e->selected = row != NULL ? gtk_list_box_row_get_index(row) : -1;
    fill(e, e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL);
}
static void active_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; Profiles *e = data;
    if (e->filling || e->busy) return;
    guint index = gtk_drop_down_get_selected(e->active);
    if (index >= e->active_ids->len) return;
    gchar *payload = action_payload(e, "activate", g_ptr_array_index(e->active_ids, index));
    deliver(e, payload); g_free(payload);
}
static void delete_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    Profiles *e = g_object_get_data(G_OBJECT(data), "profiles-editor");
    if (e != NULL && !e->busy && g_strcmp0(response, "delete") == 0) {
        const char *payload = g_object_get_data(G_OBJECT(dialog), "profiles-delete");
        deliver(e, payload);
    }
}
static GtkWidget *delete_dialog(Profiles *e, gchar *payload) {
    GtkRoot *root = gtk_widget_get_root(e->root);
    GtkWidget *dialog = adw_message_dialog_new(GTK_IS_WINDOW(root) ? GTK_WINDOW(root) : NULL,
        "Delete profile?", "Remove this saved profile? If it is selected, app settings apply until you choose "
        "another profile or Automatic.");
    g_object_set_data_full(G_OBJECT(dialog), "profiles-delete", payload, g_free);
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "delete", "Delete", NULL);
    adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "delete", ADW_RESPONSE_DESTRUCTIVE);
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    g_signal_connect_object(dialog, "response", G_CALLBACK(delete_response), e->root, 0);
    return dialog;
}
static void clicked(GtkButton *button, gpointer data) {
    Profiles *e = data;
    if (e->busy || e->token == NULL) return;
    const char *action = g_object_get_data(G_OBJECT(button), "profiles-action");
    if (g_strcmp0(action, "new") == 0) {
        e->selected = -1; gtk_list_box_unselect_all(e->list); fill(e, NULL); return;
    }
    const char *id = selected_id(e);
    if (g_strcmp0(action, "save") != 0 && id[0] == '\0') return;
    gchar *payload = action_payload(e, action, id);
    if (g_strcmp0(action, "delete") == 0) {
        GtkWidget *dialog = delete_dialog(e, payload);
        gtk_window_present(GTK_WINDOW(dialog)); return;
    }
    if (g_strcmp0(action, "save") == 0) {
        GString *form = g_string_new(payload); g_free(payload);
        e->select_new = id[0] == '\0';
        for (guint i = 0; i < 10; ++i) {
            if (is_choice(i)) append(form, choice(e, i));
            else { gchar *value = text(e->fields[i]); append(form, value); g_free(value); }
        }
        payload = g_string_free(form, FALSE);
    }
    deliver(e, payload); g_free(payload);
}
static GtkWidget *button(Profiles *e, const char *title, const char *action) {
    GtkWidget *widget = gtk_button_new_with_mnemonic(title);
    g_object_set_data(G_OBJECT(widget), "profiles-action", (gpointer)action);
    g_signal_connect(widget, "clicked", G_CALLBACK(clicked), e);
    return widget;
}
static GtkWidget *label(const char *value) {
    GtkWidget *widget = gtk_label_new(value);
    gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    gtk_label_set_xalign(GTK_LABEL(widget), 0);
    return widget;
}
static GtkWidget *field(Profiles *e, guint index, const char *title) {
    GtkWidget *widget;
    if (is_choice(index)) {
        widget = gtk_drop_down_new(NULL, NULL);
        e->choices[index] = g_ptr_array_new_with_free_func(g_free);
    } else if (index == 1 || index == 5) {
        widget = gtk_text_view_new();
        gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(widget), GTK_WRAP_WORD_CHAR);
        gtk_widget_set_size_request(widget, -1, 88);
    } else widget = gtk_entry_new();
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, title, -1);
    e->fields[index] = widget;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_box_append(GTK_BOX(box), label(title));
    if (GTK_IS_TEXT_VIEW(widget)) {
        GtkWidget *scroll = gtk_scrolled_window_new();
        gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
        gtk_widget_set_size_request(scroll, -1, 100);
        gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), widget);
        gtk_box_append(GTK_BOX(box), scroll);
    } else gtk_box_append(GTK_BOX(box), widget);
    return box;
}
static void destroy(gpointer data) {
    Profiles *e = data;
    if (editor == e) editor = NULL;
    g_ptr_array_unref(e->rows); g_ptr_array_unref(e->active_ids);
    for (guint i = 0; i < 10; ++i) if (e->choices[i] != NULL) g_ptr_array_unref(e->choices[i]);
    g_free(e->token); g_free(e->last_payload); g_free(e);
}
GtkWidget *jsti_profiles_page_new(void) {
    Profiles *e = g_new0(Profiles, 1); e->selected = -1;
    e->rows = g_ptr_array_new_with_free_func((GDestroyNotify)g_strfreev);
    e->active_ids = g_ptr_array_new_with_free_func(g_free);
    GtkWidget *column;
    e->root = jsti_page_new(&column);
    e->controls = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_box_append(GTK_BOX(column), label("Profiles"));
    gtk_box_append(GTK_BOX(column), label(
        "Overrides apply to one recording without changing your normal settings. Order decides the first X11 match."));
    gtk_box_append(GTK_BOX(column), e->controls);
    gtk_box_append(GTK_BOX(e->controls), label("Next recording: manual selection or automatic / app settings"));
    e->active = GTK_DROP_DOWN(gtk_drop_down_new(NULL, NULL));
    gtk_accessible_update_property(GTK_ACCESSIBLE(e->active),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Profile for next recording", -1);
    gtk_box_append(GTK_BOX(e->controls), GTK_WIDGET(e->active));
    e->list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(e->list), "boxed-list");
    gtk_accessible_update_property(GTK_ACCESSIBLE(e->list), GTK_ACCESSIBLE_PROPERTY_LABEL, "Saved profiles in match order", -1);
    gtk_box_append(GTK_BOX(e->controls), GTK_WIDGET(e->list));
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    const char *titles[] = {"_New", "_Duplicate", "_Delete", "Move _up", "Move do_wn"};
    const char *verbs[] = {"new", "duplicate", "delete", "up", "down"};
    for (guint i = 0; i < G_N_ELEMENTS(verbs); ++i)
        gtk_box_append(GTK_BOX(actions), button(e, titles[i], verbs[i]));
    gtk_box_append(GTK_BOX(e->controls), actions);
    const char *fields[] = {"Name", "X11 executable paths (one complete path per line)", "Transcription",
        "Post-processing", "Post-processing model", "Custom post-processing prompt", "Output language",
        "Spoken language", "Include personal lexicon directives", "Include context tags"};
    for (guint i = 0; i < G_N_ELEMENTS(fields); ++i)
        gtk_box_append(GTK_BOX(e->controls), field(e, i, fields[i]));
    e->notes = GTK_LABEL(label(""));
    gtk_label_set_selectable(e->notes, TRUE);
    gtk_box_append(GTK_BOX(e->controls), GTK_WIDGET(e->notes));
    gtk_box_append(GTK_BOX(e->controls), button(e, "_Save profile", "save"));
    e->status = GTK_LABEL(label("Open Profiles to load saved values."));
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(e->status));
    g_signal_connect(e->list, "row-selected", G_CALLBACK(selected), e);
    g_signal_connect(e->active, "notify::selected", G_CALLBACK(active_changed), e);
    g_object_set_data_full(G_OBJECT(e->root), "profiles-editor", e, destroy);
    editor = e; pending(e, TRUE);
    return e->root;
}

static void add_choice(Profiles *e, guint field, GtkStringList *names, const char *id, const char *title) {
    gtk_string_list_append(names, title);
    g_ptr_array_add(e->choices[field], g_strdup(id));
}
static void choices(Profiles *e, GPtrArray *lines) {
    for (guint field = 0; field < 10; ++field) {
        if (!is_choice(field)) continue;
        g_ptr_array_set_size(e->choices[field], 0);
        GtkStringList *names = gtk_string_list_new(NULL);
        add_choice(e, field, names, "", "Use app setting");
        if (field == 3 || field >= 8) {
            add_choice(e, field, names, "0", "Off"); add_choice(e, field, names, "1", "On");
        } else {
            add_choice(e, field, names, "!", "Keep stored unavailable value");
            const char *kind = field == 2 ? "T" : (field == 4 ? "P" : "L");
            for (guint i = 1; i < lines->len; ++i) {
                gchar **row = g_ptr_array_index(lines, i);
                if (g_strcmp0(row[0], kind) == 0) add_choice(e, field, names, row[1], row[2]);
            }
        }
        gtk_drop_down_set_model(GTK_DROP_DOWN(e->fields[field]), G_LIST_MODEL(names)); g_object_unref(names);
    }
}
static GPtrArray *parse(const char *wire) {
    gchar **lines = g_strsplit(wire, "\n", -1);
    GPtrArray *result = g_ptr_array_new_with_free_func((GDestroyNotify)g_strfreev);
    for (guint i = 0; lines[i] != NULL; ++i) {
        gchar **row = g_strsplit(lines[i], "\t", -1);
        for (guint j = 0; row[j] != NULL; ++j) {
            gchar *decoded = g_uri_unescape_string(row[j], NULL);
            if (decoded == NULL) { g_strfreev(row); g_ptr_array_unref(result); g_strfreev(lines); return NULL; }
            g_free(row[j]); row[j] = decoded;
        }
        guint count = g_strv_length(row);
        gboolean valid = i == 0 ? count == 6 && g_strcmp0(row[0], "H") == 0 && g_uuid_string_is_valid(row[1])
            : (g_strcmp0(row[0], "R") == 0 ? count == 13 && g_uuid_string_is_valid(row[1])
                : count == 3 && (g_strcmp0(row[0], "T") == 0 || g_strcmp0(row[0], "P") == 0
                    || g_strcmp0(row[0], "L") == 0));
        if (!valid) { g_strfreev(row); g_ptr_array_unref(result); g_strfreev(lines); return NULL; }
        g_ptr_array_add(result, row);
    }
    g_strfreev(lines); return result;
}
static gboolean replace(Profiles *e, const char *wire) {
    GPtrArray *lines = parse(wire);
    if (lines == NULL) return FALSE;
    gchar **header = g_ptr_array_index(lines, 0);
    gchar *previous = g_strdup(selected_id(e));
    e->filling = TRUE;
    choices(e, lines);
    g_free(e->token); e->token = g_strdup(header[1]);
    g_ptr_array_set_size(e->rows, 0); g_ptr_array_set_size(e->active_ids, 0);
    while (gtk_widget_get_first_child(GTK_WIDGET(e->list)) != NULL)
        gtk_list_box_remove(e->list, gtk_widget_get_first_child(GTK_WIDGET(e->list)));
    GtkStringList *names = gtk_string_list_new(NULL);
    gtk_string_list_append(names, "Automatic / app settings");
    g_ptr_array_add(e->active_ids, g_strdup(""));
    guint active = 0;
    e->selected = -1;
    for (guint i = 1; i < lines->len; ++i) {
        gchar **row = g_ptr_array_index(lines, i);
        if (g_strcmp0(row[0], "R") != 0) continue;
        g_ptr_array_add(e->rows, g_strdupv(row));
        gtk_list_box_append(e->list, label(row[2]));
        gtk_string_list_append(names, row[2]); g_ptr_array_add(e->active_ids, g_strdup(row[1]));
        if (g_strcmp0(previous, row[1]) == 0) e->selected = (gint)e->rows->len - 1;
        if (g_strcmp0(header[2], row[1]) == 0) active = e->rows->len;
    }
    if (active == 0 && header[2][0] != '\0') {
        gtk_string_list_append(names, "Selected profile unavailable: app settings only");
        g_ptr_array_add(e->active_ids, g_strdup(header[2]));
        active = e->active_ids->len - 1;
    }
    gtk_drop_down_set_model(e->active, G_LIST_MODEL(names)); g_object_unref(names);
    gtk_drop_down_set_selected(e->active, active);
    if (e->select_new) e->selected = (gint)e->rows->len - 1;
    e->select_new = FALSE;
    if (e->selected < 0 && e->rows->len > 0) e->selected = 0;
    if (e->selected >= 0) gtk_list_box_select_row(e->list, gtk_list_box_get_row_at_index(e->list, e->selected));
    fill(e, e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL);
    gchar *notice = g_strjoin("\n\n", header[3], header[4], header[5], NULL);
    gtk_label_set_text(e->status, notice);
    g_free(notice); g_free(previous); g_ptr_array_unref(lines);
    e->filling = FALSE; pending(e, FALSE);
    return TRUE;
}
typedef struct { gchar *wire; gboolean replace; } Update;
static void update_free(gpointer data) { Update *update = data; g_free(update->wire); g_free(update); }
static void update_apply(gpointer data) {
    Update *update = data;
    if (editor == NULL) return;
    if (update->replace && replace(editor, update->wire)) return;
    gtk_label_set_text(editor->status, update->replace ? "Profiles response could not be read. Reopen Profiles."
        : update->wire);
    pending(editor, FALSE);
}
int32_t jsti_profiles_set(const char *wire, int32_t replacing) {
    if (wire == NULL || strlen(wire) > 8388608 || (replacing != 0 && replacing != 1)) return -1;
    Update *update = g_new0(Update, 1); update->wire = g_strdup(wire); update->replace = replacing != 0;
    return jsti_window_post(update_apply, update, update_free);
}

int32_t jsti_profiles_self_test(char *error, size_t capacity) {
    Profiles *saved = editor;
    GtkWidget *root = jsti_profiles_page_new(); g_object_ref_sink(root);
    Profiles *e = editor; e->fixture = TRUE;
    const char *id = "11111111-1111-1111-1111-111111111111";
    const char *token = "22222222-2222-2222-2222-222222222222";
    gchar *wire = g_strdup_printf(
        "H\t%s\t%s\tSaved\tX11 exact paths; Wayland manual\tRules ignore custom prompts\n"
        "T\tbatch:fixture/model\tBatch model\nP\tfixture/polish\tPolish model\nL\ten\tEnglish\n"
        "R\t%s\tFirst\t/usr/bin/Editor\tbatch:fixture/model\t1\tfixture/polish\tKeep%%09tabs\tEnglish\ten\t0\t1\tKept",
        token, id, id);
    gboolean okay = replace(e, wire) && e->rows->len == 1 && e->selected == 0
        && gtk_drop_down_get_selected(e->active) == 1 && g_strcmp0(choice(e, 2), "batch:fixture/model") == 0
        && g_strcmp0(choice(e, 8), "0") == 0 && g_strcmp0(choice(e, 9), "1") == 0;
    const char *second_id = "33333333-3333-3333-3333-333333333333";
    gchar *two = g_strdup_printf(
        "H\t%s\t%s\tSaved\tX11 exact; Wayland manual\tRules are local\n"
        "T\tbatch:fixture/model\tBatch model\nP\tfixture/polish\tPolish model\nL\ten\tEnglish\n"
        "R\t%s\tSecond\t/usr/bin/Other\t\t\t\t\t\t\t\t\tOther\n"
        "R\t%s\tFirst\t/usr/bin/Editor\tbatch:fixture/model\t1\tfixture/polish\tKeep%%09tabs\tEnglish\ten\t0\t1\tKept",
        token, id, second_id, id);
    okay = okay && replace(e, two) && e->rows->len == 2 && e->selected == 1
        && g_strcmp0(((gchar **)g_ptr_array_index(e->rows, 0))[1], second_id) == 0
        && gtk_drop_down_get_selected(e->active) == 2;
    g_free(two);
    const char *verbs[] = {"save", "duplicate", "up", "down"};
    for (guint i = 0; i < G_N_ELEMENTS(verbs); ++i) {
        GtkWidget *action = button(e, verbs[i], verbs[i]); g_object_ref_sink(action);
        g_signal_emit_by_name(action, "clicked");
        okay = okay && e->last_payload != NULL && strstr(e->last_payload, verbs[i]) != NULL
            && strstr(e->last_payload, id) != NULL && e->busy;
        pending(e, FALSE); g_object_unref(action);
    }
    GtkWidget *dialog = delete_dialog(e, action_payload(e, "delete", id)); g_object_ref_sink(dialog);
    okay = okay && g_strcmp0(adw_message_dialog_get_default_response(ADW_MESSAGE_DIALOG(dialog)), "cancel") == 0
        && g_strcmp0(adw_message_dialog_get_close_response(ADW_MESSAGE_DIALOG(dialog)), "cancel") == 0;
    gchar *before_cancel = g_strdup(e->last_payload);
    delete_response(ADW_MESSAGE_DIALOG(dialog), "cancel", e->root);
    okay = okay && g_strcmp0(e->last_payload, before_cancel) == 0;
    g_free(before_cancel);
    e->selected = -1; fill(e, NULL);
    delete_response(ADW_MESSAGE_DIALOG(dialog), "delete", e->root);
    okay = okay && strstr(e->last_payload, id) != NULL && strstr(e->last_payload, "delete") != NULL;
    gtk_window_destroy(GTK_WINDOW(dialog)); g_object_unref(dialog);
    pending(e, FALSE);
    GtkWidget *new_profile = button(e, "New", "new"); g_object_ref_sink(new_profile);
    g_signal_emit_by_name(new_profile, "clicked");
    okay = okay && e->selected == -1;
    g_object_unref(new_profile);
    GtkWidget *save = button(e, "Save", "save"); g_object_ref_sink(save);
    set_text(e->fields[0], "New profile");
    g_signal_emit_by_name(save, "clicked");
    okay = okay && strstr(e->last_payload, "\tsave\t\tNew%20profile") != NULL;
    pending(e, FALSE); g_object_unref(save);
    gtk_drop_down_set_selected(e->active, 1);
    okay = okay && strstr(e->last_payload, "activate") != NULL && strstr(e->last_payload, second_id) != NULL;
    okay = okay && !replace(e, "H\tbroken") && e->rows->len == 2;
    Update *late = g_new0(Update, 1); late->wire = g_strdup("late error");
    g_free(wire); g_object_unref(root);
    okay = okay && editor == NULL;
    update_apply(late); update_free(late); editor = saved;
    if (!okay) { jsti_set_error(error, capacity, "GTK Profiles selection, wire or frozen identity failed"); return -1; }
    return 0;
}
