/* Self-tests for the dictation preferences form. */
#include "LinuxWindowSelfTestInternal.h"

gboolean configuration_reveal_self_test(void) {
    guint count = configuration.rows->len;
    if (jsti_window_reveal_configuration_field(count) != -1 ||
        jsti_window_reveal_configuration_field(JSTI_MAXIMUM_CONFIGURATION_FIELDS) != -1 ||
        jsti_window_reveal_configuration_field((size_t)-1) != -1) return FALSE;
    guint index = count;
    for (guint i = 0; i < count && index == count; ++i)
        if (gtk_widget_get_visible(g_ptr_array_index(configuration.rows, i))) index = i;
    if (index == count) return FALSE;
    GtkWidget *row = g_ptr_array_index(configuration.rows, index);
    configuration_reveal_apply(GSIZE_TO_POINTER(index));
    gboolean highlighted = reveal.target == row && reveal.highlight != 0 &&
        gtk_widget_has_css_class(row, "jsti-search-highlight");
    reveal_cancel();
    return highlighted && reveal.target == NULL && !gtk_widget_has_css_class(row, "jsti-search-highlight");
}

/* The locale/language field is no longer guaranteed to occupy row 0 (visual
 * density can precede it); the self-test discovers the real index and
 * threads it through here via the existing untyped context pointer. */
typedef struct {
    guint calls;
    guint language_index;
    guint empty_choice_index;
} ConfigurationSelfTestContext;

static const char auto_clean_choices[] = "instant\tInstant\nlivePolish\tAuto-Clean";

typedef struct { guint index; guint calls; } AutoCleanConfigurationTest;

static gboolean configuration_test_revision(const char *const *values, size_t *count) {
    if (configuration.revision == NULL) return TRUE;
    if (*count == 0 || g_strcmp0(values[*count - 1], configuration.revision) != 0) return FALSE;
    --*count;
    return TRUE;
}

static int32_t configuration_auto_clean_callback(
    int32_t action, const char *const *values, size_t count, void *context, char *error, size_t capacity
) {
    if (!configuration_test_revision(values, &count)) return -1;
    (void)error; (void)capacity;
    AutoCleanConfigurationTest *test = context;
    const guint index = test->index;
    if (action != 0 || count != configuration.rows->len || index + 4 >= count ||
        g_strcmp0(values[index], "instant") != 0 ||
        g_strcmp0(values[index + 1], "fixture/model") != 0 ||
        g_strcmp0(values[index + 2], "250") != 0 ||
        g_strcmp0(values[index + 3], "3") != 0 ||
        g_strcmp0(values[index + 4], "0") != 0) return -1;
    ++test->calls;
    return 0;
}

static gboolean configuration_auto_clean_self_test(void) {
    guint index = configuration.rows->len;
    for (guint i = 0; i < configuration.rows->len; ++i)
        if (g_strcmp0(g_ptr_array_index(configuration.choices, i), auto_clean_choices) == 0) {
            index = i;
            break;
        }
    if (index + 4 >= configuration.rows->len || configuration.rows->len <= 32) return FALSE;
    AdwComboRow *speed = ADW_COMBO_ROW(g_ptr_array_index(configuration.rows, index));
    GtkWidget *model = g_ptr_array_index(configuration.rows, index + 1);
    GtkWidget *debounce = g_ptr_array_index(configuration.rows, index + 2);
    GtkWidget *delta = g_ptr_array_index(configuration.rows, index + 3);
    GtkWidget *skip = g_ptr_array_index(configuration.rows, index + 4);
    if (!ADW_IS_ENTRY_ROW(model) || !ADW_IS_ENTRY_ROW(debounce) ||
        !ADW_IS_ENTRY_ROW(delta) || !ADW_IS_SWITCH_ROW(skip) ||
        g_list_model_get_n_items(adw_combo_row_get_model(speed)) != 2) return FALSE;
    const guint saved_speed = adw_combo_row_get_selected(speed);
    gchar *saved_model = g_strdup(gtk_editable_get_text(GTK_EDITABLE(model)));
    gchar *saved_debounce = g_strdup(gtk_editable_get_text(GTK_EDITABLE(debounce)));
    gchar *saved_delta = g_strdup(gtk_editable_get_text(GTK_EDITABLE(delta)));
    const gboolean saved_skip = adw_switch_row_get_active(ADW_SWITCH_ROW(skip));
    JSTIConfigurationCallback callback = configuration.callback;
    void *context = configuration.context;
    AutoCleanConfigurationTest test = { .index = index, .calls = 0 };
    configuration.callback = configuration_auto_clean_callback;
    configuration.context = &test;
    adw_combo_row_set_selected(speed, 0);
    gtk_editable_set_text(GTK_EDITABLE(model), "fixture/model");
    gtk_editable_set_text(GTK_EDITABLE(debounce), "250");
    gtk_editable_set_text(GTK_EDITABLE(delta), "3");
    adw_switch_row_set_active(ADW_SWITCH_ROW(skip), FALSE);
    on_configuration_apply(NULL, NULL);
    adw_combo_row_set_selected(speed, saved_speed);
    gtk_editable_set_text(GTK_EDITABLE(model), saved_model);
    gtk_editable_set_text(GTK_EDITABLE(debounce), saved_debounce);
    gtk_editable_set_text(GTK_EDITABLE(delta), saved_delta);
    adw_switch_row_set_active(ADW_SWITCH_ROW(skip), saved_skip);
    g_free(saved_model); g_free(saved_debounce); g_free(saved_delta);
    configuration.callback = callback;
    configuration.context = context;
    return test.calls == 1;
}

static gboolean configuration_empty_choice_self_test(void) {
    const char *choices = "\tLegacy fixture\n retained \tExplicit fixture";
    gboolean valid = configuration_choices_valid(choices, "") &&
        configuration_choices_valid(choices, " retained ") && !configuration_choices_valid(choices, "retained");
    const char *invalid[] = {
        "\tLegacy\n\tDuplicate empty", "\tLegacy\nretained\tFirst\nretained\tDuplicate", "\t",
        "\tLegacy\textra", "Missing separator", "\tLegacy\nretained\t", "\tLegacy\n", "\xff\tInvalid"
    };
    for (guint index = 0; index < G_N_ELEMENTS(invalid); ++index)
        valid = !configuration_choices_valid(invalid[index], "") && valid;
    valid = !configuration_choices_valid(choices, "not-listed") && valid;
    GString *bounded = g_string_new("\tLegacy fixture");
    for (guint index = 1; index < 32; ++index) g_string_append_printf(bounded, "\nvalue%u\tChoice", index);
    valid = configuration_choices_valid(bounded->str, "") && valid;
    g_string_append(bounded, "\nextra\tThirty-third choice");
    valid = !configuration_choices_valid(bounded->str, "") && valid;
    g_string_set_size(bounded, 65536);
    memset(bounded->str, 'x', bounded->len);
    valid = !configuration_choices_valid(bounded->str, "") && valid;
    g_string_free(bounded, TRUE);
    return valid;
}

static int32_t configuration_test_callback(int32_t action, const char *const *values, size_t count,
                                          void *context, char *error, size_t capacity) {
    if (!configuration_test_revision(values, &count)) return -1;
    (void)error; (void)capacity;
    ConfigurationSelfTestContext *test_context = context;
    if (test_context->language_index >= count) return -1;
    if (g_strcmp0(values[test_context->language_index], "fr_FR") != 0) return -1;
    if ((action == 0 || action == 4 || action == 5) && count != configuration.rows->len) return -1;
    if (action == 3 && (count != configuration.rows->len + 1 ||
        g_strcmp0(values[count - 1], "Second recoverable edit") != 0)) return -1;
    if (action != 0 && action != 3 && action != 4 && action != 5) return -1;
    for (guint i = 0; i < configuration.rows->len; ++i)
        if (((const char *)g_ptr_array_index(configuration.choices, i))[0] != '\0') {
            const char *choices = g_ptr_array_index(configuration.choices, i);
            gchar **lines = g_strsplit(choices, "\n", -1);
            const guint selected_index = test_context->empty_choice_index == i ? 0 : 1;
            const char *line = g_strv_length(lines) > selected_index ? lines[selected_index] : NULL;
            const char *tab = line != NULL ? strchr(line, '\t') : NULL;
            const gboolean selected = tab != NULL && strlen(values[i]) == (size_t)(tab - line) &&
                strncmp(values[i], line, tab - line) == 0;
            g_strfreev(lines);
            if (!selected) {
                g_printerr("Configuration self-test: field %u did not emit choice %u.\n", i, selected_index);
                return -1;
            }
        }
    ++test_context->calls;
    return 0;
}

typedef struct { guint intent; guint approval; guint calls; gboolean approved; } WarmApprovalConfigurationTest;

static int32_t configuration_warm_approval_callback(
    int32_t action, const char *const *values, size_t count, void *context, char *error, size_t capacity
) {
    if (!configuration_test_revision(values, &count)) return -1;
    (void)error; (void)capacity;
    WarmApprovalConfigurationTest *test = context;
    if (action != 0 || count != configuration.rows->len || test->intent >= count || test->approval >= count ||
        g_strcmp0(values[test->intent], "1") != 0 ||
        g_strcmp0(values[test->approval], test->approved ? "1" : "0") != 0) return -1;
    ++test->calls;
    return 0;
}

static gboolean configuration_warm_approval_self_test(void) {
    WarmApprovalConfigurationTest test = {
        .intent = configuration.rows->len, .approval = configuration.rows->len, .calls = 0, .approved = FALSE
    };
    for (guint index = 0; index < configuration.rows->len; ++index) {
        const char *title = adw_preferences_row_get_title(
            ADW_PREFERENCES_ROW(g_ptr_array_index(configuration.rows, index)));
        if (g_strcmp0(title, "Prepare completed-only OpenRouter cleanup (not live/streaming)") == 0)
            test.intent = index;
        if (g_strcmp0(title, "Approve probes this session, only after successful capture") == 0)
            test.approval = index;
    }
    if (test.intent >= configuration.rows->len || test.approval >= configuration.rows->len) return FALSE;
    GtkWidget *intent = g_ptr_array_index(configuration.rows, test.intent);
    GtkWidget *approval = g_ptr_array_index(configuration.rows, test.approval);
    if (!ADW_IS_SWITCH_ROW(intent) || !ADW_IS_SWITCH_ROW(approval) ||
        g_array_index(configuration.enabled_by_fields, gint32, test.approval) != (gint32)test.intent + 1)
        return FALSE;
    const gboolean saved_intent = adw_switch_row_get_active(ADW_SWITCH_ROW(intent));
    const gboolean saved_approval = adw_switch_row_get_active(ADW_SWITCH_ROW(approval));
    JSTIConfigurationCallback saved_callback = configuration.callback;
    void *saved_context = configuration.context;
    configuration.callback = configuration_warm_approval_callback;
    configuration.context = &test;
    adw_switch_row_set_active(ADW_SWITCH_ROW(approval), FALSE);
    adw_switch_row_set_active(ADW_SWITCH_ROW(intent), FALSE);
    gboolean valid = !gtk_widget_get_sensitive(approval) &&
        !adw_switch_row_get_active(ADW_SWITCH_ROW(approval));
    adw_switch_row_set_active(ADW_SWITCH_ROW(intent), TRUE);
    valid = valid && gtk_widget_get_sensitive(approval) &&
        !adw_switch_row_get_active(ADW_SWITCH_ROW(approval));
    on_configuration_apply(NULL, NULL);
    valid = valid && test.calls == 1;
    adw_switch_row_set_active(ADW_SWITCH_ROW(approval), TRUE);
    test.approved = TRUE;
    on_configuration_apply(NULL, NULL);
    valid = valid && test.calls == 2;
    adw_switch_row_set_active(ADW_SWITCH_ROW(approval), saved_approval);
    adw_switch_row_set_active(ADW_SWITCH_ROW(intent), saved_intent);
    configuration.callback = saved_callback;
    configuration.context = saved_context;
    return valid;
}

gboolean configuration_self_test(void) {
    if (!configuration_empty_choice_self_test()) return FALSE;
    if (configuration.rows == NULL || configuration.rows->len < 10 ||
        configuration.rows->len != configuration.booleans->len ||
        configuration.rows->len != configuration.overlay_settings->len ||
        configuration.rows->len != configuration.hands_free_settings->len) return FALSE;
    GtkWidget *corrections = gtk_stack_get_child_by_name(ui.pages, "corrections");
    if (ui.configuration_columns[4] == NULL || corrections == NULL ||
        !gtk_widget_is_ancestor(ui.configuration_columns[4], corrections)) return FALSE;
    gboolean found_learning_switch = FALSE, found_learning_threshold = FALSE;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        GtkWidget *row = g_ptr_array_index(configuration.rows, i);
        if (!gtk_widget_is_ancestor(row, ui.configuration_columns[4])) continue;
        if (gtk_widget_is_ancestor(row, ui.configuration_columns[0])) return FALSE;
        found_learning_switch |= ADW_IS_SWITCH_ROW(row);
        found_learning_threshold |= ADW_IS_ENTRY_ROW(row);
    }
    if (!found_learning_switch || !found_learning_threshold) return FALSE;
    gboolean found_dependency = FALSE;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        gint32 enabling = g_array_index(configuration.enabled_by_fields, gint32, i);
        if (enabling == -1 && gtk_widget_get_sensitive(g_ptr_array_index(configuration.rows, i)))
            return FALSE;
        if (enabling <= 0) continue;
        found_dependency = TRUE;
        AdwSwitchRow *control = ADW_SWITCH_ROW(g_ptr_array_index(configuration.rows, enabling - 1));
        GtkWidget *dependent = g_ptr_array_index(configuration.rows, i);
        gboolean saved = adw_switch_row_get_active(control);
        const gboolean is_switch = ADW_IS_SWITCH_ROW(dependent), is_choice = ADW_IS_COMBO_ROW(dependent);
        if (!is_switch && !is_choice && !GTK_IS_EDITABLE(dependent)) return FALSE;
        const gboolean saved_switch = is_switch && adw_switch_row_get_active(ADW_SWITCH_ROW(dependent));
        const guint saved_choice = is_choice ? adw_combo_row_get_selected(ADW_COMBO_ROW(dependent)) : 0;
        gchar *text = !is_switch && !is_choice ? g_strdup(gtk_editable_get_text(GTK_EDITABLE(dependent))) : NULL;
        adw_switch_row_set_active(control, FALSE);
        gboolean disabled = !gtk_widget_get_sensitive(dependent);
        adw_switch_row_set_active(control, TRUE);
        gboolean enabled = gtk_widget_get_sensitive(dependent);
        gboolean retained = is_switch ? saved_switch == adw_switch_row_get_active(ADW_SWITCH_ROW(dependent)) :
            is_choice ? saved_choice == adw_combo_row_get_selected(ADW_COMBO_ROW(dependent)) :
            g_strcmp0(text, gtk_editable_get_text(GTK_EDITABLE(dependent))) == 0;
        adw_switch_row_set_active(control, saved);
        g_free(text);
        if (!disabled || !enabled || !retained) {
            g_printerr("Configuration self-test: dependency for field %u lost availability or its value.\n", i);
            return FALSE;
        }
    }
    if (!found_dependency) return FALSE;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (g_array_index(configuration.overlay_settings, gboolean, i) &&
            gtk_widget_get_visible(g_ptr_array_index(configuration.rows, i)) != jsti_hud_overlay_supported())
            return FALSE;
        if (g_array_index(configuration.hands_free_settings, gboolean, i)) {
            GtkWidget *row = g_ptr_array_index(configuration.rows, i);
            gboolean enabled = adw_switch_row_get_active(ADW_SWITCH_ROW(row));
            if (gtk_widget_get_sensitive(row) != (jsti_window_hands_free_guard_ready() != 0 || enabled))
                return FALSE;
            configuration_hands_free_availability(row, TRUE);
            if (!gtk_widget_get_sensitive(row)) return FALSE;
            configuration_hands_free_availability(row, FALSE);
            if (gtk_widget_get_sensitive(row) != (jsti_window_hands_free_guard_ready() != 0)) return FALSE;
            configuration_hands_free_availability(row, enabled);
        }
    }
    JSTIConfigurationCallback callback = configuration.callback;
    void *context = configuration.context;
    /* Row ordering mirrors DesktopConfiguration.fields, which can insert
     * non-editable rows (e.g. visual density) ahead of the locale entry row;
     * find the real AdwEntryRow rather than assuming it is always row 0. */
    guint language_index = configuration.rows->len;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (ADW_IS_ENTRY_ROW(g_ptr_array_index(configuration.rows, i))) { language_index = i; break; }
    }
    if (language_index >= configuration.rows->len) return FALSE;
    AdwEntryRow *language = ADW_ENTRY_ROW(g_ptr_array_index(configuration.rows, language_index));
    gchar *saved = g_strdup(gtk_editable_get_text(GTK_EDITABLE(language)));
    ConfigurationSelfTestContext test_context = {
        .calls = 0, .language_index = language_index, .empty_choice_index = G_MAXUINT
    };
    AdwComboRow *choice_row = NULL;
    guint optional_choice_count = 0;
    GArray *original_choices = g_array_new(FALSE, FALSE, sizeof(guint));
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (((const char *)g_ptr_array_index(configuration.choices, i))[0] == '\0') continue;
        choice_row = ADW_COMBO_ROW(g_ptr_array_index(configuration.rows, i));
        const char *choices = g_ptr_array_index(configuration.choices, i);
        if (choices[0] == '\t') ++optional_choice_count;
        guint count = g_list_model_get_n_items(adw_combo_row_get_model(choice_row));
        gchar **lines = g_strsplit(choices, "\n", -1);
        const guint expected_count = g_strv_length(lines);
        g_strfreev(lines);
        if (count < 2 || count != expected_count) {
            g_printerr("Configuration self-test: field %u has %u choices; expected %u.\n", i, count, expected_count);
            g_array_unref(original_choices); return FALSE;
        }
        guint original_choice = adw_combo_row_get_selected(choice_row);
        g_array_append_val(original_choices, original_choice);
        adw_combo_row_set_selected(choice_row, 1);
    }
    if (choice_row == NULL) { g_array_unref(original_choices); return FALSE; }
    configuration.callback = configuration_test_callback;
    configuration.context = &test_context;
    gtk_editable_set_text(GTK_EDITABLE(language), "fr_FR");
    gchar *saved_title = g_strdup(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(language)));
    gchar gemini_title[] = "Gemini voice language";
    ConfigurationTitleUpdate title_update = { .index = language_index, .title = gemini_title };
    configuration_title_apply(&title_update);
    const gboolean title_preserved =
        g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(language)), gemini_title) == 0 &&
        g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(language)), "fr_FR") == 0 &&
        jsti_window_set_configuration_field_title(JSTI_MAXIMUM_CONFIGURATION_FIELDS, "Invalid") < 0 &&
        jsti_window_set_configuration_field_title(language_index, NULL) < 0 &&
        jsti_window_set_configuration_field_title(language_index, "") < 0 &&
        jsti_window_set_configuration_field_enabled(JSTI_MAXIMUM_CONFIGURATION_FIELDS, 1) < 0 &&
        jsti_window_set_configuration_field_enabled(language_index, 2) < 0;
    ConfigurationAvailabilityUpdate availability = { .index = language_index, .enabled = FALSE };
    configuration_availability_apply(&availability);
    gboolean availability_preserved = !gtk_widget_get_sensitive(GTK_WIDGET(language)) &&
        g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(language)), "fr_FR") == 0;
    availability.enabled = TRUE; configuration_availability_apply(&availability);
    availability_preserved = availability_preserved && gtk_widget_get_sensitive(GTK_WIDGET(language)) &&
        g_strcmp0(gtk_editable_get_text(GTK_EDITABLE(language)), "fr_FR") == 0;
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(language), saved_title);
    g_free(saved_title);
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (((const char *)g_ptr_array_index(configuration.choices, i))[0] != '\t') continue;
        AdwComboRow *optional_choice_row = ADW_COMBO_ROW(g_ptr_array_index(configuration.rows, i));
        test_context.empty_choice_index = i;
        adw_combo_row_set_selected(optional_choice_row, 0);
        on_configuration_apply(NULL, NULL);
        adw_combo_row_set_selected(optional_choice_row, 1);
        test_context.empty_choice_index = G_MAXUINT;
    }
    on_configuration_apply(NULL, NULL);
    on_configuration_apply(NULL, GINT_TO_POINTER(4));
    on_configuration_apply(NULL, GINT_TO_POINTER(5));
    GListModel *saved_model = adw_combo_row_get_model(configuration.recovery_row);
    g_object_ref(saved_model);
    guint saved_count = configuration.recovery_count;
    guint saved_selection = adw_combo_row_get_selected(configuration.recovery_row);
    const char *edits[] = {"First recoverable edit", "Second recoverable edit", NULL};
    GtkStringList *recovered = gtk_string_list_new(edits);
    adw_combo_row_set_model(configuration.recovery_row, G_LIST_MODEL(recovered));
    g_object_unref(recovered);
    configuration.recovery_count = 2;
    adw_combo_row_set_selected(configuration.recovery_row, 1);
    on_configuration_apply(NULL, GINT_TO_POINTER(3));
    adw_combo_row_set_model(configuration.recovery_row, saved_model);
    adw_combo_row_set_selected(configuration.recovery_row, saved_selection);
    configuration.recovery_count = saved_count;
    guint choice_index = 0;
    for (guint i = 0; i < configuration.rows->len; ++i) {
        if (((const char *)g_ptr_array_index(configuration.choices, i))[0] == '\0') continue;
        adw_combo_row_set_selected(ADW_COMBO_ROW(g_ptr_array_index(configuration.rows, i)),
            g_array_index(original_choices, guint, choice_index++));
    }
    g_array_unref(original_choices);
    g_object_unref(saved_model);
    gtk_editable_set_text(GTK_EDITABLE(language), saved);
    g_free(saved);
    configuration.callback = callback;
    configuration.context = context;
    if (test_context.calls != optional_choice_count + 4 || !title_preserved || !availability_preserved) {
        g_printerr("Configuration self-test: calls %u/%u, title %d, availability %d.\n",
            test_context.calls, optional_choice_count + 4, title_preserved, availability_preserved);
        return FALSE;
    }
    if (!configuration_auto_clean_self_test()) {
        g_printerr("Configuration self-test: Auto-Clean Apply did not preserve all fields.\n");
        return FALSE;
    }
    if (!configuration_warm_approval_self_test()) {
        g_printerr("Configuration self-test: session warm-up approval did not preserve intent and consent.\n");
        return FALSE;
    }
    return TRUE;
}
