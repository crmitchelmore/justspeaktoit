#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

static GMutex transition_mutex, registration_mutex;
static GCond callbacks_finished;
static GPrivate callback_depth = G_PRIVATE_INIT(NULL);
static JSTIVoiceProviderCredentialCallback provider_callback;
static void *provider_context;
static guint64 registration_generation;
static gsize admitted_callbacks;
static gboolean registration_closing;

guint64 jsti_voice_provider_generation(void) {
    g_mutex_lock(&registration_mutex);
    guint64 result = provider_callback != NULL && !registration_closing ? registration_generation : 0;
    g_mutex_unlock(&registration_mutex);
    return result;
}
gboolean jsti_voice_provider_enter(guint64 generation) {
    g_mutex_lock(&registration_mutex);
    gboolean admitted = generation != 0 && generation == registration_generation &&
        provider_callback != NULL && !registration_closing;
    if (admitted) {
        ++admitted_callbacks;
        g_private_set(&callback_depth, GSIZE_TO_POINTER(GPOINTER_TO_SIZE(g_private_get(&callback_depth)) + 1));
    }
    g_mutex_unlock(&registration_mutex);
    return admitted;
}
void jsti_voice_provider_leave(void) {
    g_mutex_lock(&registration_mutex);
    --admitted_callbacks;
    g_private_set(&callback_depth, GSIZE_TO_POINTER(GPOINTER_TO_SIZE(g_private_get(&callback_depth)) - 1));
    if (admitted_callbacks == 0) g_cond_broadcast(&callbacks_finished);
    g_mutex_unlock(&registration_mutex);
}
int32_t jsti_window_set_voice_provider_credential_handler(JSTIVoiceProviderCredentialCallback callback, void *context) {
    if ((callback == NULL) != (context == NULL) || g_private_get(&callback_depth) != NULL) return -1;
    g_mutex_lock(&transition_mutex);
    g_mutex_lock(&registration_mutex);
    registration_closing = TRUE; ++registration_generation;
    while (admitted_callbacks != 0) g_cond_wait(&callbacks_finished, &registration_mutex);
    provider_callback = NULL; provider_context = NULL;
    provider_callback = callback; provider_context = context; registration_closing = FALSE;
    g_mutex_unlock(&registration_mutex);
    g_mutex_unlock(&transition_mutex);
    return 0;
}

typedef struct {
    GtkWindow *window;
    AdwPreferencesGroup *group;
    AdwPasswordEntryRow *key;
    AdwActionRow *status;
    GtkWidget *save, *remove, *recheck;
    guint64 generation;
    gchar *session, *epoch, *provider, *view_id, *write_id, *write_slot, *operation, *slot;
    gchar *outcome;
    gboolean loading, saved, can_save, retired;
} ProviderForm;
static ProviderForm *active_provider_form;
static gboolean uuid(const char *value) {
    if (value == NULL || strlen(value) != 36) return FALSE;
    for (gsize index = 0; index < 36; ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (value[index] != '-') return FALSE;
        } else if (!g_ascii_isxdigit(value[index])) return FALSE;
    }
    return TRUE;
}
static gboolean same_uuid(const char *first, const char *second) {
    return uuid(first) && uuid(second) && g_ascii_strcasecmp(first, second) == 0;
}
static void emit(ProviderForm *form, const char *operation, const char *request,
                 const char *slot, const char *secret) {
    if (!jsti_voice_provider_enter(form->generation)) return;
    g_mutex_lock(&registration_mutex);
    JSTIVoiceProviderCredentialCallback callback = provider_callback;
    void *context = provider_context;
    g_mutex_unlock(&registration_mutex);
    if (callback != NULL)
        callback(operation, "voice-output", form->provider, slot, form->session, form->epoch, request, secret, context);
    jsti_voice_provider_leave();
}
static void sensitivity(ProviderForm *form) {
    gboolean live = !form->retired && form->generation == jsti_voice_provider_generation();
    gboolean idle = live && !form->loading && form->write_id == NULL;
    gtk_widget_set_sensitive(GTK_WIDGET(form->key), idle && form->can_save);
    gtk_widget_set_sensitive(form->save, idle && form->can_save && form->slot != NULL);
    gtk_widget_set_sensitive(form->remove, idle && form->can_save && form->saved && form->slot != NULL);
    gtk_widget_set_sensitive(form->recheck, live && !form->loading && form->write_id == NULL);
}
static void request_view(ProviderForm *form) {
    gtk_editable_set_text(GTK_EDITABLE(form->key), "");
    g_clear_pointer(&form->slot, g_free); g_clear_pointer(&form->view_id, g_free);
    form->view_id = g_uuid_string_random();
    form->loading = TRUE; form->can_save = FALSE; form->saved = FALSE;
    adw_action_row_set_subtitle(form->status, "Checking this account Voice key...");
    sensitivity(form);
    emit(form, "open", form->view_id, "", "");
}
static void cancel(ProviderForm *form) {
    if (form->write_id != NULL) emit(form, "cancel", form->write_id, "", "");
    if (form->loading && form->view_id != NULL) emit(form, "cancel", form->view_id, "", "");
    gtk_editable_set_text(GTK_EDITABLE(form->key), "");
    g_clear_pointer(&form->write_id, g_free); g_clear_pointer(&form->view_id, g_free);
    g_clear_pointer(&form->write_slot, g_free); g_clear_pointer(&form->operation, g_free);
    form->loading = FALSE; form->retired = TRUE;
    sensitivity(form);
}
static void destroy(gpointer data) {
    ProviderForm *form = data;
    if (active_provider_form == form) active_provider_form = NULL;
    g_free(form->session); g_free(form->epoch); g_free(form->provider); g_free(form->view_id);
    g_free(form->write_id); g_free(form->write_slot); g_free(form->operation); g_free(form->slot);
    g_free(form->outcome); g_free(form);
}
static void unmap(GtkWidget *widget, gpointer data) {
    (void)widget; ProviderForm *form = data;
    if (active_provider_form == form) active_provider_form = NULL;
    cancel(form);
}
static void submit(ProviderForm *form, gboolean remove) {
    if (form->retired || form->generation != jsti_voice_provider_generation() || form->loading || form->write_id != NULL ||
        !form->can_save || form->slot == NULL || (remove && !form->saved)) return;
    const gchar *value = remove ? "" : gtk_editable_get_text(GTK_EDITABLE(form->key));
    if (!remove && (value[0] == '\0' || strlen(value) > 8192)) {
        adw_action_row_set_subtitle(form->status, "Enter a non-empty key of at most 8,192 UTF-8 bytes.");
        return;
    }
    gchar *secret = g_strdup(value);
    form->write_id = g_uuid_string_random(); form->write_slot = g_strdup(form->slot);
    form->operation = g_strdup(remove ? "remove" : "replace");
    g_clear_pointer(&form->outcome, g_free);
    gtk_editable_set_text(GTK_EDITABLE(form->key), ""); sensitivity(form);
    adw_action_row_set_subtitle(form->status, "Updating this account Voice key...");
    emit(form, form->operation, form->write_id, form->write_slot, secret);
    volatile gchar *wipe = secret;
    for (gsize index = 0, length = strlen(secret); index < length; ++index) wipe[index] = 0;
    g_free(secret);
}
static void save(GtkButton *button, gpointer data) { (void)button; submit(data, FALSE); }
static void recheck(GtkButton *button, gpointer data) {
    (void)button; ProviderForm *form = data;
    if (!form->retired && !form->loading && form->write_id == NULL) {
        g_clear_pointer(&form->outcome, g_free); request_view(form);
    }
}
typedef struct { guint64 generation; gchar *session, *epoch, *provider, *view_id; } Removal;
static void free_removal(gpointer data) {
    Removal *value = data;
    g_free(value->session); g_free(value->epoch); g_free(value->provider); g_free(value->view_id); g_free(value);
}
static void confirm_removal(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)dialog; Removal *value = data;
    if (value->generation != jsti_voice_provider_generation()) return;
    ProviderForm *form = active_provider_form;
    if (g_strcmp0(response, "remove") == 0 && form != NULL && form->generation == value->generation &&
        same_uuid(form->session, value->session) && same_uuid(form->epoch, value->epoch) &&
        same_uuid(form->view_id, value->view_id) && g_strcmp0(form->provider, value->provider) == 0)
        submit(form, TRUE);
}
static void remove_key(GtkButton *button, gpointer data) {
    (void)button; ProviderForm *form = data;
    if (!gtk_widget_get_sensitive(form->remove)) return;
    GtkWidget *dialog = adw_message_dialog_new(form->window, "Remove this account Voice key?",
        "Other features using this same key also lose access. Cancel keeps the existing key.");
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog), "cancel", "Cancel", "remove", "Remove saved key", NULL);
    adw_message_dialog_set_response_appearance(ADW_MESSAGE_DIALOG(dialog), "remove", ADW_RESPONSE_DESTRUCTIVE);
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    Removal *value = g_new0(Removal, 1);
    value->generation = form->generation; value->session = g_strdup(form->session); value->epoch = g_strdup(form->epoch);
    value->provider = g_strdup(form->provider); value->view_id = g_strdup(form->view_id);
    g_object_set_data_full(G_OBJECT(dialog), "provider-key-removal", value, free_removal);
    g_signal_connect(dialog, "response", G_CALLBACK(confirm_removal), value);
    gtk_window_present(GTK_WINDOW(dialog));
}
static void close_form(GtkButton *button, gpointer data) {
    (void)button; gtk_window_destroy(((ProviderForm *)data)->window);
}
typedef struct {
    guint64 generation;
    gchar *request, *session, *epoch, *provider, *slot, *label, *privacy, *status;
    gint saved;
    gboolean can_save, finish;
} ProviderDelivery;
static void free_delivery(gpointer data) {
    ProviderDelivery *value = data;
    g_free(value->request); g_free(value->session); g_free(value->epoch); g_free(value->provider);
    g_free(value->slot); g_free(value->label); g_free(value->privacy); g_free(value->status); g_free(value);
}
static void apply_delivery(gpointer data) {
    ProviderDelivery *value = data;
    if (value->generation == 0 || value->generation != jsti_voice_provider_generation()) return;
    ProviderForm *form = active_provider_form;
    if (form == NULL || form->generation != value->generation ||
        !same_uuid(form->session, value->session) || !same_uuid(form->epoch, value->epoch) ||
        g_strcmp0(form->provider, value->provider) != 0) return;
    if (value->finish) {
        if (!same_uuid(form->write_id, value->request) || form->operation == NULL ||
            form->write_slot == NULL || g_strcmp0(form->write_slot, form->slot) != 0) return;
        g_clear_pointer(&form->write_id, g_free); g_clear_pointer(&form->write_slot, g_free);
        g_clear_pointer(&form->operation, g_free);
        g_free(form->outcome); form->outcome = g_strdup(value->status);
        request_view(form); adw_action_row_set_subtitle(form->status, value->status); return;
    }
    if (!form->loading || !same_uuid(form->view_id, value->request) || form->write_id != NULL) return;
    form->loading = FALSE; form->slot = value->saved >= 0 ? g_strdup(value->slot) : NULL;
    form->can_save = value->can_save && value->saved >= 0; form->saved = value->saved == 1;
    adw_preferences_group_set_title(form->group, value->label);
    adw_preferences_group_set_description(form->group, value->privacy);
    gchar *status = form->outcome == NULL ? g_strdup(value->status)
        : g_strconcat(form->outcome, "\n", value->status, NULL);
    adw_action_row_set_subtitle(form->status, status); g_free(status);
    gtk_editable_set_text(GTK_EDITABLE(form->key), ""); sensitivity(form);
}
static gboolean bounded(const char *value, gsize maximum) {
    return value != NULL && strlen(value) <= maximum && g_utf8_validate(value, -1, NULL);
}
int32_t jsti_window_set_voice_provider_credential(
    const char *request, const char *session, const char *epoch, const char *provider, const char *slot,
    const char *label, const char *privacy, const char *status, int32_t saved, int32_t can_save) {
    if (!uuid(request) || !uuid(session) || !uuid(epoch) || !bounded(provider, 32) || provider[0] == '\0' ||
        !bounded(slot, 128) || saved < -1 || saved > 1 || (can_save != 0 && can_save != 1) ||
        (saved >= 0 && slot[0] == '\0') || (saved == -1 && (can_save || slot[0] != '\0')) ||
        !bounded(label, 512) || !bounded(privacy, 4096) || !bounded(status, 2048)) return -1;
    ProviderDelivery *value = g_new0(ProviderDelivery, 1);
    value->generation = jsti_voice_provider_generation();
    value->request = g_strdup(request); value->session = g_strdup(session); value->epoch = g_strdup(epoch);
    value->provider = g_strdup(provider); value->slot = g_strdup(slot); value->label = g_strdup(label);
    value->privacy = g_strdup(privacy); value->status = g_strdup(status); value->saved = saved; value->can_save = can_save;
    if (value->generation == 0) { free_delivery(value); return 0; }
    return jsti_window_post(apply_delivery, value, free_delivery);
}
int32_t jsti_window_finish_voice_provider_credential(
    const char *request, const char *session, const char *epoch, const char *provider, int32_t success,
    const char *message) {
    if (!uuid(request) || !uuid(session) || !uuid(epoch) || !bounded(provider, 32) || provider[0] == '\0' ||
        (success != 0 && success != 1) || !bounded(message, 2048)) return -1;
    ProviderDelivery *value = g_new0(ProviderDelivery, 1);
    value->generation = jsti_voice_provider_generation();
    value->request = g_strdup(request); value->session = g_strdup(session); value->epoch = g_strdup(epoch);
    value->provider = g_strdup(provider); value->status = g_strdup(message); value->finish = TRUE;
    if (value->generation == 0) { free_delivery(value); return 0; }
    return jsti_window_post(apply_delivery, value, free_delivery);
}
void jsti_show_voice_provider_credentials(GtkWindow *owner, guint64 generation,
    const char *session, const char *epoch, const char *provider) {
    if (generation == 0 || generation != jsti_voice_provider_generation()) return;
    ProviderForm *form = g_new0(ProviderForm, 1);
    form->generation = generation; form->session = g_strdup(session); form->epoch = g_strdup(epoch);
    form->provider = g_strdup(provider);
    form->window = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(form->window, "Account Voice provider key");
    gtk_window_set_transient_for(form->window, owner); gtk_window_set_modal(form->window, TRUE);
    gtk_window_set_destroy_with_parent(form->window, TRUE); gtk_window_set_default_size(form->window, 620, 420);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20); gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 20); gtk_widget_set_margin_bottom(box, 20);
    gtk_window_set_child(form->window, box);
    form->group = ADW_PREFERENCES_GROUP(adw_preferences_group_new());
    adw_preferences_group_set_title(form->group, "Account Voice provider key");
    adw_preferences_group_set_description(form->group, "No key is shown or prefilled. This form sends no source text.");
    form->key = ADW_PASSWORD_ENTRY_ROW(adw_password_entry_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(form->key), "New API key (blank keeps saved key)");
    gtk_editable_set_enable_undo(GTK_EDITABLE(form->key), FALSE);
    adw_preferences_group_add(form->group, GTK_WIDGET(form->key));
    form->status = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(form->status), "Saved key state");
    adw_preferences_group_add(form->group, GTK_WIDGET(form->status));
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(form->group));
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    form->save = gtk_button_new_with_label("Replace key"); form->remove = gtk_button_new_with_label("Remove key");
    form->recheck = gtk_button_new_with_label("Recheck"); GtkWidget *close = gtk_button_new_with_label("Close");
    GtkWidget *controls[] = {form->save, form->remove, form->recheck, close};
    for (gsize index = 0; index < G_N_ELEMENTS(controls); ++index) {
        gtk_widget_set_size_request(controls[index], -1, 44); gtk_box_append(GTK_BOX(buttons), controls[index]);
    }
    gtk_widget_set_halign(buttons, GTK_ALIGN_END); gtk_box_append(GTK_BOX(box), buttons);
    g_signal_connect(form->save, "clicked", G_CALLBACK(save), form);
    g_signal_connect(form->remove, "clicked", G_CALLBACK(remove_key), form);
    g_signal_connect(form->recheck, "clicked", G_CALLBACK(recheck), form);
    g_signal_connect(close, "clicked", G_CALLBACK(close_form), form);
    g_signal_connect(form->window, "unmap", G_CALLBACK(unmap), form);
    g_object_set_data_full(G_OBJECT(form->window), "provider-key-form", form, destroy);
    active_provider_form = form;
    request_view(form); gtk_window_present(form->window);
}
