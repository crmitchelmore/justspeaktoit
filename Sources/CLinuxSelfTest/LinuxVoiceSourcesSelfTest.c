/* jsti_voice_sources_self_test: the Voice sources dialog, markup helper and
 * audio formats, plus the controls, usage and discovery checks. */
#include "../CLinuxSupport/LinuxVoiceSourcesInternal.h"

typedef struct {
    gint calls, source, generated, flags;
    gchar *text, *record, *generate_flags, *played_result;
} Received;
static void receive_fixture(int32_t action, int32_t source, const char *value,
                             const char *record, const char *path, void *context) {
    Received *received = context;
    if (action == 115) { ++received->generated; g_free(received->generate_flags); received->generate_flags = g_strdup(path); }
    if (action == 116) { g_free(received->played_result); received->played_result = g_strdup(record); }
    if (action == 118) received->flags = source;
    if (action != 110) return;
    ++received->calls; received->source = source;
    g_free(received->text); g_free(received->record);
    received->text = g_strdup(value); received->record = g_strdup(record);
}
int32_t jsti_voice_controls_self_test(GtkWindow *owner, char *error, size_t capacity);
int32_t jsti_voice_usage_self_test(GtkWindow *owner, char *error, size_t capacity);
int32_t jsti_voice_discovery_self_test(GtkWindow *owner, char *error, size_t capacity);
static int32_t markup_fixture_wrap(const char *input, char *output, size_t capacity,
                                   int32_t *utf16, int32_t *scalars) {
    if (strcmp(input, "Reject") == 0) return -1;
    gboolean wrapped = strstr(input, "<fixture>") != NULL;
    gchar *result = wrapped ? g_strdup(input) : g_strconcat("<fixture>", input, "</fixture>", NULL);
    if (strlen(result) + 1 > capacity) { g_free(result); return -1; }
    memcpy(output, result, strlen(result) + 1); *utf16 = *scalars = wrapped ? 0 : 9;
    g_free(result); return 0;
}
static gboolean markup_fixture_copy(GtkWidget *widget, const char *value, gpointer data) {
    (void)widget;
    gchar **captured = data; g_free(*captured); *captured = g_strdup(value); return TRUE;
}
/* Turns the installed markup configuration on or off, as the host would. */
static void set_markup_enabled(gboolean enabled) {
    MarkupConfiguration current = {0};
    swap_markup_configuration(&current); current.enabled = enabled; swap_markup_configuration(&current);
}
/* Installs synthetic format rows, as jsti_window_set_voice_audio_formats would. */
static void use_formats(const char *labels, const char *identifiers, guint selected) {
    FormatState value = {
        .labels = g_strsplit(labels, "\n", -1), .identifiers = g_strsplit(identifiers, "\n", -1),
        .selected = selected };
    swap_format_state(&value); clear_formats(&value);
}
static gboolean markup_self_test(Dialog *dialog) {
    MarkupConfiguration original = {0};
    swap_markup_configuration(&original);
    gboolean passed = !markup_configured();
    gchar *original_text = text(dialog);
    guint original_source = dialog->selected;
    const gchar *fixture_texts[] = {"Synthetic & <tag>", "Synthetic \xC9\x99 & <other>", NULL};
    const gchar *fixture_descriptions[] = {"First synthetic example", "Second synthetic example", NULL};
    MarkupConfiguration fixture = {TRUE, g_strdupv((gchar **)fixture_texts),
        g_strdupv((gchar **)fixture_descriptions), markup_fixture_wrap};
    swap_markup_configuration(&fixture);
    passed = markup_configured() && passed;
    dialog->selected = 3; refresh(dialog);
    GtkTextBuffer *buffer = gtk_text_view_get_buffer(dialog->editor);
    const gchar *draft = "\xCE\xA9 \xF0\x9F\x98\x80 & <";
    gtk_text_buffer_set_text(buffer, draft, -1);
    GtkTextIter insert, bound;
    gtk_text_buffer_get_iter_at_offset(buffer, &insert, 3);
    gtk_text_buffer_get_iter_at_offset(buffer, &bound, 2);
    gtk_text_buffer_select_range(buffer, &insert, &bound);
    MarkupHelper *helper = make_markup_helper(dialog);
    passed = helper != NULL && passed;
    gchar *copied = NULL;
    if (helper != NULL) {
        helper->copy = markup_fixture_copy; helper->copy_context = &copied;
        gtk_drop_down_set_selected(helper->examples, 1);
        g_signal_emit_by_name(helper->copy_button, "clicked");
        gchar *unchanged = text(dialog);
        passed = g_strcmp0(copied, fixture_texts[1]) == 0 && strcmp(unchanged, draft) == 0 &&
            gtk_widget_get_focusable(dialog->markup_apply) &&
            gtk_button_get_use_underline(GTK_BUTTON(dialog->markup_apply)) &&
            gtk_window_get_default_widget(helper->window) == dialog->markup_apply && passed;
        g_free(unchanged);
        passed = markup_key(NULL, GDK_KEY_Escape, 0, 0, helper) && passed;
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer));
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer));
        passed = gtk_text_iter_get_offset(&insert) == 3 && gtk_text_iter_get_offset(&bound) == 2 && passed;
    }
    helper = make_markup_helper(dialog);
    if (helper != NULL) {
        gchar *current = g_strconcat(draft, " newer", NULL);
        gtk_text_buffer_set_text(buffer, current, -1);
        gtk_text_buffer_get_iter_at_offset(buffer, &insert, 3);
        gtk_text_buffer_get_iter_at_offset(buffer, &bound, 2);
        gtk_text_buffer_select_range(buffer, &insert, &bound);
        g_signal_emit_by_name(dialog->markup_apply, "clicked");
        gchar *actual = text(dialog);
        gchar *expected = g_strconcat("<fixture>", current, "</fixture>", NULL);
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer));
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer));
        passed = strcmp(actual, expected) == 0 && gtk_text_iter_get_offset(&insert) == 12 &&
            gtk_text_iter_get_offset(&bound) == 11 && passed;
        gtk_text_buffer_undo(buffer);
        gchar *undone = text(dialog);
        passed = strcmp(undone, current) == 0 && passed;
        g_free(actual); g_free(expected); g_free(undone); g_free(current);
    } else passed = FALSE;
    gtk_text_buffer_set_text(buffer, "<fixture>Already wrapped</fixture>", -1);
    gtk_text_buffer_get_iter_at_offset(buffer, &insert, 16);
    gtk_text_buffer_get_iter_at_offset(buffer, &bound, 9);
    gtk_text_buffer_select_range(buffer, &insert, &bound);
    helper = make_markup_helper(dialog);
    if (helper != NULL) {
        passed = apply_markup(helper) && passed;
        gtk_text_buffer_get_iter_at_mark(buffer, &insert, gtk_text_buffer_get_insert(buffer));
        gtk_text_buffer_get_iter_at_mark(buffer, &bound, gtk_text_buffer_get_selection_bound(buffer));
        passed = gtk_text_iter_get_offset(&insert) == 16 && gtk_text_iter_get_offset(&bound) == 9 && passed;
        gtk_text_buffer_set_text(buffer, "Reject", -1);
        passed = !apply_markup(helper) && passed;
        gchar *unchanged = text(dialog); passed = strcmp(unchanged, "Reject") == 0 && passed; g_free(unchanged);
        set_markup_enabled(FALSE); refresh(dialog);
        passed = !gtk_widget_get_sensitive(dialog->helper) &&
            !gtk_widget_get_sensitive(dialog->markup_apply) && !apply_markup(helper) && passed;
        close_markup(NULL, helper);
    } else passed = FALSE;
    set_markup_enabled(TRUE);
    for (guint source = 0; source <= 2; source += 2) {
        dialog->selected = source; refresh(dialog);
        passed = !gtk_widget_get_sensitive(dialog->helper) && !can_edit_markup(dialog) && passed;
    }
    dialog->selected = 3; dialog->import_token = g_strdup("synthetic-helper-import"); refresh(dialog);
    passed = !gtk_widget_get_sensitive(dialog->helper) && passed;
    g_clear_pointer(&dialog->import_token, g_free);
    passed = jsti_window_set_voice_markup_helper(2, NULL, 0, NULL) == -1 && passed;
    swap_markup_configuration(&original); clear_markup(&original);
    dialog->selected = original_source; gtk_text_buffer_set_text(buffer, original_text, -1); refresh(dialog);
    g_free(original_text); g_free(copied);
    return passed;
}
static gboolean format_self_test(Dialog *dialog) {
    const JSTIVoiceSourceCallback callback = dialog->callback;
    void *context = dialog->context;
    Received received = {0};
    dialog->callback = receive_fixture; dialog->context = &received;
    gboolean passed = format_available(0) && format_available(7);
    use_formats("MP3\nAAC (M4A)\nWAV", "mp3\nm4a\nwav", 2);
    show_formats(dialog);
    generate_audio(NULL, dialog);
    passed = g_list_model_get_n_items(gtk_drop_down_get_model(dialog->format)) == 3 &&
        format_available(2) && !format_available(3) &&
        g_strcmp0(received.generate_flags, "2|wav") == 0 && passed;
    gtk_drop_down_set_selected(dialog->format, 0);
    passed = dialog->format_pending && !gtk_widget_get_sensitive(GTK_WIDGET(dialog->generate)) && passed;
    use_formats("MP3\nAAC (M4A)\nWAV", "mp3\nm4a\nwav", 0); show_formats(dialog);
    generate_audio(NULL, dialog);
    passed = g_strcmp0(received.generate_flags, "2|mp3") == 0 && passed;
    g_free(dialog->result_format); dialog->result_format = g_strdup("m4a");
    passed = strcmp(selected_format(dialog), "mp3") == 0 &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_result)) && passed;
    /* Match the production parser's explicit non-executable stored-format row. */
    use_formats("MP3\nAAC (M4A)\nWAV\nUnavailable stored format", "mp3\nm4a\nwav\n", 3); show_formats(dialog);
    passed = !format_available(3) && passed;
    passed = strcmp(selected_format(dialog), "") == 0 &&
        !gtk_widget_get_sensitive(GTK_WIDGET(dialog->generate)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_button)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->read)) &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_result)) && passed;
    gtk_drop_down_set_selected(dialog->format, 0);
    passed = dialog->format_pending && !gtk_widget_get_sensitive(GTK_WIDGET(dialog->generate)) && passed;
    use_formats("MP3\nAAC (M4A)\nWAV\nUnavailable stored format", "mp3\nm4a\nwav\n", 0); show_formats(dialog);
    generate_audio(NULL, dialog);
    passed = g_strcmp0(received.generate_flags, "2|mp3") == 0 &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->generate)) && passed;
    dialog->callback = callback; dialog->context = context;
    g_free(received.generate_flags); g_free(received.played_result);
    FormatState fixture = {0}; swap_format_state(&fixture); clear_formats(&fixture);
    return passed;
}
int32_t jsti_voice_sources_self_test(GtkWindow *owner, char *error, size_t capacity) {
    FormatState original_formats = {0}; swap_format_state(&original_formats);
    Dialog *dialog = make_dialog(owner, "synthetic-record", "Synthetic History snapshot");
    if (dialog == NULL) {
        swap_format_state(&original_formats);
        jsti_set_error(error, capacity, "Voice sources fixture could not open."); return -1;
    }
    Received received = {0};
    dialog->callback = receive_fixture; dialog->context = &received;
    gchar *snapshot = text(dialog);
    gboolean history = g_strcmp0(snapshot, "Synthetic History snapshot") == 0 &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->read));
    g_free(snapshot);
    voice_read_aloud(NULL, dialog);
    gboolean history_snapshot = received.calls == 1 && received.source == 0 &&
        g_strcmp0(received.record, "synthetic-record") == 0 &&
        g_strcmp0(received.text, "Synthetic History snapshot") == 0;
    gtk_drop_down_set_selected(dialog->source, 1);
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), "Synthetic typed text", -1);
    gboolean typed = gtk_text_view_get_editable(dialog->editor) &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_button));
    voice_read_aloud(NULL, dialog);
    gboolean typed_snapshot = received.calls == 2 && received.source == 1 &&
        received.record[0] == '\0' && g_strcmp0(received.text, "Synthetic typed text") == 0;
    gtk_drop_down_set_selected(dialog->source, 2);
    gboolean unavailable = !gtk_widget_get_sensitive(GTK_WIDGET(dialog->read)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_button)) &&
        g_list_model_get_n_items(gtk_drop_down_get_model(dialog->source)) == 4;
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), "Synthetic clipboard snapshot", -1);
    voice_read_aloud(NULL, dialog);
    gboolean clipboard_snapshot = received.calls == 3 && received.source == 2 &&
        received.record[0] == '\0' && g_strcmp0(received.text, "Synthetic clipboard snapshot") == 0;
    gtk_drop_down_set_selected(dialog->source, 3);
    dialog->import_token = g_strdup("synthetic-import");
    gboolean imported = apply_import_result(dialog, "synthetic-import", "Synthetic file text", "");
    voice_read_aloud(NULL, dialog);
    gboolean file_snapshot = imported && received.calls == 4 && received.source == 4 &&
        received.record[0] == '\0' && g_strcmp0(received.text, "Synthetic file text") == 0 &&
        gtk_text_view_get_editable(dialog->editor);
    gboolean stale_import = !apply_import_result(dialog, "synthetic-import", "Stale text", "");
    dialog->import_token = g_strdup("synthetic-failure");
    apply_import_result(dialog, "synthetic-failure", "", "Synthetic read error.");
    gchar *unchanged = text(dialog);
    gboolean failed_import = g_strcmp0(unchanged, "Synthetic file text") == 0 &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->read));
    g_free(unchanged);
    dialog->import_token = g_strdup("synthetic-edit");
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(dialog->editor), "Synthetic user edit", -1);
    gboolean edited_import = !apply_import_result(dialog, "synthetic-edit", "Late text", "");
    gtk_check_button_set_active(dialog->auto_play, FALSE);
    gtk_check_button_set_active(dialog->save, TRUE);
    preferences_changed(NULL, dialog);
    generate_audio(NULL, dialog);
    gboolean generated_snapshot = received.generated == 1 && received.flags == 2 &&
        g_strcmp0(received.generate_flags, "2") == 0;
    dialog->working = TRUE; refresh(dialog);
    gboolean busy_result = !gtk_widget_get_sensitive(GTK_WIDGET(dialog->generate)) &&
        !gtk_widget_get_sensitive(GTK_WIDGET(dialog->play_result));
    dialog->working = FALSE;
    g_free(dialog->result_id); dialog->result_id = g_strdup("synthetic-result"); refresh(dialog);
    play_result(NULL, dialog);
    gboolean retained_result = g_strcmp0(received.played_result, "synthetic-result") == 0 &&
        gtk_widget_get_sensitive(GTK_WIDGET(dialog->export_result));
    gboolean markup = markup_self_test(dialog) &&
        received.calls == 4 && received.generated == 1 && received.flags == 2;
    gboolean formats = format_self_test(dialog);
    gtk_window_destroy(dialog->window);
    swap_format_state(&original_formats);
    g_free(received.text); g_free(received.record);
    g_free(received.generate_flags); g_free(received.played_result);
    gboolean passed = history && typed && unavailable && history_snapshot && typed_snapshot &&
        clipboard_snapshot && file_snapshot && stale_import && failed_import && edited_import &&
        generated_snapshot && busy_result && retained_result && markup && formats;
    if (!passed) {
        const gboolean checks[] = {history, typed, unavailable, history_snapshot, typed_snapshot,
            clipboard_snapshot, file_snapshot, stale_import, failed_import, edited_import,
            generated_snapshot, busy_result, retained_result, markup, formats};
        const char *names[] = {"history", "typed", "unavailable", "history snapshot", "typed snapshot",
            "clipboard snapshot", "file snapshot", "stale import", "failed import", "edited import",
            "generated snapshot", "busy result", "retained result", "markup", "formats"};
        GString *detail = g_string_new("Voice sources state/snapshot checks failed:");
        for (guint index = 0; index < G_N_ELEMENTS(checks); ++index)
            if (!checks[index]) g_string_append_printf(detail, " %s;", names[index]);
        jsti_set_error(error, capacity, "%s", detail->str);
        g_string_free(detail, TRUE);
    }
    return passed && jsti_voice_controls_self_test(owner, error, capacity) == 0 &&
        jsti_voice_usage_self_test(owner, error, capacity) == 0
        ? jsti_voice_discovery_self_test(owner, error, capacity) : -1;
}
