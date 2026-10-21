#include "LinuxActionShortcutsInternal.h"
#include <string.h>

static GPtrArray *current;
static GtkListBox *preferences;
static GHashTable *pressed;

static void row_free(gpointer pointer) {
    ActionRow *row = pointer;
    g_free(row->title);
    g_free(row->chord);
    g_free(row->note);
    g_free(row->page);
    g_free(row->identifier);
    g_free(row);
}

static void refresh_preferences(void) {
    if (preferences == NULL) return;
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(preferences))) != NULL)
        gtk_list_box_remove(preferences, child);
    for (guint i = 0; current != NULL && i < current->len; ++i) {
        const ActionRow *item = g_ptr_array_index(current, i);
        AdwActionRow *row = ADW_ACTION_ROW(adw_action_row_new());
        adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(row), FALSE);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), item->title);
        gchar *subtitle = g_strdup_printf("%s - %s", item->chord, item->note);
        adw_action_row_set_subtitle(row, subtitle);
        g_free(subtitle);
        gtk_list_box_append(preferences, GTK_WIDGET(row));
    }
}

static void edit_clicked(GtkButton *button, gpointer owner) {
    (void)button;
    jsti_action_shortcut_editor_open(GTK_WINDOW(owner));
}

GtkWidget *jsti_action_shortcuts_group_new(GtkWindow *owner) {
    GtkWidget *group = adw_preferences_group_new();
    adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(group), "Action shortcuts");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(group),
        "Saved bindings run while this window is active, outside typing controls. Sidebar shortcuts run first. "
        "Edit keys, switches and presets below. Supported global actions register on X11; "
        "Wayland uses desktop keyboard settings.");
    preferences = GTK_LIST_BOX(gtk_list_box_new());
    g_object_add_weak_pointer(G_OBJECT(preferences), (gpointer *)&preferences);
    gtk_list_box_set_selection_mode(preferences, GTK_SELECTION_NONE);
    gtk_widget_add_css_class(GTK_WIDGET(preferences), "boxed-list");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(preferences));
    GtkWidget *edit = gtk_button_new_with_label("Edit action shortcuts...");
    gtk_widget_set_halign(edit, GTK_ALIGN_START);
    gtk_widget_set_margin_top(edit, 8);
    g_signal_connect(edit, "clicked", G_CALLBACK(edit_clicked), owner);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), edit);
    refresh_preferences();
    return group;
}

static void apply_rows(gpointer pointer) {
    GPtrArray *rows = g_ptr_array_ref(pointer);
    g_clear_pointer(&current, g_ptr_array_unref);
    current = rows;
    jsti_action_shortcut_editor_rows(rows);
    refresh_preferences();
}

GPtrArray *jsti_action_shortcuts_copy_rows(const JSTILinuxActionShortcut *rows, size_t count) {
    if (count > 64 || (count != 0 && rows == NULL)) return NULL;
    GPtrArray *copy = g_ptr_array_new_with_free_func(row_free);
    for (size_t i = 0; i < count; ++i) {
        const JSTILinuxActionShortcut *row = rows + i;
        if (row->title == NULL || row->chord == NULL || row->note == NULL || row->page == NULL ||
            row->identifier == NULL || !g_utf8_validate(row->identifier, -1, NULL) ||
            !g_utf8_validate(row->title, -1, NULL) || !g_utf8_validate(row->chord, -1, NULL) ||
            !g_utf8_validate(row->note, -1, NULL) || !g_utf8_validate(row->page, -1, NULL) ||
            row->run < 0 || row->run > 12 || (row->modifiers & ~13u) != 0 ||
            row->identifier[0] == '\0' || strlen(row->identifier) > 128 ||
            (row->binding_enabled != 0 && row->binding_enabled != 1) ||
            (row->binding_global != 0 && row->binding_global != 1) ||
            (row->can_be_global != 0 && row->can_be_global != 1) ||
            (row->has_key != 0 && row->has_key != 1) ||
            (row->enabled != 0 && row->enabled != 1) ||
            (row->enabled && (row->keysym == 0 || row->run == 0)) ||
            (row->run == 2 && row->page[0] == '\0') ||
            (row->run == 6 && (row->slot < 1 || row->slot > 3))) {
            g_ptr_array_unref(copy);
            return NULL;
        }
        ActionRow *item = g_new0(ActionRow, 1);
        item->title = g_strdup(row->title);
        item->chord = g_strdup(row->chord);
        item->note = g_strdup(row->note);
        item->page = g_strdup(row->page);
        item->identifier = g_strdup(row->identifier);
        item->keysym = row->keysym;
        item->modifiers = row->modifiers;
        item->run = row->run;
        item->slot = row->slot;
        item->enabled = row->enabled != 0;
        item->binding_enabled = row->binding_enabled != 0;
        item->binding_global = row->binding_global != 0;
        item->can_be_global = row->can_be_global != 0;
        item->has_key = row->has_key != 0;
        g_ptr_array_add(copy, item);
    }
    return copy;
}

GPtrArray *jsti_action_shortcuts_clone_rows(GPtrArray *rows) {
    GPtrArray *copy = g_ptr_array_new_with_free_func(row_free);
    for (guint i = 0; rows != NULL && i < rows->len; ++i) {
        ActionRow *original = g_ptr_array_index(rows, i);
        ActionRow *row = g_memdup2(original, sizeof *row);
        row->title = g_strdup(original->title);
        row->chord = g_strdup(original->chord);
        row->note = g_strdup(original->note);
        row->page = g_strdup(original->page);
        row->identifier = g_strdup(original->identifier);
        g_ptr_array_add(copy, row);
    }
    return copy;
}

int32_t jsti_window_set_action_shortcuts(const JSTILinuxActionShortcut *rows, size_t count) {
    GPtrArray *copy = jsti_action_shortcuts_copy_rows(rows, count);
    return copy == NULL ? -1 : jsti_window_post(apply_rows, copy, (GDestroyNotify)g_ptr_array_unref);
}

void jsti_action_shortcuts_release(guint keycode) {
    if (pressed != NULL) g_hash_table_remove(pressed, GUINT_TO_POINTER(keycode));
}

void jsti_action_shortcuts_reset(void) {
    if (pressed != NULL) g_hash_table_remove_all(pressed);
}

static gboolean belongs_to_focus(GtkWidget *focused, guint keyval, guint modifiers) {
    gboolean plain = (modifiers & (GDK_CONTROL_MASK | GDK_ALT_MASK)) == 0;
    for (GtkWidget *focus = focused; focus != NULL; focus = gtk_widget_get_parent(focus)) {
        if (GTK_IS_EDITABLE(focus) || GTK_IS_TEXT_VIEW(focus) || GTK_IS_DROP_DOWN(focus)) return TRUE;
        if (plain && (GTK_IS_RANGE(focus) || GTK_IS_LIST_VIEW(focus) || GTK_IS_GRID_VIEW(focus) ||
                      GTK_IS_COLUMN_VIEW(focus) || GTK_IS_LIST_BOX(focus))) return TRUE;
        if (plain && (keyval == GDK_KEY_space || keyval == GDK_KEY_Return) &&
            (GTK_IS_BUTTON(focus) || GTK_IS_CHECK_BUTTON(focus))) return TRUE;
    }
    return FALSE;
}

gboolean jsti_action_shortcuts_key(struct _GtkEventControllerKey *controller,
    guint keyval, guint keycode, guint modifiers, GtkWidget *focused, jsti_action_run_fn run) {
    guint relevant = modifiers & (GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_ALT_MASK |
                                  GDK_SUPER_MASK | GDK_HYPER_MASK | GDK_META_MASK);
    if (belongs_to_focus(focused, keyval, relevant)) return FALSE;
    if (controller != NULL) {
        GdkEvent *event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
        if (event != NULL && gdk_event_get_event_type(event) == GDK_KEY_PRESS) {
            /* AltGr must keep producing text, not become a Ctrl+Alt action. */
            if (gdk_key_event_get_consumed_modifiers(event) & (GDK_CONTROL_MASK | GDK_ALT_MASK)) return FALSE;
            guint base;
            if (gdk_display_translate_key(gdk_event_get_display(event), keycode, 0,
                gdk_key_event_get_layout(event), &base, NULL, NULL, NULL)) keyval = base;
        }
    }
    keyval = gdk_keyval_to_lower(keyval);
    if (keycode != 0 && pressed != NULL && g_hash_table_contains(pressed, GUINT_TO_POINTER(keycode))) return TRUE;
    for (guint i = 0; current != NULL && i < current->len; ++i) {
        const ActionRow *row = g_ptr_array_index(current, i);
        if (!row->enabled || row->keysym != keyval || row->modifiers != relevant) continue;
        /* Dispatch may open a modal nested loop and replace the configuration. */
        gint code = row->run, slot = row->slot;
        gchar *page = g_strdup(row->page);
        if (keycode != 0) {
            if (pressed == NULL) pressed = g_hash_table_new(g_direct_hash, g_direct_equal);
            g_hash_table_add(pressed, GUINT_TO_POINTER(keycode));
        }
        run(code, page, slot);
        g_free(page);
        /* A busy action must not start later just because the key is held. */
        return TRUE;
    }
    return FALSE;
}

static guint captured;
static gint captured_run;
static gboolean accept_run;
static gboolean capture_run(gint run, const char *page, gint slot) {
    (void)page; (void)slot;
    captured_run = run;
    ++captured;
    return accept_run;
}

int32_t jsti_action_shortcuts_self_test(char *error, size_t capacity) {
    if (current == NULL || current->len == 0 || preferences == NULL) {
        jsti_set_error(error, capacity, "saved action shortcuts were not projected into Keyboard");
        return -1;
    }
    guint shown = 0;
    for (GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(preferences));
         child != NULL; child = gtk_widget_get_next_sibling(child)) {
        if (shown >= current->len || !ADW_IS_ACTION_ROW(child)) {
            jsti_set_error(error, capacity, "unexpected action shortcut row");
            return -1;
        }
        const ActionRow *row = g_ptr_array_index(current, shown++);
        if (g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(child)), row->title) != 0 ||
            strstr(adw_action_row_get_subtitle(ADW_ACTION_ROW(child)), row->note) == NULL) {
            jsti_set_error(error, capacity, "action shortcut title or availability note was lost");
            return -1;
        }
    }
    if (shown != current->len) {
        jsti_set_error(error, capacity, "action shortcut rows were omitted");
        return -1;
    }
    GPtrArray *saved = g_ptr_array_ref(current);
    GPtrArray *fixture = g_ptr_array_new_with_free_func(row_free);
    ActionRow *row = g_new0(ActionRow, 1);
    row->title = g_strdup("Fixture");
    row->chord = g_strdup("Ctrl+D");
    row->note = g_strdup("This window");
    row->page = g_strdup("");
    row->identifier = g_strdup("openDashboard");
    row->keysym = GDK_KEY_d;
    row->modifiers = GDK_CONTROL_MASK;
    row->run = 1;
    row->enabled = TRUE;
    g_ptr_array_add(fixture, row);
    apply_rows(fixture);
    captured = 0;
    accept_run = TRUE;
    jsti_action_shortcuts_reset();
    gboolean okay = jsti_action_shortcuts_key(NULL, GDK_KEY_D, 42, GDK_CONTROL_MASK | GDK_LOCK_MASK, NULL, capture_run);
    okay = okay && captured == 1 && captured_run == 1 &&
        jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK, NULL, capture_run) && captured == 1;
    jsti_action_shortcuts_release(42);
    okay = okay && jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK, NULL, capture_run) && captured == 2;
    jsti_action_shortcuts_release(42);
    const guint extra[] = { GDK_SHIFT_MASK, GDK_ALT_MASK, GDK_SUPER_MASK, GDK_META_MASK, GDK_HYPER_MASK };
    for (guint i = 0; i < G_N_ELEMENTS(extra); ++i)
        okay = okay && !jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK | extra[i], NULL, capture_run);
    GtkWidget *entry = gtk_entry_new(), *text = gtk_text_view_new();
    g_object_ref_sink(entry);
    g_object_ref_sink(text);
    okay = okay && !jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK, entry, capture_run) &&
        !jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK, text, capture_run);
    g_object_unref(entry);
    g_object_unref(text);
    accept_run = FALSE;
    okay = okay && jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK, NULL, capture_run) &&
        captured == 3 && jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK, NULL, capture_run) &&
        captured == 3;
    jsti_action_shortcuts_reset();
    accept_run = TRUE;
    okay = okay && jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK, NULL, capture_run) && captured == 4;
    jsti_action_shortcuts_release(42);
    row->enabled = FALSE;
    okay = okay && !jsti_action_shortcuts_key(NULL, GDK_KEY_d, 42, GDK_CONTROL_MASK, NULL, capture_run);
    JSTILinuxActionShortcut invalid = { .title = "bad" };
    okay = okay && jsti_window_set_action_shortcuts(NULL, 1) == -1 &&
        jsti_window_set_action_shortcuts(&invalid, 1) == -1 && captured == 4;
    JSTILinuxActionShortcut paste = {
        .title = "Paste Last History Item", .chord = "Ctrl+Alt+V", .note = "This window",
        .page = "", .identifier = "pasteLastHistoryItem", .keysym = GDK_KEY_v,
        .modifiers = GDK_CONTROL_MASK | GDK_ALT_MASK, .run = 11, .enabled = 1,
        .binding_enabled = 1, .can_be_global = 1, .has_key = 1
    };
    GPtrArray *paste_rows = jsti_action_shortcuts_copy_rows(&paste, 1);
    okay = okay && paste_rows != NULL &&
        ((ActionRow *)g_ptr_array_index(paste_rows, 0))->run == 11;
    if (paste_rows != NULL) {
        apply_rows(paste_rows);
        jsti_action_shortcuts_reset();
        okay = okay && jsti_action_shortcuts_key(NULL, GDK_KEY_v, 43,
            GDK_CONTROL_MASK | GDK_ALT_MASK, NULL, capture_run) && captured == 5 && captured_run == 11;
        jsti_action_shortcuts_release(43);
    }
    g_clear_pointer(&paste_rows, g_ptr_array_unref);
    JSTILinuxActionShortcut selected = paste;
    selected.title = "Speak Selected Text"; selected.identifier = "speakSelectedText";
    selected.run = 12; selected.enabled = 0;
    GPtrArray *selected_rows = jsti_action_shortcuts_copy_rows(&selected, 1);
    okay = okay && selected_rows != NULL &&
        ((ActionRow *)g_ptr_array_index(selected_rows, 0))->run == 12;
    if (selected_rows != NULL) {
        apply_rows(selected_rows);
        jsti_action_shortcuts_reset();
        okay = okay && !jsti_action_shortcuts_key(NULL, GDK_KEY_v, 43,
            GDK_CONTROL_MASK | GDK_ALT_MASK, NULL, capture_run) && captured == 5;
    }
    g_clear_pointer(&selected_rows, g_ptr_array_unref);
    paste.run = 13;
    paste_rows = jsti_action_shortcuts_copy_rows(&paste, 1);
    okay = okay && paste_rows == NULL;
    g_clear_pointer(&paste_rows, g_ptr_array_unref);
    apply_rows(saved);
    g_ptr_array_unref(saved);
    g_ptr_array_unref(fixture);
    jsti_action_shortcuts_reset();
    if (!okay) jsti_set_error(error, capacity, "action shortcut projection, focus, modifiers or repeat suppression failed");
    return okay ? 0 : -1;
}
