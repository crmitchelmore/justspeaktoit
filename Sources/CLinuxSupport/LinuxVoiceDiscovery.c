#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>

typedef struct {
    GtkWindow *window;
    GtkDropDown *voices;
    GtkLabel *status;
    GtkButton *refresh, *choose;
    GtkDropDown *providers;
    GtkButton *key;
    gchar *token;
    gchar **identifiers;
    gboolean loading;
    JSTIVoiceSourceCallback callback;
    void *context;
    guint64 generation;
    gboolean modern, proposed, acknowledged, inventory_matched, applying;
    gchar *epoch, *provider, **provider_ids;
} Discovery;
static Discovery *active;
static gboolean active_is_modern;
static gboolean same_uuid(const char *first, const char *second) {
    return first != NULL && second != NULL && strlen(first) == 36 && strlen(second) == 36 &&
        g_uuid_string_is_valid(first) && g_uuid_string_is_valid(second) &&
        g_ascii_strcasecmp(first, second) == 0;
}
static void emit(Discovery *dialog, const char *path, const char *text, gboolean session) {
    if (dialog->modern && !jsti_voice_provider_enter(dialog->generation)) return;
    dialog->callback(118, -1, text,
        dialog->modern && !session ? dialog->epoch : dialog->token, path, dialog->context);
    if (dialog->modern) jsti_voice_provider_leave();
}
static void destroy_discovery(gpointer data) {
    Discovery *dialog = data;
    if (active == dialog) { active = NULL; active_is_modern = FALSE; }
    emit(dialog, "account-close", "", TRUE);
    g_free(dialog->token); g_free(dialog->epoch); g_free(dialog->provider);
    g_strfreev(dialog->provider_ids); g_strfreev(dialog->identifiers); g_free(dialog);
}
static void sensitivity(Discovery *dialog) {
    guint index = gtk_drop_down_get_selected(dialog->voices);
    gboolean ready = !dialog->loading && (!dialog->modern || (dialog->acknowledged && dialog->inventory_matched &&
        dialog->generation == jsti_voice_provider_generation()));
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->providers), dialog->modern && ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->key), dialog->modern && ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->refresh), ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->voices), ready);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->choose), ready && dialog->identifiers != NULL &&
        index < g_strv_length(dialog->identifiers));
}
static void selection_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; sensitivity(data);
}
static void refresh(GtkButton *button, gpointer data) {
    (void)button;
    Discovery *dialog = data;
    if (dialog->loading) return;
    dialog->loading = TRUE; sensitivity(dialog);
    gtk_label_set_text(dialog->status, "Listing account voices. Close cancels.");
    emit(dialog, "account-refresh", "", FALSE);
}
static void choose(GtkButton *button, gpointer data) {
    (void)button;
    Discovery *dialog = data;
    guint index = gtk_drop_down_get_selected(dialog->voices);
    if (!dialog->loading && dialog->identifiers != NULL && index < g_strv_length(dialog->identifiers))
        emit(dialog, "account-choose", dialog->identifiers[index], FALSE);
}
static void close_discovery(GtkButton *button, gpointer data) {
    (void)button; gtk_window_destroy(((Discovery *)data)->window);
}
typedef struct {
    gchar *token, **labels, **identifiers, *status;
    gint selected;
    gboolean loading;
    guint64 generation;
} Inventory;
static void apply_inventory(gpointer data) {
    Inventory *inventory = data;
    if (active_is_modern && inventory->generation == 0) return;
    if (inventory->generation != 0 && inventory->generation != jsti_voice_provider_generation()) return;
    if (active == NULL || (active->modern ? !same_uuid(active->epoch, inventory->token) :
        g_strcmp0(active->token, inventory->token) != 0)) return;
    Discovery *dialog = active;
    if (dialog->modern && (inventory->generation != dialog->generation ||
        dialog->generation != jsti_voice_provider_generation())) return;
    gchar *prefix = dialog->modern ? g_strconcat(dialog->provider, "/", NULL) : g_strdup("xai/");
    for (guint index = 0; index < g_strv_length(inventory->identifiers); ++index) {
        if (!g_str_has_prefix(inventory->identifiers[index], prefix)) { g_free(prefix); return; }
    }
    g_free(prefix);
    if (dialog->modern) dialog->inventory_matched = TRUE;
    dialog->loading = TRUE;
    g_strfreev(dialog->identifiers); dialog->identifiers = g_strdupv(inventory->identifiers);
    GtkStringList *model = gtk_string_list_new((const char *const *)inventory->labels);
    gtk_drop_down_set_model(dialog->voices, G_LIST_MODEL(model)); g_object_unref(model);
    gtk_drop_down_set_selected(dialog->voices,
        inventory->selected < 0 ? GTK_INVALID_LIST_POSITION : (guint)inventory->selected);
    gtk_label_set_text(dialog->status, inventory->status);
    dialog->loading = inventory->loading; sensitivity(dialog);
}
static void free_inventory(gpointer data) {
    Inventory *inventory = data;
    g_free(inventory->token); g_free(inventory->status);
    g_strfreev(inventory->labels); g_strfreev(inventory->identifiers); g_free(inventory);
}
int32_t jsti_window_set_voice_account_inventory(const char *token, const char *labels, const char *identifiers,
                                               int32_t selected, const char *status, int32_t loading) {
    if (token == NULL || token[0] == '\0' || strlen(token) > 64 ||
        labels == NULL || strlen(labels) > 262144 || !g_utf8_validate(labels, -1, NULL) ||
        identifiers == NULL || strlen(identifiers) > 262144 || !g_utf8_validate(identifiers, -1, NULL) ||
        status == NULL || strlen(status) > 4096 || !g_utf8_validate(status, -1, NULL) ||
        (loading != 0 && loading != 1)) return -1;
    Inventory *inventory = g_new0(Inventory, 1);
    inventory->token = g_strdup(token);
    inventory->labels = labels[0] != '\0' ? g_strsplit(labels, "\n", -1) : g_new0(gchar *, 1);
    inventory->identifiers = identifiers[0] != '\0' ? g_strsplit(identifiers, "\n", -1) : g_new0(gchar *, 1);
    inventory->status = g_strdup(status); inventory->generation = jsti_voice_provider_generation();
    inventory->selected = selected; inventory->loading = loading;
    guint count = g_strv_length(inventory->labels);
    gboolean valid = count <= 514 && count == g_strv_length(inventory->identifiers) &&
        selected >= -1 && (count == 0 ? selected == -1 : selected < (gint)count);
    for (guint index = 0; valid && index < count; ++index)
        valid = inventory->labels[index][0] != '\0' && strlen(inventory->labels[index]) <= 512 &&
            strchr(inventory->labels[index], '\r') == NULL && strlen(inventory->identifiers[index]) <= 260 &&
            strchr(inventory->identifiers[index], '/') != NULL &&
            strchr(inventory->identifiers[index], '\r') == NULL;
    if (!valid) { free_inventory(inventory); return -1; }
    return jsti_window_post(apply_inventory, inventory, free_inventory);
}
static void propose(Discovery *dialog, guint selected) {
    if (dialog->provider_ids == NULL || selected >= g_strv_length(dialog->provider_ids)) return;
    gchar *epoch = g_uuid_string_random();
    if (same_uuid(epoch, dialog->epoch)) {
        g_free(epoch); gtk_label_set_text(dialog->status, "A provider transition could not be created. Close and retry.");
        return;
    }
    g_free(dialog->epoch); dialog->epoch = epoch;
    g_free(dialog->provider); dialog->provider = g_strdup(dialog->provider_ids[selected]);
    dialog->proposed = TRUE; dialog->acknowledged = FALSE; dialog->inventory_matched = FALSE; dialog->loading = TRUE;
    g_clear_pointer(&dialog->identifiers, g_strfreev);
    GtkStringList *empty = gtk_string_list_new(NULL);
    gtk_drop_down_set_model(dialog->voices, G_LIST_MODEL(empty)); g_object_unref(empty);
    gtk_label_set_text(dialog->status, "Waiting for the selected account provider. No key lookup is started.");
    sensitivity(dialog);
    gchar *payload = g_strconcat(dialog->provider, "\n", dialog->epoch, NULL);
    emit(dialog, "account-provider", payload, TRUE); g_free(payload);
}
static void provider_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; Discovery *dialog = data;
    if (!dialog->applying && gtk_widget_get_sensitive(GTK_WIDGET(dialog->providers)))
        propose(dialog, gtk_drop_down_get_selected(dialog->providers));
}
static void provider_key(GtkButton *button, gpointer data) {
    (void)button; Discovery *dialog = data;
    if (gtk_widget_get_sensitive(GTK_WIDGET(dialog->key)))
        jsti_show_voice_provider_credentials(dialog->window, dialog->generation, dialog->token,
            dialog->epoch, dialog->provider);
}
typedef struct { guint64 generation; gchar *session, *epoch, **ids, **labels; guint selected; } Providers;
static void free_providers(gpointer data) {
    Providers *value = data;
    g_free(value->session); g_free(value->epoch); g_strfreev(value->ids); g_strfreev(value->labels); g_free(value);
}
static void apply_providers(gpointer data) {
    Providers *value = data;
    if (value->generation == 0 || value->generation != jsti_voice_provider_generation()) return;
    Discovery *dialog = active;
    if (dialog == NULL || !dialog->modern || dialog->generation != value->generation ||
        !same_uuid(dialog->token, value->session)) return;
    if (!dialog->proposed) {
        g_strfreev(dialog->provider_ids); dialog->provider_ids = g_strdupv(value->ids);
        dialog->applying = TRUE;
        GtkStringList *model = gtk_string_list_new((const char *const *)value->labels);
        gtk_drop_down_set_model(dialog->providers, G_LIST_MODEL(model)); g_object_unref(model);
        gtk_drop_down_set_selected(dialog->providers, value->selected); dialog->applying = FALSE;
        dialog->epoch = g_strdup(value->epoch);
        propose(dialog, value->selected);
    } else if (same_uuid(dialog->epoch, value->epoch) &&
        g_strcmp0(dialog->provider, value->ids[value->selected]) == 0) {
        gboolean same_ids = g_strv_length(dialog->provider_ids) == g_strv_length(value->ids);
        for (guint index = 0; same_ids && index < g_strv_length(value->ids); ++index)
            same_ids = g_strcmp0(dialog->provider_ids[index], value->ids[index]) == 0;
        if (same_ids) dialog->acknowledged = TRUE;
        sensitivity(dialog);
    }
}
int32_t jsti_window_set_voice_account_providers(const char *session, const char *epoch,
    const char *ids, const char *labels, int32_t selected) {
    if (session == NULL || strlen(session) != 36 || !g_uuid_string_is_valid(session) ||
        epoch == NULL || strlen(epoch) != 36 || !g_uuid_string_is_valid(epoch) ||
        ids == NULL || ids[0] == '\0' || strlen(ids) > 262144 ||
        labels == NULL || strlen(labels) > 262144 || !g_utf8_validate(labels, -1, NULL)) return -1;
    Providers *value = g_new0(Providers, 1);
    value->generation = jsti_voice_provider_generation();
    value->session = g_strdup(session); value->epoch = g_strdup(epoch);
    value->ids = g_strsplit(ids, "\n", -1); value->labels = g_strsplit(labels, "\n", -1); value->selected = selected;
    guint count = g_strv_length(value->ids);
    gboolean valid = count > 0 && count <= 514 && count == g_strv_length(value->labels) &&
        selected >= 0 && (guint)selected < count;
    for (guint index = 0; valid && index < count; ++index) {
        const gchar *id = value->ids[index];
        valid = id[0] != '\0' && strlen(id) <= 32 && value->labels[index][0] != '\0' &&
            strlen(value->labels[index]) <= 512 && strchr(value->labels[index], '\r') == NULL;
        for (gsize offset = 0; valid && id[offset] != '\0'; ++offset)
            valid = g_ascii_islower(id[offset]) || g_ascii_isdigit(id[offset]) || id[offset] == '-';
        for (guint previous = 0; valid && previous < index; ++previous)
            valid = g_strcmp0(id, value->ids[previous]) != 0;
    }
    if (!valid) { free_providers(value); return -1; }
    if (value->generation == 0) { free_providers(value); return 0; }
    return jsti_window_post(apply_providers, value, free_providers);
}
static Discovery *make_discovery(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context) {
    Discovery *dialog = g_new0(Discovery, 1);
    dialog->token = g_uuid_string_random(); dialog->callback = callback; dialog->context = context;
    dialog->window = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(dialog->window, "Account Voice providers");
    gtk_window_set_transient_for(dialog->window, owner); gtk_window_set_modal(dialog->window, TRUE);
    gtk_window_set_destroy_with_parent(dialog->window, TRUE); gtk_window_set_default_size(dialog->window, 620, 380);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(dialog->window, box);
    GtkWidget *heading = gtk_label_new("Account Voice provider: presets and explicitly refreshed account voices");
    gtk_label_set_xalign(GTK_LABEL(heading), 0); gtk_label_set_wrap(GTK_LABEL(heading), TRUE);
    gtk_box_append(GTK_BOX(box), heading);
    GtkWidget *provider_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    dialog->providers = GTK_DROP_DOWN(gtk_drop_down_new(NULL, NULL));
    gtk_widget_set_hexpand(GTK_WIDGET(dialog->providers), TRUE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(dialog->providers), GTK_ACCESSIBLE_PROPERTY_LABEL,
        "Account Voice provider", -1);
    gtk_widget_set_size_request(GTK_WIDGET(dialog->providers), 240, 44);
    dialog->key = GTK_BUTTON(gtk_button_new_with_label("Provider key..."));
    gtk_widget_set_size_request(GTK_WIDGET(dialog->key), 140, 44);
    gtk_box_append(GTK_BOX(provider_row), GTK_WIDGET(dialog->providers));
    gtk_box_append(GTK_BOX(provider_row), GTK_WIDGET(dialog->key));
    gtk_box_append(GTK_BOX(box), provider_row);
    dialog->voices = GTK_DROP_DOWN(gtk_drop_down_new(NULL, NULL));
    gtk_drop_down_set_enable_search(dialog->voices, TRUE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(dialog->voices), GTK_ACCESSIBLE_PROPERTY_LABEL, "Account Voice voice", -1);
    gtk_widget_set_size_request(GTK_WIDGET(dialog->voices), 340, 44);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(dialog->voices));
    dialog->status = GTK_LABEL(gtk_label_new("Preparing choices. No source text is sent."));
    gtk_label_set_wrap(dialog->status, TRUE); gtk_label_set_xalign(dialog->status, 0);
    gtk_widget_set_vexpand(GTK_WIDGET(dialog->status), TRUE);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(dialog->status));
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_box_append(GTK_BOX(box), buttons);
    dialog->refresh = GTK_BUTTON(gtk_button_new_with_label("Refresh"));
    dialog->choose = GTK_BUTTON(gtk_button_new_with_label("Choose voice"));
    GtkWidget *close = gtk_button_new_with_label("Close");
    for (guint index = 0; index < 3; ++index) {
        GtkWidget *button = index == 0 ? GTK_WIDGET(dialog->refresh) : index == 1 ? GTK_WIDGET(dialog->choose) : close;
        gtk_widget_set_size_request(button, 120, 44); gtk_box_append(GTK_BOX(buttons), button);
    }
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->choose), FALSE);
    g_object_set_data_full(G_OBJECT(dialog->window), "voice-discovery", dialog, destroy_discovery);
    g_signal_connect(dialog->voices, "notify::selected", G_CALLBACK(selection_changed), dialog);
    g_signal_connect(dialog->providers, "notify::selected", G_CALLBACK(provider_changed), dialog);
    g_signal_connect(dialog->key, "clicked", G_CALLBACK(provider_key), dialog);
    g_signal_connect(dialog->refresh, "clicked", G_CALLBACK(refresh), dialog);
    g_signal_connect(dialog->choose, "clicked", G_CALLBACK(choose), dialog);
    g_signal_connect(close, "clicked", G_CALLBACK(close_discovery), dialog);
    active = dialog;
    active_is_modern = FALSE;
    sensitivity(dialog);
    return dialog;
}
void jsti_show_voice_discovery(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context) {
    guint64 generation = jsti_voice_provider_generation();
    if (callback == NULL || generation == 0) {
        jsti_window_update("The account Voice callbacks are not configured.", NULL, -1); return;
    }
    Discovery *dialog = make_discovery(owner, callback, context);
    dialog->modern = TRUE; active_is_modern = TRUE;
    dialog->generation = generation; dialog->loading = TRUE; sensitivity(dialog);
    emit(dialog, "account-open-modern", "", TRUE);
    gtk_window_present(dialog->window);
}
typedef struct { gchar *choice; guint refreshed, closed; } Calls;
static void fixture_callback(int32_t action, int32_t flag, const char *text, const char *token,
                             const char *path, void *context) {
    (void)token;
    if (context == NULL || action != 118 || flag != -1) return;
    Calls *calls = context;
    if (g_strcmp0(path, "account-choose") == 0) {
        g_free(calls->choice); calls->choice = g_strdup(text);
    }
    if (g_strcmp0(path, "account-refresh") == 0) ++calls->refreshed;
    if (g_strcmp0(path, "account-close") == 0) ++calls->closed;
}
static void fixture_inventory(Discovery *dialog) {
    Inventory inventory = {
        dialog->token,
        g_strsplit("Eve - xAI Speech (documented preset)\nSynthetic account voice (account listing)", "\n", -1),
        g_strsplit("xai/eve\nxai/Account-A", "\n", -1),
        "Synthetic fixture: no provider calls. Listing received: 1 additional account voice. "
        "Documented presets are labelled separately. Choose voice saves the stable identifier.", 1, FALSE, 0
    };
    apply_inventory(&inventory);
    g_strfreev(inventory.labels); g_strfreev(inventory.identifiers);
}
int32_t jsti_voice_discovery_self_test(GtkWindow *owner, char *error, size_t capacity) {
    Calls calls = {0};
    Discovery *dialog = make_discovery(owner, fixture_callback, &calls);
    gboolean passed = !gtk_widget_get_sensitive(GTK_WIDGET(dialog->choose)) &&
        jsti_window_set_voice_account_inventory(dialog->token, "one", "xai/a\nxai/b", 0, "", 0) == -1;
    fixture_inventory(dialog);
    choose(dialog->choose, dialog);
    passed = passed && g_strcmp0(calls.choice, "xai/Account-A") == 0;
    refresh(dialog->refresh, dialog);
    passed = passed && calls.refreshed == 1 && !gtk_widget_get_sensitive(GTK_WIDGET(dialog->choose));
    Inventory stale = {"obsolete", NULL, NULL, NULL, 0, FALSE, 0};
    apply_inventory(&stale);
    passed = passed && !gtk_widget_get_sensitive(GTK_WIDGET(dialog->choose));
    fixture_inventory(dialog);
    passed = passed && gtk_widget_get_sensitive(GTK_WIDGET(dialog->choose));
    gtk_window_destroy(dialog->window);
    passed = passed && calls.closed == 1;
    apply_inventory(&stale);
    g_free(calls.choice);
    if (!passed) jsti_set_error(error, capacity, "Account voice fixture failed stable selection, loading or stale ownership.");
    return passed ? 0 : -1;
}
void jsti_voice_discovery_show_fixture(GtkWindow *owner) {
    Discovery *dialog = make_discovery(owner, fixture_callback, NULL);
    fixture_inventory(dialog); gtk_window_present(dialog->window);
}
int32_t jsti_voice_discovery_save_snapshot(const char *path) {
    if (active == NULL) return -1;
    int32_t result = jsti_widget_save_snapshot(GTK_WIDGET(active->window), path, TRUE);
    gtk_window_destroy(active->window);
    return result;
}
