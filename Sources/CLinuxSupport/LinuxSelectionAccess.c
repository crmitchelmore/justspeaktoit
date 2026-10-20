#include "LinuxSupportInternal.h"
#include "include/LinuxAtspi.h"
#include <adwaita.h>

typedef struct {
    GWeakRef row;
    guint64 token;
    gboolean responded;
} SelectionOffer;

static void offer_free(gpointer data, GClosure *closure) {
    (void)closure;
    SelectionOffer *offer = data;
    if (!offer->responded) jsti_atspi_selection_consent(0, offer->token);
    g_weak_ref_clear(&offer->row); g_free(offer);
}

static void selection_response(AdwMessageDialog *dialog, const char *response, gpointer data) {
    (void)dialog;
    SelectionOffer *offer = data;
    offer->responded = TRUE;
    AdwActionRow *row = g_weak_ref_get(&offer->row);
    gboolean allowed = row != NULL && g_strcmp0(response, "allow") == 0;
    gboolean applied = jsti_atspi_selection_consent(allowed ? 1 : 0, offer->token) == 1;
    if (row != NULL) {
        adw_action_row_set_subtitle(row, allowed && applied
            ? "Session access allowed. Refocus an external editable field, select text, then use your desktop shortcut."
            : "Selection access is off. Nothing was read.");
        g_object_unref(row);
    }
}

static void selection_allow(GtkButton *button, gpointer data) {
    (void)button;
    GtkWidget *row = data;
    GtkRoot *root = gtk_widget_get_root(row);
    if (!GTK_IS_WINDOW(root)) return;
    guint64 token = jsti_atspi_selection_offer();
    if (token == 0) {
        adw_action_row_set_subtitle(ADW_ACTION_ROW(row),
            "Local consent is unavailable. Restart the app to try again.");
        return;
    }
    GtkWidget *dialog = adw_message_dialog_new(GTK_WINDOW(root),
        "Allow selected-text speech for this session?",
        "Only an explicit selected-text speech command reads one selection, up to 8,192 characters, from a supported "
        "ordinary editable AT-SPI field. That text is sent to your saved Voice Output provider, which may be remote. "
        "Passwords and ambiguous fields are excluded. There is no clipboard or PRIMARY-selection fallback, "
        "automatic text sampling, editing or correction learning. Accessibility must already be enabled. "
        "Access is not saved or imported. Stop access revokes pending reads.");
    adw_message_dialog_add_responses(ADW_MESSAGE_DIALOG(dialog),
        "cancel", "Keep off", "allow", "Allow for this session", NULL);
    adw_message_dialog_set_default_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    adw_message_dialog_set_close_response(ADW_MESSAGE_DIALOG(dialog), "cancel");
    gtk_window_set_destroy_with_parent(GTK_WINDOW(dialog), TRUE);
    SelectionOffer *offer = g_new0(SelectionOffer, 1);
    g_weak_ref_init(&offer->row, row); offer->token = token;
    g_signal_connect_data(dialog, "response", G_CALLBACK(selection_response), offer, offer_free, 0);
    gtk_window_present(GTK_WINDOW(dialog));
}

static void selection_stop(GtkButton *button, gpointer data) {
    (void)button;
    jsti_atspi_selection_consent(0, 0);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(data), "Selection access is off. Pending reads were revoked.");
    jsti_window_emit(JSTI_EVENT_PLAYBACK_STOP, "", 0);
}

static void selection_controls_destroyed(gpointer data, GObject *object) {
    (void)data; (void)object;
    jsti_atspi_selection_consent(0, 0);
}

GtkWidget *jsti_selection_access_group_new(void) {
    GtkWidget *group = adw_preferences_group_new();
    adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(group), "Selected-text speech");
    adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(group),
        "Allow access here, then refocus the external field and use a desktop keyboard binding for "
        "'justspeaktoit --speak-selected-text' while the app is running. "
        "Only ordinary editable AT-SPI controls are supported; read-only documents are not.");
    GtkWidget *row = adw_action_row_new();
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(row), "Selection access");
    adw_action_row_set_subtitle(ADW_ACTION_ROW(row), "Off for this session. No external text is sampled.");
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *allow = gtk_button_new_with_label("Allow...");
    GtkWidget *stop = gtk_button_new_with_label("Stop access");
    gtk_widget_set_valign(actions, GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(allow, "Review selected-text access for this session");
    gtk_widget_set_tooltip_text(stop, "Revoke selected-text access and stop speech");
    g_signal_connect_object(allow, "clicked", G_CALLBACK(selection_allow), row, 0);
    g_signal_connect_object(stop, "clicked", G_CALLBACK(selection_stop), row, 0);
    gtk_box_append(GTK_BOX(actions), allow); gtk_box_append(GTK_BOX(actions), stop);
    adw_action_row_add_suffix(ADW_ACTION_ROW(row), actions);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(group), row);
    g_object_weak_ref(G_OBJECT(group), selection_controls_destroyed, NULL);
    return group;
}
