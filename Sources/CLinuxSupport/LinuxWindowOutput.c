/* General > Output and Keyboard > Shortcut: text output method, clipboard
 * restoration, app-switch delivery, the shortcut hint and activation style.
 * Owns OutputPage (LinuxWindowOutputState.h). */
#include "LinuxWindowOutputState.h"

static OutputPage output_state;
OutputPage *output_page(void) { return &output_state; }

static void on_text_output(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    guint method = adw_combo_row_get_selected(output_page()->output_row);
    gboolean restore = adw_switch_row_get_active(output_page()->restore_row);
    gtk_widget_set_sensitive(GTK_WIDGET(output_page()->restore_row), method == 0 && output_page()->can_restore_clipboard);
    gtk_widget_set_sensitive(GTK_WIDGET(output_page()->app_switch_row), method == 0 && output_page()->app_switch_configured);
    refresh_setup();
    if (output_page()->app_switch_configured) {
        gchar *payload = g_strdup_printf("%s\t%u", restore ? "restore" : "",
                                        adw_combo_row_get_selected(output_page()->app_switch_row));
        emit(JSTI_EVENT_TEXT_OUTPUT, payload, (gint32)method);
        g_free(payload);
    } else {
        emit(JSTI_EVENT_TEXT_OUTPUT, restore ? "restore" : "", (gint32)method);
    }
}

static void on_style(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data;
    emit(JSTI_EVENT_SHORTCUT_STYLE, "", (gint32)adw_combo_row_get_selected(output_page()->style_row));
}

GtkWidget *output_group(void) {
    GtkWidget *output = group("Output");
    output_page()->output_group = ADW_PREFERENCES_GROUP(output);
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(output),
        "Checking paste and clipboard support for this desktop.");
    const char *methods[] = { "Paste into the focused app", "Copy to the clipboard only", NULL };
    output_page()->output_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(output_page()->output_row), "Text output");
    adw_combo_row_set_model(output_page()->output_row, G_LIST_MODEL(gtk_string_list_new(methods)));
    g_signal_connect(output_page()->output_row, "notify::selected", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(output_page()->output_row));
    output_page()->restore_row = ADW_SWITCH_ROW(adw_switch_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(output_page()->restore_row), "Restore the clipboard after pasting");
    adw_switch_row_set_active(output_page()->restore_row, TRUE);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(output_page()->restore_row),
                               "Previous text only, while Just Speak to It still owns the X11 selection.");
    gtk_widget_set_visible(GTK_WIDGET(output_page()->restore_row), FALSE);
    g_signal_connect(output_page()->restore_row, "notify::active", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(output_page()->restore_row));
    output_page()->app_switch_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(output_page()->app_switch_row), "App-switch delivery");
    gtk_widget_set_sensitive(GTK_WIDGET(output_page()->app_switch_row), FALSE);
    g_signal_connect(output_page()->app_switch_row, "notify::selected", G_CALLBACK(on_text_output), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(output_page()->app_switch_row));
    output_page()->app_switch_help = GTK_LABEL(gtk_label_new(NULL));
    gtk_label_set_wrap(output_page()->app_switch_help, TRUE);
    gtk_label_set_xalign(output_page()->app_switch_help, 0);
    gtk_widget_set_margin_top(GTK_WIDGET(output_page()->app_switch_help), 8);
    gtk_widget_set_margin_bottom(GTK_WIDGET(output_page()->app_switch_help), 8);
    gtk_widget_set_margin_start(GTK_WIDGET(output_page()->app_switch_help), 12);
    gtk_widget_set_margin_end(GTK_WIDGET(output_page()->app_switch_help), 12);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(output), GTK_WIDGET(output_page()->app_switch_help));
    return output;
}

GtkWidget *shortcut_group(void) {
    GtkWidget *shortcut = group("Shortcut");
    adw_preferences_group_set_description(
        ADW_PREFERENCES_GROUP(shortcut),
        "Where the desktop offers no shortcut portal, bind the command justspeaktoit --toggle to a key in your "
        "desktop's keyboard settings. With the app already running, --speak-clipboard reads clipboard text aloud "
        "and --paste-last-history delivers the newest History text without raising this window. "
        "The running app also accepts --stop-speech, --pause-resume-speech and --quick-voice-1 "
        "(or --quick-voice-2 / --quick-voice-3).");
    output_page()->shortcut_row = ADW_ACTION_ROW(adw_action_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(output_page()->shortcut_row), "Keyboard shortcut");
    adw_action_row_set_subtitle(output_page()->shortcut_row, "Checking the desktop…");
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(shortcut), GTK_WIDGET(output_page()->shortcut_row));
    const char *styles[] = { "Press to toggle", "Hold to record", "Double-tap to toggle",
                             "Hold, or double-tap to toggle", NULL };
    output_page()->style_row = ADW_COMBO_ROW(adw_combo_row_new());
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(output_page()->style_row), "Activation");
    adw_combo_row_set_model(output_page()->style_row, G_LIST_MODEL(gtk_string_list_new(styles)));
    g_signal_connect(output_page()->style_row, "notify::selected", G_CALLBACK(on_style), NULL);
    adw_preferences_group_add(ADW_PREFERENCES_GROUP(shortcut), GTK_WIDGET(output_page()->style_row));
    return shortcut;
}

static void text_output_free(gpointer pointer) {
    TextOutput *output = pointer;
    g_free(output->hint);
    g_free(output->policy_title);
    g_free(output->policy_labels);
    g_free(output->policy_help);
    g_free(output);
}

void text_output_apply(gpointer pointer) {
    TextOutput *output = pointer;
    ui.suppress = TRUE;
    output_page()->can_restore_clipboard = output->can_restore;
    if (output->policy_labels != NULL) {
        gchar **labels = g_strsplit(output->policy_labels, "\n", -1);
        GtkStringList *model = gtk_string_list_new((const char *const *)labels);
        adw_combo_row_set_model(output_page()->app_switch_row, G_LIST_MODEL(model));
        g_object_unref(model);
        g_strfreev(labels);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(output_page()->app_switch_row), output->policy_title);
        gtk_label_set_text(output_page()->app_switch_help, output->policy_help);
        adw_combo_row_set_selected(output_page()->app_switch_row, output->policy_selection);
        output_page()->app_switch_configured = TRUE;
    }
    adw_combo_row_set_selected(output_page()->output_row, output->method == 1 ? 1 : 0);
    adw_switch_row_set_active(output_page()->restore_row, output->restore);
    gtk_widget_set_visible(GTK_WIDGET(output_page()->restore_row), output->can_restore);
    gtk_widget_set_sensitive(GTK_WIDGET(output_page()->restore_row), output->method != 1 && output->can_restore);
    gtk_widget_set_sensitive(GTK_WIDGET(output_page()->app_switch_row), output->method != 1 && output_page()->app_switch_configured);
    gboolean explicit_policy = output_page()->app_switch_configured && adw_combo_row_get_selected(output_page()->app_switch_row) != 0;
    adw_preferences_group_set_description(output_page()->output_group, explicit_policy ?
        "The saved app-switch policy is enforced. Unsupported or uncertain destinations copy only; "
        "the delivery support explanation below describes this desktop's limits." : output->can_restore ?
        "Finished text goes to the app you were in when dictation started. Recording in this window offers "
        "Copy instead." :
        "Wayland pastes into the app focused at delivery and cannot confirm when it consumes the paste, "
        "so the transcript stays on the clipboard. Your X11 restoration preference is retained. "
        "Recording in this window offers Copy instead.");
    if (output->hint != NULL) adw_action_row_set_subtitle(output_page()->shortcut_row, output->hint);
    ui.suppress = FALSE;
    refresh_setup();
}

int32_t jsti_window_set_text_output(int32_t method, int32_t restore_clipboard,
                                   int32_t can_restore_clipboard, const char *shortcut_hint) {
    TextOutput *output = g_new0(TextOutput, 1);
    output->method = method;
    output->restore = restore_clipboard != 0;
    output->can_restore = can_restore_clipboard != 0;
    output->hint = g_strdup(shortcut_hint);
    return post(text_output_apply, output, text_output_free);
}

int32_t jsti_window_set_text_output_policy(
    int32_t method, int32_t restore_clipboard, int32_t can_restore_clipboard, const char *shortcut_hint,
    const char *policy_title, const char *policy_labels, int32_t policy_selection, const char *policy_help) {
    if (method < 0 || method > 1 || policy_title == NULL || *policy_title == '\0' || policy_labels == NULL ||
        policy_help == NULL || !g_utf8_validate(policy_title, -1, NULL) ||
        !g_utf8_validate(policy_labels, -1, NULL) || !g_utf8_validate(policy_help, -1, NULL)) return -1;
    gchar **labels = g_strsplit(policy_labels, "\n", -1);
    guint count = g_strv_length(labels);
    gboolean valid = count > 0 && policy_selection >= 0 && (guint)policy_selection < count;
    for (guint index = 0; index < count; index++) valid = valid && *labels[index] != '\0';
    g_strfreev(labels);
    if (!valid) return -1;
    TextOutput *output = g_new0(TextOutput, 1);
    output->method = method;
    output->restore = restore_clipboard != 0;
    output->can_restore = can_restore_clipboard != 0;
    output->hint = g_strdup(shortcut_hint);
    output->policy_title = g_strdup(policy_title);
    output->policy_labels = g_strdup(policy_labels);
    output->policy_help = g_strdup(policy_help);
    output->policy_selection = policy_selection;
    return post(text_output_apply, output, text_output_free);
}

static void style_apply(gpointer data) {
    ui.suppress = TRUE;
    adw_combo_row_set_selected(output_page()->style_row, (guint)GPOINTER_TO_INT(data));
    ui.suppress = FALSE;
}

int32_t jsti_window_set_shortcut_style(int32_t index) {
    if (index < 0 || index > 3) return -1;
    return post(style_apply, GINT_TO_POINTER(index), NULL);
}

gchar *output_summary(void) {
    const char *output = combo_row_text(output_page()->output_row);
    gboolean restores = output_page()->can_restore_clipboard && adw_combo_row_get_selected(output_page()->output_row) == 0 &&
                        adw_switch_row_get_active(output_page()->restore_row);
    return g_strdup_printf("%s%s", output != NULL ? output : "", restores ? " · clipboard restored" : "");
}

const char *output_shortcut_hint(void) { return adw_action_row_get_subtitle(output_page()->shortcut_row); }

TextOutput output_current(void) {
    return (TextOutput){
        .method = (gint32)adw_combo_row_get_selected(output_page()->output_row),
        .restore = adw_switch_row_get_active(output_page()->restore_row),
        .can_restore = output_page()->can_restore_clipboard
    };
}
