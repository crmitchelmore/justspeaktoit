#include "LinuxActionShortcutsInternal.h"

typedef struct {
    gchar *revision;
    gchar **names;
    GPtrArray *presets;
    guint reset;
} EditorConfiguration;

typedef struct {
    GtkWindow *window;
    GtkDropDown *action, *preset;
    AdwSwitchRow *enabled, *global;
    GtkLabel *key, *notice;
    GtkButton *record, *save;
    GtkWidget *controls;
    GPtrArray *rows;
    GArray *changed;
    gchar *revision, *request;
    gboolean loading, capturing, pending, stale;
} Editor;

static EditorConfiguration configuration;
static GPtrArray *saved_rows;
static Editor *active;
static gboolean idle = TRUE;
static gint editor_open;
static void (*emit_edit)(gint32, const char *, gint32) = jsti_window_emit;

int32_t jsti_action_shortcuts_editor_is_open(void) { return g_atomic_int_get(&editor_open); }

static void configuration_free(gpointer pointer) {
    EditorConfiguration *config = pointer;
    g_free(config->revision);
    g_strfreev(config->names);
    g_clear_pointer(&config->presets, g_ptr_array_unref);
    g_free(config);
}

static void refresh_controls(Editor *editor) {
    gboolean editable = idle && !editor->pending && !editor->stale;
    gtk_widget_set_sensitive(editor->controls, editable);
    gtk_widget_set_sensitive(GTK_WIDGET(editor->save), editable && !editor->capturing);
}

static void configure_editor(gpointer pointer) {
    EditorConfiguration *incoming = pointer;
    g_free(configuration.revision);
    g_strfreev(configuration.names);
    g_clear_pointer(&configuration.presets, g_ptr_array_unref);
    configuration.revision = g_strdup(incoming->revision);
    configuration.names = g_strdupv(incoming->names);
    configuration.presets = g_ptr_array_ref(incoming->presets);
    configuration.reset = incoming->reset;
    if (active != NULL && g_strcmp0(active->revision, configuration.revision) != 0) {
        active->stale = TRUE;
        active->capturing = FALSE;
        if (!active->pending)
            gtk_label_set_text(active->notice, "Saved shortcuts changed. Close and reopen this editor; your draft was not saved.");
        refresh_controls(active);
    }
}

int32_t jsti_window_set_action_shortcut_editor(const char *revision, const char *const *names,
    const JSTILinuxActionShortcut *presets, size_t preset_count, size_t row_count, int32_t reset_index) {
    if (revision == NULL || !g_uuid_string_is_valid(revision) || names == NULL || presets == NULL ||
        preset_count == 0 || preset_count > 8 || row_count == 0 || row_count > 64 ||
        reset_index < 0 || (size_t)reset_index >= preset_count) return -1;
    EditorConfiguration *copy = g_new0(EditorConfiguration, 1);
    copy->revision = g_strdup(revision);
    copy->reset = (guint)reset_index;
    copy->names = g_new0(gchar *, preset_count + 1);
    copy->presets = g_ptr_array_new_with_free_func((GDestroyNotify)g_ptr_array_unref);
    for (size_t index = 0; index < preset_count; ++index) {
        GPtrArray *rows = jsti_action_shortcuts_copy_rows(presets + index * row_count, row_count);
        if (names[index] == NULL || !g_utf8_validate(names[index], -1, NULL) || rows == NULL) {
            if (rows != NULL) g_ptr_array_unref(rows);
            configuration_free(copy);
            return -1;
        }
        copy->names[index] = g_strdup(names[index]);
        g_ptr_array_add(copy->presets, rows);
    }
    return jsti_window_post(configure_editor, copy, configuration_free);
}

void jsti_action_shortcut_editor_rows(GPtrArray *rows) {
    GPtrArray *copy = g_ptr_array_ref(rows);
    g_clear_pointer(&saved_rows, g_ptr_array_unref);
    saved_rows = copy;
}

void jsti_action_shortcut_editor_set_idle(gboolean value) {
    idle = value;
    if (active != NULL) refresh_controls(active);
}

static ActionRow *selected(Editor *editor) {
    guint index = gtk_drop_down_get_selected(editor->action);
    return index < editor->rows->len ? g_ptr_array_index(editor->rows, index) : NULL;
}

static void show_selected(Editor *editor) {
    ActionRow *row = selected(editor);
    if (row == NULL) return;
    editor->loading = TRUE;
    editor->capturing = FALSE;
    gtk_button_set_label(editor->record, "Record key");
    gtk_label_set_text(editor->key, row->has_key ? row->chord : "Not set");
    adw_switch_row_set_active(editor->enabled, row->binding_enabled);
    gtk_widget_set_sensitive(GTK_WIDGET(editor->enabled), row->has_key);
    adw_switch_row_set_active(editor->global, row->binding_global);
    gtk_widget_set_sensitive(GTK_WIDGET(editor->global), row->can_be_global || row->binding_global);
    gtk_label_set_text(editor->notice, row->note);
    editor->loading = FALSE;
    refresh_controls(editor);
}

static void selection_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec;
    show_selected(data);
}

static void switches_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec;
    Editor *editor = data;
    ActionRow *row = selected(editor);
    if (editor->loading || row == NULL) return;
    row->binding_enabled = row->has_key && adw_switch_row_get_active(editor->enabled);
    row->binding_global = adw_switch_row_get_active(editor->global);
}

static void record_key(GtkButton *button, gpointer data) {
    Editor *editor = data;
    editor->capturing = TRUE;
    gtk_button_set_label(button, "Press a combination...");
    gtk_label_set_text(editor->notice,
        "Press Ctrl, Alt or Shift with a key. F13-F20 and Insert may be used alone. "
        "Ctrl+Alt+Space is reserved for dictation. Escape cancels recording.");
    refresh_controls(editor);
}

static void clear_key(GtkButton *button, gpointer data) {
    (void)button;
    Editor *editor = data;
    ActionRow *row = selected(editor);
    if (row == NULL) return;
    row->keysym = row->modifiers = 0;
    row->has_key = row->binding_enabled = FALSE;
    g_array_index(editor->changed, gboolean, gtk_drop_down_get_selected(editor->action)) = TRUE;
    show_selected(editor);
}

static void editor_free(gpointer pointer) {
    Editor *editor = pointer;
    if (active == editor) {
        active = NULL;
        g_atomic_int_set(&editor_open, 0);
    }
    g_ptr_array_unref(editor->rows);
    g_array_unref(editor->changed);
    g_free(editor->revision);
    g_free(editor->request);
    g_free(editor);
}

static void close_editor(Editor *editor) {
    GtkWindow *window = editor->window;
    editor->window = NULL;
    if (active == editor) {
        active = NULL;
        g_atomic_int_set(&editor_open, 0);
    }
    gtk_window_destroy(window);
}

static void cancel_edit(GtkButton *button, gpointer data) { (void)button; close_editor(data); }
static gboolean close_request(GtkWindow *window, gpointer data) {
    (void)window;
    close_editor(data);
    return TRUE;
}

void jsti_action_shortcut_editor_close(void) {
    if (active != NULL) close_editor(active);
}

static gboolean key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode,
                            GdkModifierType modifiers, gpointer data) {
    Editor *editor = data;
    if (keyval == GDK_KEY_Escape) {
        if (editor->capturing) show_selected(editor);
        else close_editor(editor);
        return TRUE;
    }
    if (!editor->capturing || editor->pending || editor->stale || !idle) return FALSE;
    if (keyval == GDK_KEY_Tab && (modifiers & ~GDK_LOCK_MASK) == 0) {
        show_selected(editor);
        return FALSE;
    }
    GdkEvent *event = controller != NULL ?
        gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller)) : NULL;
    if (event != NULL && gdk_event_get_event_type(event) == GDK_KEY_PRESS) {
        if (gdk_key_event_is_modifier(event)) return TRUE;
        if (gdk_key_event_get_consumed_modifiers(event) & (GDK_CONTROL_MASK | GDK_ALT_MASK)) {
            gtk_label_set_text(editor->notice, "AltGr is reserved for typing. Use another combination.");
            return TRUE;
        }
        guint base;
        if (gdk_display_translate_key(gdk_event_get_display(event), keycode, 0,
            gdk_key_event_get_layout(event), &base, NULL, NULL, NULL)) keyval = base;
    }
    guint relevant = modifiers & (GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_ALT_MASK |
                                  GDK_SUPER_MASK | GDK_HYPER_MASK | GDK_META_MASK);
    if (relevant & ~13u) {
        gtk_label_set_text(editor->notice, "Use Ctrl, Alt or Shift; Super/Meta combinations cannot be saved in the shared format.");
        return TRUE;
    }
    ActionRow *row = selected(editor);
    if (row == NULL) return TRUE;
    row->keysym = gdk_keyval_to_lower(keyval);
    row->modifiers = relevant;
    row->has_key = TRUE;
    g_free(row->chord);
    row->chord = gtk_accelerator_get_label(row->keysym, relevant);
    g_array_index(editor->changed, gboolean, gtk_drop_down_get_selected(editor->action)) = TRUE;
    show_selected(editor);
    return TRUE;
}

static void apply_preset(Editor *editor, guint index) {
    if (configuration.presets == NULL || index >= configuration.presets->len) return;
    GPtrArray *rows = g_ptr_array_index(configuration.presets, index);
    if (rows->len != editor->rows->len) return;
    g_ptr_array_unref(editor->rows);
    editor->rows = jsti_action_shortcuts_clone_rows(rows);
    for (guint i = 0; i < editor->changed->len; ++i) g_array_index(editor->changed, gboolean, i) = TRUE;
    show_selected(editor);
    gtk_label_set_text(editor->notice, "Preset applied to the draft. Choose Save to persist it.");
}

static void use_preset(GtkButton *button, gpointer data) {
    (void)button;
    Editor *editor = data;
    apply_preset(editor, gtk_drop_down_get_selected(editor->preset));
}
static void reset_defaults(GtkButton *button, gpointer data) {
    (void)button;
    apply_preset(data, configuration.reset);
}

static void save_edit(GtkButton *button, gpointer data) {
    (void)button;
    Editor *editor = data;
    if (!idle || editor->pending || editor->stale || editor->capturing) return;
    g_free(editor->request);
    editor->request = g_uuid_string_random();
    GString *wire = g_string_new(editor->revision);
    g_string_append_printf(wire, "\t%s\n", editor->request);
    for (guint i = 0; i < editor->rows->len; ++i) {
        const ActionRow *row = g_ptr_array_index(editor->rows, i);
        gchar *identifier = g_uri_escape_string(row->identifier, NULL, FALSE);
        g_string_append_printf(wire, "%s\t%u\t%u\t%d\t%d\t%d\n", identifier, row->keysym, row->modifiers,
            row->binding_enabled, row->binding_global, g_array_index(editor->changed, gboolean, i));
        g_free(identifier);
    }
    editor->pending = TRUE;
    gtk_label_set_text(editor->notice, "Saving shortcuts...");
    refresh_controls(editor);
    emit_edit(JSTI_EVENT_ACTION_SHORTCUT_EDIT, wire->str, 0);
    g_string_free(wire, TRUE);
}

typedef struct { gchar *request, *message; gboolean success; } Completion;
static void completion_free(gpointer pointer) {
    Completion *completion = pointer;
    g_free(completion->request);
    g_free(completion->message);
    g_free(completion);
}
static void finish_edit(gpointer pointer) {
    Completion *completion = pointer;
    if (active == NULL || !active->pending ||
        (g_ascii_strcasecmp(active->request, completion->request) != 0 &&
         (completion->success || completion->request[0] != '\0'))) return;
    if (completion->success) { close_editor(active); return; }
    active->pending = FALSE;
    gtk_label_set_text(active->notice, completion->message);
    refresh_controls(active);
}
int32_t jsti_action_shortcuts_edit_finished(const char *request, int32_t success, const char *message) {
    if (request == NULL || message == NULL || !g_utf8_validate(message, -1, NULL) ||
        (success != 0 && success != 1) || (request[0] != '\0' && !g_uuid_string_is_valid(request)) ||
        (success && request[0] == '\0')) return -1;
    Completion *copy = g_new0(Completion, 1);
    copy->request = g_strdup(request);
    copy->message = g_strdup(message);
    copy->success = success != 0;
    return jsti_window_post(finish_edit, copy, completion_free);
}

static GtkWidget *wrapped(const char *text) {
    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_selectable(GTK_LABEL(label), TRUE);
    return label;
}
static GtkWidget *button(const char *title, GCallback callback, Editor *editor) {
    GtkWidget *widget = gtk_button_new_with_label(title);
    gtk_widget_set_size_request(widget, -1, 44);
    g_signal_connect(widget, "clicked", callback, editor);
    return widget;
}

void jsti_action_shortcut_editor_open(GtkWindow *owner) {
    if (active != NULL) { gtk_window_present(active->window); return; }
    if (!idle || configuration.revision == NULL || saved_rows == NULL || saved_rows->len == 0) {
        jsti_window_update("Action shortcuts are not ready to edit. Wait for recording or setup to finish.", NULL, -1);
        return;
    }
    Editor *editor = g_new0(Editor, 1);
    editor->window = GTK_WINDOW(gtk_window_new());
    editor->rows = jsti_action_shortcuts_clone_rows(saved_rows);
    editor->revision = g_strdup(configuration.revision);
    editor->changed = g_array_sized_new(FALSE, TRUE, sizeof(gboolean), editor->rows->len);
    g_array_set_size(editor->changed, editor->rows->len);
    gtk_window_set_title(editor->window, "Action shortcuts");
    gtk_window_set_default_size(editor->window, 620, 650);
    gtk_widget_set_size_request(GTK_WIDGET(editor->window), 360, 480);
    gtk_window_set_transient_for(editor->window, owner);
    gtk_window_set_modal(editor->window, TRUE);
    gtk_window_set_destroy_with_parent(editor->window, TRUE);
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *scroll = gtk_scrolled_window_new(), *body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_margin_start(body, 20); gtk_widget_set_margin_end(body, 20);
    gtk_widget_set_margin_top(body, 20); gtk_widget_set_margin_bottom(body, 20);
    gtk_window_set_child(editor->window, root);
    gtk_box_append(GTK_BOX(root), scroll);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), body);
    gtk_box_append(GTK_BOX(body), wrapped(
        "Choose an action and record its key. Changes stay in this draft until Save. "
        "Supported global bindings register on X11. Wayland uses desktop keyboard settings."));
    editor->controls = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_box_append(GTK_BOX(body), editor->controls);
    GtkStringList *titles = gtk_string_list_new(NULL);
    for (guint i = 0; i < editor->rows->len; ++i)
        gtk_string_list_append(titles, ((ActionRow *)g_ptr_array_index(editor->rows, i))->title);
    editor->action = GTK_DROP_DOWN(gtk_drop_down_new(G_LIST_MODEL(titles), NULL));
    gtk_accessible_update_property(GTK_ACCESSIBLE(editor->action), GTK_ACCESSIBLE_PROPERTY_LABEL, "Action", -1);
    gtk_widget_set_size_request(GTK_WIDGET(editor->action), -1, 44);
    gtk_box_append(GTK_BOX(editor->controls), GTK_WIDGET(editor->action));
    editor->key = GTK_LABEL(wrapped(""));
    gtk_box_append(GTK_BOX(editor->controls), GTK_WIDGET(editor->key));
    GtkWidget *keys = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    editor->record = GTK_BUTTON(button("Record key", G_CALLBACK(record_key), editor));
    gtk_widget_set_hexpand(GTK_WIDGET(editor->record), TRUE);
    gtk_box_append(GTK_BOX(keys), GTK_WIDGET(editor->record));
    gtk_box_append(GTK_BOX(keys), button("Clear", G_CALLBACK(clear_key), editor));
    gtk_box_append(GTK_BOX(editor->controls), keys);
    GtkWidget *switches = adw_preferences_group_new();
    editor->enabled = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(editor->enabled), "Enabled");
    editor->global = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(editor->global), "Work in other apps");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(editor->global),
        "X11 registers supported actions after saving. Check Action shortcuts for availability.");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(switches), GTK_WIDGET(editor->enabled));
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(switches), GTK_WIDGET(editor->global));
    gtk_box_append(GTK_BOX(editor->controls), switches);
    editor->preset = GTK_DROP_DOWN(gtk_drop_down_new_from_strings((const char *const *)configuration.names));
    gtk_accessible_update_property(GTK_ACCESSIBLE(editor->preset), GTK_ACCESSIBLE_PROPERTY_LABEL, "Preset", -1);
    gtk_widget_set_size_request(GTK_WIDGET(editor->preset), -1, 44);
    gtk_box_append(GTK_BOX(editor->controls), GTK_WIDGET(editor->preset));
    gtk_box_append(GTK_BOX(editor->controls), button("Apply preset to draft", G_CALLBACK(use_preset), editor));
    gtk_box_append(GTK_BOX(editor->controls), button("Reset draft to defaults", G_CALLBACK(reset_defaults), editor));
    GtkWidget *footer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(footer, 20); gtk_widget_set_margin_end(footer, 20);
    gtk_widget_set_margin_top(footer, 12); gtk_widget_set_margin_bottom(footer, 20);
    gtk_box_append(GTK_BOX(root), footer);
    editor->notice = GTK_LABEL(wrapped(""));
    gtk_box_append(GTK_BOX(footer), GTK_WIDGET(editor->notice));
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(actions, GTK_ALIGN_END);
    gtk_box_append(GTK_BOX(actions), button("Cancel", G_CALLBACK(cancel_edit), editor));
    editor->save = GTK_BUTTON(button("Save", G_CALLBACK(save_edit), editor));
    gtk_widget_add_css_class(GTK_WIDGET(editor->save), "suggested-action");
    gtk_box_append(GTK_BOX(actions), GTK_WIDGET(editor->save));
    gtk_box_append(GTK_BOX(footer), actions);
    g_signal_connect(editor->action, "notify::selected", G_CALLBACK(selection_changed), editor);
    g_signal_connect(editor->enabled, "notify::active", G_CALLBACK(switches_changed), editor);
    g_signal_connect(editor->global, "notify::active", G_CALLBACK(switches_changed), editor);
    g_signal_connect(editor->window, "close-request", G_CALLBACK(close_request), editor);
    GtkEventController *controller = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE);
    g_signal_connect(controller, "key-pressed", G_CALLBACK(key_pressed), editor);
    gtk_widget_add_controller(GTK_WIDGET(editor->window), controller);
    g_object_set_data_full(G_OBJECT(editor->window), "jsti-action-editor", editor, editor_free);
    active = editor;
    g_atomic_int_set(&editor_open, 1);
    show_selected(editor);
    gtk_window_present(editor->window);
}

static gchar *captured_wire;
static void capture_edit(gint32 event, const char *wire, gint32 index) {
    (void)index;
    if (event != JSTI_EVENT_ACTION_SHORTCUT_EDIT) return;
    g_free(captured_wire);
    captured_wire = g_strdup(wire);
}

int32_t jsti_action_shortcut_editor_self_test(GtkWindow *owner, char *error, size_t capacity) {
    if (active != NULL || configuration.presets == NULL || saved_rows == NULL || saved_rows->len == 0) {
        jsti_set_error(error, capacity, "action shortcut editor configuration is unavailable");
        return -1;
    }
    gboolean original_idle = idle;
    gchar *original_revision = g_strdup(configuration.revision);
    void (*original_emit)(gint32, const char *, gint32) = emit_edit;
    emit_edit = capture_edit;
    idle = TRUE;
    jsti_action_shortcut_editor_open(owner);
    Editor *editor = active;
    if (editor == NULL) {
        emit_edit = original_emit;
        idle = original_idle;
        g_free(original_revision);
        jsti_set_error(error, capacity, "action shortcut editor did not open");
        return -1;
    }
    gboolean okay = jsti_action_shortcuts_editor_is_open() &&
        editor->rows->len == saved_rows->len && !editor->pending;
    guint original_symbol = ((ActionRow *)g_ptr_array_index(saved_rows, 0))->keysym;
    record_key(editor->record, editor);
    okay = okay && key_pressed(NULL, GDK_KEY_J, 44, GDK_CONTROL_MASK | GDK_ALT_MASK, editor) &&
        selected(editor)->keysym == GDK_KEY_j && selected(editor)->modifiers == 12 &&
        g_array_index(editor->changed, gboolean, 0) &&
        ((ActionRow *)g_ptr_array_index(saved_rows, 0))->keysym == original_symbol;
    clear_key(NULL, editor);
    okay = okay && !selected(editor)->has_key && !selected(editor)->binding_enabled;
    guint off = configuration.presets->len;
    for (guint p = 0; p < configuration.presets->len; ++p) {
        GPtrArray *preset = g_ptr_array_index(configuration.presets, p);
        gboolean disabled = TRUE;
        for (guint i = 0; i < preset->len; ++i)
            disabled = disabled && !((ActionRow *)g_ptr_array_index(preset, i))->binding_enabled;
        if (disabled) { off = p; break; }
    }
    okay = okay && off < configuration.presets->len;
    if (off < configuration.presets->len) apply_preset(editor, off);
    for (guint i = 0; i < editor->rows->len; ++i)
        okay = okay && !((ActionRow *)g_ptr_array_index(editor->rows, i))->binding_enabled;
    reset_defaults(NULL, editor);
    GPtrArray *defaults = g_ptr_array_index(configuration.presets, configuration.reset);
    for (guint i = 0; i < editor->rows->len; ++i)
        okay = okay && ((ActionRow *)g_ptr_array_index(editor->rows, i))->binding_enabled ==
            ((ActionRow *)g_ptr_array_index(defaults, i))->binding_enabled;
    save_edit(NULL, editor);
    okay = okay && editor->pending && captured_wire != NULL &&
        g_str_has_prefix(captured_wire, editor->revision) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(editor->save));
    gchar *old_request = g_strdup(editor->request);
    gchar *canonical_request = g_ascii_strup(old_request, -1);
    Completion failed = { .request = canonical_request, .message = (gchar *)"fixture write failure" };
    finish_edit(&failed);
    okay = okay && active == editor && !editor->pending &&
        g_strcmp0(gtk_label_get_text(editor->notice), "fixture write failure") == 0;
    save_edit(NULL, editor);
    Completion late = { .request = old_request, .message = (gchar *)"", .success = TRUE };
    finish_edit(&late);
    okay = okay && active == editor && editor->pending;
    close_editor(editor);
    okay = okay && !jsti_action_shortcuts_editor_is_open();
    jsti_action_shortcut_editor_open(owner);
    okay = okay && active != NULL;
    finish_edit(&late);
    okay = okay && active != NULL && !active->pending;
    /* The setter owns a copy; emulate a queued external settings update. */
    EditorConfiguration *copy = g_new0(EditorConfiguration, 1);
    copy->revision = g_uuid_string_random();
    copy->names = g_strdupv(configuration.names);
    copy->presets = g_ptr_array_ref(configuration.presets);
    copy->reset = configuration.reset;
    configure_editor(copy);
    configuration_free(copy);
    okay = okay && active != NULL && active->stale && !gtk_widget_get_sensitive(GTK_WIDGET(active->save));
    jsti_action_shortcut_editor_close();
    g_free(configuration.revision);
    configuration.revision = original_revision;
    g_free(canonical_request);
    g_free(old_request);
    g_clear_pointer(&captured_wire, g_free);
    emit_edit = original_emit;
    idle = original_idle;
    if (!okay) jsti_set_error(error, capacity, "action shortcut draft, preset, save-failure or request fence failed");
    return okay ? 0 : -1;
}
