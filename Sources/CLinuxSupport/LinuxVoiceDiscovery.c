#include "LinuxSupportInternal.h"
#include <gtk/gtk.h>

typedef struct {
    GtkWindow *window;
    GtkDropDown *voices;
    GtkLabel *status;
    GtkButton *refresh, *choose;
    gchar *token;
    gchar **identifiers;
    gboolean loading;
    JSTIVoiceSourceCallback callback;
    void *context;
} Discovery;
static Discovery *active;
static void destroy_discovery(gpointer data) {
    Discovery *dialog = data;
    if (active == dialog) active = NULL;
    dialog->callback(118, -1, "", dialog->token, "account-close", dialog->context);
    g_free(dialog->token); g_strfreev(dialog->identifiers); g_free(dialog);
}
static void sensitivity(Discovery *dialog) {
    guint index = gtk_drop_down_get_selected(dialog->voices);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->refresh), !dialog->loading);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->voices), !dialog->loading);
    gtk_widget_set_sensitive(GTK_WIDGET(dialog->choose), !dialog->loading && dialog->identifiers != NULL &&
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
    dialog->callback(118, -1, "", dialog->token, "account-refresh", dialog->context);
}
static void choose(GtkButton *button, gpointer data) {
    (void)button;
    Discovery *dialog = data;
    guint index = gtk_drop_down_get_selected(dialog->voices);
    if (!dialog->loading && dialog->identifiers != NULL && index < g_strv_length(dialog->identifiers))
        dialog->callback(118, -1, dialog->identifiers[index], dialog->token, "account-choose", dialog->context);
}
static void close_discovery(GtkButton *button, gpointer data) {
    (void)button; gtk_window_destroy(((Discovery *)data)->window);
}
typedef struct {
    gchar *token, **labels, **identifiers, *status;
    gint selected;
    gboolean loading;
} Inventory;
static void apply_inventory(gpointer data) {
    Inventory *inventory = data;
    if (active == NULL || g_strcmp0(active->token, inventory->token) != 0) return;
    Discovery *dialog = active;
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
        labels == NULL || labels[0] == '\0' || strlen(labels) > 262144 || !g_utf8_validate(labels, -1, NULL) ||
        identifiers == NULL || strlen(identifiers) > 262144 || !g_utf8_validate(identifiers, -1, NULL) ||
        status == NULL || strlen(status) > 4096 || !g_utf8_validate(status, -1, NULL) ||
        (loading != 0 && loading != 1)) return -1;
    Inventory *inventory = g_new0(Inventory, 1);
    inventory->token = g_strdup(token); inventory->labels = g_strsplit(labels, "\n", -1);
    inventory->identifiers = g_strsplit(identifiers, "\n", -1); inventory->status = g_strdup(status);
    inventory->selected = selected; inventory->loading = loading;
    guint count = g_strv_length(inventory->labels);
    gboolean valid = count > 0 && count <= 514 && count == g_strv_length(inventory->identifiers) &&
        selected >= -1 && selected < (gint)count;
    for (guint index = 0; valid && index < count; ++index)
        valid = inventory->labels[index][0] != '\0' && strlen(inventory->labels[index]) <= 512 &&
            strchr(inventory->labels[index], '\r') == NULL && strlen(inventory->identifiers[index]) <= 260 &&
            g_str_has_prefix(inventory->identifiers[index], "xai/") &&
            strchr(inventory->identifiers[index], '\r') == NULL;
    if (!valid) { free_inventory(inventory); return -1; }
    return jsti_window_post(apply_inventory, inventory, free_inventory);
}
static Discovery *make_discovery(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context) {
    Discovery *dialog = g_new0(Discovery, 1);
    dialog->token = g_uuid_string_random(); dialog->callback = callback; dialog->context = context;
    dialog->window = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(dialog->window, "xAI account voices");
    gtk_window_set_transient_for(dialog->window, owner); gtk_window_set_modal(dialog->window, TRUE);
    gtk_window_set_destroy_with_parent(dialog->window, TRUE); gtk_window_set_default_size(dialog->window, 620, 380);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(dialog->window, box);
    GtkWidget *heading = gtk_label_new("xAI voices: documented presets and explicitly refreshed account listing");
    gtk_label_set_xalign(GTK_LABEL(heading), 0); gtk_label_set_wrap(GTK_LABEL(heading), TRUE);
    gtk_box_append(GTK_BOX(box), heading);
    dialog->voices = GTK_DROP_DOWN(gtk_drop_down_new(NULL, NULL));
    gtk_drop_down_set_enable_search(dialog->voices, TRUE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(dialog->voices), GTK_ACCESSIBLE_PROPERTY_LABEL, "xAI voice", -1);
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
    g_signal_connect(dialog->refresh, "clicked", G_CALLBACK(refresh), dialog);
    g_signal_connect(dialog->choose, "clicked", G_CALLBACK(choose), dialog);
    g_signal_connect(close, "clicked", G_CALLBACK(close_discovery), dialog);
    active = dialog;
    return dialog;
}
void jsti_show_voice_discovery(GtkWindow *owner, JSTIVoiceSourceCallback callback, void *context) {
    if (callback == NULL) return;
    Discovery *dialog = make_discovery(owner, callback, context);
    callback(118, -1, "", dialog->token, "account-open", context);
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
        "Documented presets are labelled separately. Choose voice saves the stable identifier.", 1, FALSE
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
    Inventory stale = {"obsolete", NULL, NULL, NULL, 0, FALSE};
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
    int32_t result = jsti_window_save_widget_png(GTK_WIDGET(active->window), path, TRUE);
    gtk_window_destroy(active->window);
    return result;
}
