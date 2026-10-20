#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

typedef struct {
    GtkWindow *window;
    AdwComboRow *provider;
    AdwPasswordEntryRow *key;
    AdwActionRow *details;
    GtkLabel *message;
    GtkWidget *save, *check, *remove, *refresh, *website;
    GPtrArray *rows;
    gchar *identity, *selection_epoch, *request;
    gboolean pending, suppress;
} Form;
typedef struct { GPtrArray *rows; gchar *request, *message; } Delivery;
static Form *active;
static GtkWidget *entry_button;
static gboolean idle = TRUE;
static GMutex lock;
static jsti_api_keys_fn callback;
static gpointer context;
static gchar *current_request;
static gboolean opened;

static gboolean same(const char *first, const char *second) {
    return first != NULL && second != NULL && g_ascii_strcasecmp(first, second) == 0;
}
static gboolean text_valid(const char *text, gsize maximum) {
    return text != NULL && strlen(text) <= maximum && g_utf8_validate(text, -1, NULL);
}
int32_t jsti_api_keys_configure(jsti_api_keys_fn fn, void *data) {
    if (fn == NULL || data == NULL) return -1;
    g_mutex_lock(&lock);
    gboolean available = callback == NULL;
    if (available) { callback = fn; context = data; }
    g_mutex_unlock(&lock);
    return available ? 0 : -1;
}
void jsti_api_keys_clear(void) {
    g_mutex_lock(&lock);
    callback = NULL; context = NULL; opened = FALSE;
    g_clear_pointer(&current_request, g_free);
    g_mutex_unlock(&lock);
}
int32_t jsti_api_keys_is_open(void) {
    g_mutex_lock(&lock);
    gboolean result = opened;
    g_mutex_unlock(&lock);
    return result ? 1 : 0;
}
int32_t jsti_api_keys_request_is_current(const char *request) {
    g_mutex_lock(&lock);
    gboolean result = opened && same(current_request, request);
    g_mutex_unlock(&lock);
    return result ? 1 : 0;
}
static void row_free(gpointer data) {
    JSTILinuxAPIKeyRow *row = data;
    g_free((gpointer)row->identifier); g_free((gpointer)row->label); g_free((gpointer)row->uses);
    g_free((gpointer)row->status); g_free((gpointer)row->url); g_free((gpointer)row->hint); g_free(row);
}
static const JSTILinuxAPIKeyRow *selected(Form *form) {
    guint index = adw_combo_row_get_selected(form->provider);
    return form->rows != NULL && index < form->rows->len ? g_ptr_array_index(form->rows, index) : NULL;
}
static void enable(Form *form) {
    const JSTILinuxAPIKeyRow *row = selected(form);
    gboolean available = idle && !form->pending;
    gtk_widget_set_sensitive(GTK_WIDGET(form->provider), available);
    gtk_widget_set_sensitive(GTK_WIDGET(form->key), available && row != NULL);
    gtk_widget_set_sensitive(form->save, available && row != NULL);
    gtk_widget_set_sensitive(form->check, available && row != NULL);
    gtk_widget_set_sensitive(form->remove, available && row != NULL && row->saved);
    gtk_widget_set_sensitive(form->website, available && row != NULL && row->url[0] != '\0');
    gtk_widget_set_sensitive(form->refresh, available);
}
static void show_selection(Form *form) {
    gtk_editable_set_text(GTK_EDITABLE(form->key), "");
    g_free(form->selection_epoch); form->selection_epoch = g_uuid_string_random();
    const JSTILinuxAPIKeyRow *row = selected(form);
    gchar *detail = row == NULL ? g_strdup("Refresh to load the shared provider catalogue.")
        : g_strdup_printf("%s\n%s\n%s", row->uses, row->status, row->hint);
    adw_action_row_set_subtitle(form->details, detail);
    g_free(detail);
    enable(form);
}
static void selection_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; Form *form = data;
    if (!form->suppress) show_selection(form);
}
static void request(Form *form, gint action) {
    if (form->pending || !idle) return;
    const JSTILinuxAPIKeyRow *row = selected(form);
    if (action != JSTI_LINUX_API_KEY_REFRESH && row == NULL) return;
    const gchar *typed = gtk_editable_get_text(GTK_EDITABLE(form->key));
    if (strlen(typed) > 8192 || (action == JSTI_LINUX_API_KEY_SAVE && typed[0] == '\0')) {
        gtk_label_set_text(form->message, typed[0] == '\0'
            ? "Enter a new key. Blank input never removes a saved key."
            : "The key exceeds 8,192 UTF-8 bytes. Enter the complete key within that limit.");
        return;
    }
    g_mutex_lock(&lock);
    jsti_api_keys_fn fn = callback; gpointer data = context;
    g_mutex_unlock(&lock);
    if (fn == NULL) {
        gtk_label_set_text(form->message, "API Keys is unavailable. Close and reopen the app.");
        return;
    }
    gchar *secret = g_strdup(action == JSTI_LINUX_API_KEY_REMOVE || action == JSTI_LINUX_API_KEY_REFRESH ? "" : typed);
    gtk_editable_set_text(GTK_EDITABLE(form->key), "");
    g_free(form->request); form->request = g_uuid_string_random();
    g_mutex_lock(&lock);
    g_free(current_request); current_request = g_strdup(form->request);
    g_mutex_unlock(&lock);
    form->pending = TRUE;
    enable(form);
    gtk_label_set_text(form->message, action == JSTI_LINUX_API_KEY_REFRESH
        ? "Reading saved key states. Your desktop keyring may need to be unlocked."
        : "Working on the selected provider key...");
    fn(action, form->request, row == NULL ? "" : row->identifier, secret, data);
    volatile gchar *wipe = secret;
    for (gsize index = 0, length = strlen(secret); index < length; ++index) wipe[index] = 0;
    g_free(secret);
}
static void save_clicked(GtkButton *button, gpointer data) { (void)button; request(data, JSTI_LINUX_API_KEY_SAVE); }
static void check_clicked(GtkButton *button, gpointer data) { (void)button; request(data, JSTI_LINUX_API_KEY_VALIDATE); }
static void refresh_clicked(GtkButton *button, gpointer data) { (void)button; request(data, JSTI_LINUX_API_KEY_REFRESH); }

typedef struct { gchar *identity, *epoch; } Removal;
static void removal_free(gpointer data) {
    Removal *value = data; g_free(value->identity); g_free(value->epoch); g_free(value);
}
static void removal_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)dialog; Removal *value = data;
    if (g_strcmp0(response, "remove") == 0 && active != NULL && same(active->identity, value->identity) &&
        same(active->selection_epoch, value->epoch)) request(active, JSTI_LINUX_API_KEY_REMOVE);
}
static void remove_clicked(GtkButton *button, gpointer data) {
    (void)button; Form *form = data;
    if (!gtk_widget_get_sensitive(form->remove)) return;
    const JSTILinuxAPIKeyRow *row = selected(form);
    gchar *heading = g_strdup_printf("Remove %s key?", row->label);
    GtkWidget *dialog = adw_message_dialog_new(form->window, heading,
        "Every feature using this same provider key will lose access. Cancel keeps the saved key.");
    g_free(heading);
    gtk_window_set_destroy_with_parent(GTK_WINDOW(dialog), TRUE);
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "remove", "Remove saved key", NULL);
    adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "remove", ADW_RESPONSE_DESTRUCTIVE);
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    Removal *value = g_new0(Removal, 1);
    value->identity = g_strdup(form->identity); value->epoch = g_strdup(form->selection_epoch);
    g_object_set_data_full(G_OBJECT(dialog), "api-key-removal", value, removal_free);
    g_signal_connect(dialog, "response", G_CALLBACK(removal_response), value);
    gtk_window_present(GTK_WINDOW(dialog));
}
static void website_finished(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data; GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result, &error)) {
        (void)jsti_window_update("The provider key website could not be opened.", NULL, -1);
        g_clear_error(&error);
    }
}
static void website_clicked(GtkButton *button, gpointer data) {
    (void)button; Form *form = data;
    const JSTILinuxAPIKeyRow *row = selected(form);
    if (row == NULL || row->url[0] == '\0') return;
    GtkUriLauncher *launcher = gtk_uri_launcher_new(row->url);
    gtk_uri_launcher_launch(launcher, form->window, NULL, website_finished, NULL);
    g_object_unref(launcher);
}
static void retire(Form *form) {
    if (active != form) return;
    active = NULL;
    g_mutex_lock(&lock);
    opened = FALSE;
    g_clear_pointer(&current_request, g_free);
    jsti_api_keys_fn fn = callback; gpointer data = context;
    g_mutex_unlock(&lock);
    if (fn != NULL && form->pending) fn(JSTI_LINUX_API_KEY_CANCEL, form->request, "", "", data);
}
static gboolean closing(GtkWindow *window, gpointer data) {
    (void)window; Form *form = data;
    gtk_editable_set_text(GTK_EDITABLE(form->key), "");
    retire(form); return FALSE;
}
static void form_free(gpointer data) {
    Form *form = data;
    retire(form);
    g_clear_pointer(&form->rows, g_ptr_array_unref);
    g_free(form->identity); g_free(form->selection_epoch); g_free(form->request); g_free(form);
}
void jsti_api_keys_close(void) {
    Form *form = active;
    if (form != NULL) {
        gtk_editable_set_text(GTK_EDITABLE(form->key), "");
        retire(form); gtk_window_destroy(form->window);
    }
}
static gboolean key_pressed(GtkEventControllerKey *controller, guint key, guint code,
                            GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)code; (void)modifiers; Form *form = data;
    if (key != GDK_KEY_Escape) return FALSE;
    gtk_window_close(form->window); return TRUE;
}
static GtkWidget *button(const char *title, GCallback fn, Form *form) {
    GtkWidget *widget = gtk_button_new_with_label(title);
    gtk_widget_set_size_request(widget, -1, 44);
    g_signal_connect(widget, "clicked", fn, form);
    return widget;
}
static void key_unmapped(GtkWidget *widget, gpointer data) {
    (void)data; gtk_editable_set_text(GTK_EDITABLE(widget), "");
}
void jsti_api_keys_open(GtkWindow *owner) {
    if (!idle) { (void)jsti_window_update("Finish the current operation before opening API Keys.", NULL, -1); return; }
    if (active != NULL) { gtk_window_present(active->window); return; }
    Form *form = g_new0(Form, 1);
    active = form; form->identity = g_uuid_string_random();
    form->window = GTK_WINDOW(adw_window_new());
    gtk_window_set_title(form->window, "API Keys");
    gtk_window_set_default_size(form->window, 580, 580);
    gtk_window_set_transient_for(form->window, owner);
    gtk_window_set_destroy_with_parent(form->window, TRUE);
    gtk_window_set_modal(form->window, TRUE);
    gtk_window_set_application(form->window, gtk_window_get_application(owner));
    g_object_set_data_full(G_OBJECT(form->window), "api-keys-form", form, form_free);
    g_signal_connect(form->window, "close-request", G_CALLBACK(closing), form);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), form);
    gtk_widget_add_controller(GTK_WIDGET(form->window), keys);
    GtkWidget *toolbar = adw_toolbar_view_new();
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(toolbar), adw_header_bar_new());
    GtkWidget *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_widget_set_margin_start(column, 20); gtk_widget_set_margin_end(column, 20);
    gtk_widget_set_margin_top(column, 16); gtk_widget_set_margin_bottom(column, 20);
    GtkWidget *scrolled = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scrolled, TRUE);
    GtkWidget *group = adw_preferences_group_new();
    adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(group), "Provider credentials");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(group),
        "Opening and refreshing read your desktop keyring, not the provider. Save validates before storing; "
        "Check key also contacts the selected provider. Stored keys are never shown or prefilled.");
    form->provider = ADW_COMBO_ROW(adw_combo_row_new());
    adw_combo_row_set_enable_search(form->provider, TRUE);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(form->provider), "Provider");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(form->provider));
    form->details = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(form->details), FALSE);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(form->details), "Uses and saved key state");
    adw_action_row_set_subtitle_lines(form->details, 0);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(form->details));
    form->key = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(form->key), "New API key (blank keeps saved key)");
    gtk_editable_set_enable_undo(GTK_EDITABLE(form->key), FALSE);
    g_signal_connect(form->key, "unmap", G_CALLBACK(key_unmapped), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), GTK_WIDGET(form->key));
    GtkWidget *privacy = gtk_label_new("Closing cancels pending validation. A storage operation already started may finish.");
    gtk_label_set_wrap(GTK_LABEL(privacy), TRUE); gtk_label_set_xalign(GTK_LABEL(privacy), 0);
    gtk_widget_set_margin_top(privacy, 12);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), privacy);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), group);
    gtk_box_append(GTK_BOX(column), scrolled);
    form->message = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(form->message, TRUE); gtk_label_set_xalign(form->message, 0);
    gtk_label_set_wrap_mode(form->message, PANGO_WRAP_WORD_CHAR);
    gtk_label_set_selectable(form->message, TRUE);
    GtkWidget *result = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(result), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(result), TRUE);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(result), 48);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(result), 120);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(result), GTK_WIDGET(form->message));
    gtk_box_append(GTK_BOX(column), result);
    GtkWidget *primary = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    form->save = button("Save and validate", G_CALLBACK(save_clicked), form);
    gtk_widget_add_css_class(form->save, "suggested-action");
    form->check = button("Check key", G_CALLBACK(check_clicked), form);
    form->remove = button("Remove saved key", G_CALLBACK(remove_clicked), form);
    gtk_box_append(GTK_BOX(primary), form->save); gtk_box_append(GTK_BOX(primary), form->check);
    gtk_box_append(GTK_BOX(primary), form->remove);
    gtk_box_append(GTK_BOX(column), primary);
    GtkWidget *secondary = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    form->refresh = button("Refresh", G_CALLBACK(refresh_clicked), form);
    form->website = button("Get provider key", G_CALLBACK(website_clicked), form);
    gtk_box_append(GTK_BOX(secondary), form->refresh); gtk_box_append(GTK_BOX(secondary), form->website);
    gtk_box_append(GTK_BOX(column), secondary);
    g_signal_connect(form->provider, "notify::selected", G_CALLBACK(selection_changed), form);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(toolbar), column);
    adw_window_set_content(ADW_WINDOW(form->window), toolbar);
    g_mutex_lock(&lock); opened = TRUE; g_mutex_unlock(&lock);
    show_selection(form);
    gtk_window_present(form->window);
    request(form, JSTI_LINUX_API_KEY_REFRESH);
}
static void open_clicked(GtkButton *widget, gpointer owner) { (void)widget; jsti_api_keys_open(owner); }
GtkWidget *jsti_api_keys_group_new(GtkWindow *owner) {
    GtkWidget *group = adw_preferences_group_new();
    adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(group), "API Keys");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(group),
        "Manage the shared keys for transcription, post-processing and Voice Output in your desktop keyring.");
    entry_button = gtk_button_new_with_label("Manage API Keys...");
    g_object_add_weak_pointer(G_OBJECT(entry_button), (gpointer *)&entry_button);
    gtk_widget_set_halign(entry_button, GTK_ALIGN_START);
    gtk_widget_set_size_request(entry_button, -1, 44);
    g_signal_connect(entry_button, "clicked", G_CALLBACK(open_clicked), owner);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), entry_button);
    gtk_widget_set_sensitive(entry_button, idle);
    return group;
}
void jsti_api_keys_set_idle(gboolean value) {
    idle = value;
    if (entry_button != NULL) gtk_widget_set_sensitive(entry_button, value);
    if (active != NULL) {
        if (!value) gtk_editable_set_text(GTK_EDITABLE(active->key), "");
        enable(active);
    }
}
static void delivery_free(gpointer data) {
    Delivery *value = data; g_ptr_array_unref(value->rows);
    g_free(value->request); g_free(value->message); g_free(value);
}
static void delivery_apply(gpointer data) {
    Delivery *value = data; Form *form = active;
    if (form == NULL || !form->pending || !same(form->request, value->request) ||
        !jsti_api_keys_request_is_current(value->request)) return;
    const JSTILinuxAPIKeyRow *before = selected(form);
    gchar *identifier = before == NULL ? NULL : g_strdup(before->identifier);
    g_clear_pointer(&form->rows, g_ptr_array_unref);
    form->rows = g_ptr_array_ref(value->rows);
    GtkStringList *names = gtk_string_list_new(NULL);
    guint selection = 0;
    for (guint index = 0; index < form->rows->len; ++index) {
        const JSTILinuxAPIKeyRow *row = g_ptr_array_index(form->rows, index);
        gtk_string_list_append(names, row->label);
        if (g_strcmp0(identifier, row->identifier) == 0) selection = index;
    }
    g_free(identifier);
    form->suppress = TRUE;
    adw_combo_row_set_model(form->provider, G_LIST_MODEL(names));
    adw_combo_row_set_selected(form->provider, selection);
    g_object_unref(names);
    form->suppress = FALSE; form->pending = FALSE;
    gtk_label_set_text(form->message, value->message);
    show_selection(form);
}
static Delivery *delivery_copy(const JSTILinuxAPIKeyRow *rows, gsize count, const char *request_id, const char *message) {
    if (count > 128 || (count != 0 && rows == NULL) || !text_valid(message, 8192) ||
        request_id == NULL || !g_uuid_string_is_valid(request_id)) return NULL;
    Delivery *value = g_new0(Delivery, 1);
    value->request = g_strdup(request_id); value->message = g_strdup(message);
    value->rows = g_ptr_array_new_with_free_func(row_free);
    for (gsize index = 0; index < count; ++index) {
        const JSTILinuxAPIKeyRow *row = &rows[index];
        gboolean valid = text_valid(row->identifier, 128) && row->identifier[0] != '\0' &&
            text_valid(row->label, 512) && row->label[0] != '\0' && text_valid(row->uses, 1024) &&
            text_valid(row->status, 2048) && text_valid(row->hint, 4096) && text_valid(row->url, 2048) &&
            (row->url[0] == '\0' || g_str_has_prefix(row->url, "https://")) && (row->saved == 0 || row->saved == 1);
        for (gsize previous = 0; valid && previous < index; ++previous)
            valid = g_strcmp0(rows[previous].identifier, row->identifier) != 0;
        if (!valid) { delivery_free(value); return NULL; }
        JSTILinuxAPIKeyRow *copy = g_new0(JSTILinuxAPIKeyRow, 1);
        copy->identifier = g_strdup(row->identifier); copy->label = g_strdup(row->label);
        copy->uses = g_strdup(row->uses); copy->status = g_strdup(row->status);
        copy->hint = g_strdup(row->hint); copy->url = g_strdup(row->url); copy->saved = row->saved;
        g_ptr_array_add(value->rows, copy);
    }
    return value;
}
int32_t jsti_api_keys_finish(const JSTILinuxAPIKeyRow *rows, size_t count, const char *request_id, const char *message) {
    Delivery *value = delivery_copy(rows, count, request_id, message);
    return value == NULL ? -1 : jsti_window_post(delivery_apply, value, delivery_free);
}

typedef struct {
    gint calls, action, cancels;
    gboolean valid;
    gchar request[37];
} Fixture;
static void fixture_callback(int32_t action, const char *ticket, const char *identifier,
                             const char *secret, void *data) {
    Fixture *fixture = data;
    ++fixture->calls; fixture->action = action;
    fixture->valid = fixture->valid && g_uuid_string_is_valid(ticket);
    g_strlcpy(fixture->request, ticket, sizeof(fixture->request));
    if (action == JSTI_LINUX_API_KEY_CANCEL) ++fixture->cancels;
    else if (action != JSTI_LINUX_API_KEY_REFRESH) {
        fixture->valid = fixture->valid && g_strcmp0(identifier, "second.apiKey") == 0 &&
            g_strcmp0(secret, action == JSTI_LINUX_API_KEY_SAVE ? "synthetic-key" : "") == 0;
    }
}
int32_t jsti_api_keys_self_test(GtkWindow *owner, char *error, size_t capacity) {
    if (active != NULL) { jsti_set_error(error, capacity, "API Keys is already open."); return -1; }
    Fixture fixture = { .valid = TRUE };
    gboolean saved_idle = idle;
    g_mutex_lock(&lock);
    jsti_api_keys_fn saved_callback = callback; gpointer saved_context = context;
    callback = fixture_callback; context = &fixture;
    g_mutex_unlock(&lock);
    jsti_api_keys_set_idle(TRUE);
    jsti_api_keys_open(owner);
    JSTILinuxAPIKeyRow rows[] = {
        { "first.apiKey", "First", "Transcription", "Not set", "https://example.invalid/keys", "Paste a key", 0 },
        { "second.apiKey", "Second", "Voice Output", "Saved suffix", "", "Paste a key", 1 }
    };
    gboolean valid = fixture.calls == 1 && fixture.action == JSTI_LINUX_API_KEY_REFRESH && active->pending;
    gchar *uppercase = g_ascii_strup(fixture.request, -1);
    Delivery *value = delivery_copy(rows, 2, uppercase, "Synthetic key states");
    delivery_apply(value); delivery_free(value); g_free(uppercase);
    valid = valid && !active->pending && gtk_window_get_modal(active->window) &&
        !gtk_widget_get_sensitive(active->remove);
    gtk_editable_set_text(GTK_EDITABLE(active->key), "discard-on-selection");
    adw_combo_row_set_selected(active->provider, 1);
    valid = valid && gtk_editable_get_text(GTK_EDITABLE(active->key))[0] == '\0' &&
        gtk_widget_get_sensitive(active->remove) && !gtk_widget_get_sensitive(active->website);
    gtk_editable_set_text(GTK_EDITABLE(active->key), "");
    request(active, JSTI_LINUX_API_KEY_SAVE);
    valid = valid && fixture.calls == 1;
    gtk_editable_set_text(GTK_EDITABLE(active->key), "synthetic-key");
    gchar *old = g_strdup(fixture.request);
    request(active, JSTI_LINUX_API_KEY_SAVE);
    valid = valid && fixture.calls == 2 && fixture.action == JSTI_LINUX_API_KEY_SAVE && active->pending &&
        gtk_editable_get_text(GTK_EDITABLE(active->key))[0] == '\0' &&
        !gtk_widget_get_sensitive(GTK_WIDGET(active->provider));
    request(active, JSTI_LINUX_API_KEY_REFRESH);
    value = delivery_copy(rows, 2, old, "Stale result");
    delivery_apply(value); delivery_free(value);
    valid = valid && active->pending && fixture.calls == 2;
    value = delivery_copy(rows, 2, fixture.request, "Saved");
    delivery_apply(value); delivery_free(value);
    valid = valid && !active->pending && adw_combo_row_get_selected(active->provider) == 1;
    request(active, JSTI_LINUX_API_KEY_VALIDATE);
    valid = valid && fixture.action == JSTI_LINUX_API_KEY_VALIDATE;
    value = delivery_copy(rows, 2, fixture.request, "Checked");
    delivery_apply(value); delivery_free(value);
    Removal removal = { g_strdup(active->identity), g_strdup(active->selection_epoch) };
    gint calls = fixture.calls;
    removal_response(NULL, "cancel", &removal);
    valid = valid && fixture.calls == calls;
    adw_combo_row_set_selected(active->provider, 0);
    removal_response(NULL, "remove", &removal);
    valid = valid && fixture.calls == calls;
    adw_combo_row_set_selected(active->provider, 1);
    g_free(removal.epoch); removal.epoch = g_strdup(active->selection_epoch);
    removal_response(NULL, "remove", &removal);
    valid = valid && fixture.action == JSTI_LINUX_API_KEY_REMOVE;
    g_free(removal.identity); g_free(removal.epoch);
    g_free(old); old = g_strdup(fixture.request);
    jsti_api_keys_close();
    valid = valid && !jsti_api_keys_is_open() && fixture.cancels == 1 &&
        !jsti_api_keys_request_is_current(old);
    jsti_api_keys_open(owner);
    value = delivery_copy(rows, 2, old, "Closed-window result");
    delivery_apply(value); delivery_free(value);
    valid = valid && active->pending;
    value = delivery_copy(rows, 2, fixture.request, "");
    delivery_apply(value); delivery_free(value);
    gtk_editable_set_text(GTK_EDITABLE(active->key), "wipe-on-close");
    GtkWidget *entry = GTK_WIDGET(g_object_ref(active->key));
    jsti_api_keys_close();
    valid = valid && gtk_editable_get_text(GTK_EDITABLE(entry))[0] == '\0';
    g_object_unref(entry);
    rows[1].identifier = rows[0].identifier;
    valid = valid && delivery_copy(rows, 2, old, "") == NULL;
    rows[0].label = "\xff";
    valid = valid && delivery_copy(rows, 1, old, "") == NULL &&
        delivery_copy(NULL, 129, old, "") == NULL && fixture.valid;
    g_free(old);
    g_mutex_lock(&lock); callback = saved_callback; context = saved_context; g_mutex_unlock(&lock);
    jsti_api_keys_set_idle(saved_idle);
    if (!valid) { jsti_set_error(error, capacity, "API Keys request, privacy or lifecycle fence failed."); return -1; }
    return 0;
}
