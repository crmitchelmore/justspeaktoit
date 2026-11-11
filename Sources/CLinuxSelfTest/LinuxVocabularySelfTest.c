/* The Corrections and Pronunciation editors' checks (jsti_vocabulary_self_test). */
#include "../CLinuxSupport/LinuxVocabularyInternal.h"
#include <string.h>

static guint filter_visible_count(Editor *e) {
    guint count = 0;
    for (guint i = 0; i < e->rows->len; ++i)
        if (gtk_widget_get_child_visible(GTK_WIDGET(gtk_list_box_get_row_at_index(e->list, (gint)i)))) ++count;
    return count;
}
static void filter_fixture(const char *header, const char *rows) {
    Presentation p = {1, g_strconcat(header, rows, NULL), TRUE};
    vocabulary_present(&p); g_free(p.payload);
}
static void filter_query(Editor *e, const char *query) {
    gtk_editable_set_text(GTK_EDITABLE(e->search), query);
    g_signal_emit_by_name(e->search, "search-changed");
}
static gboolean filter_expect(gboolean condition, const char *message, char *error, size_t capacity) {
    if (!condition) jsti_set_error(error, capacity, "%s", message);
    return condition;
}
static gboolean filter_action_sensitive(Editor *e, const char *action) {
    for (guint i = 0; i < e->buttons->len; ++i) {
        GtkWidget *button = g_ptr_array_index(e->buttons, i);
        if (g_strcmp0(g_object_get_data(G_OBJECT(button), "vocabulary-action"), action) == 0)
            return gtk_widget_get_sensitive(button);
    }
    return FALSE;
}
static gboolean pronunciation_filter_checks(Editor *e, char *error, size_t capacity) {
    const char *legacy = "\ttrue\ttrue\t";
    const char *modern = "\ttrue\ttrue\t\tpronunciationCategories.v1\t4\tTechnical\t1\tNames\t1";
    const char *rows =
        "\nfixture-a\tAlpha\tFirst\tReplacementOnly\tTechnical\tfalse\tfalse\t"
        "\nfixture-b\tBeta\tSecond\tOther\tNames\tfalse\tfalse\t"
        "\nfixture-u\tGamma\tThird\tOther\tImported\tfalse\tfalse\t"
        "\nfixture-n\tDelta\tFourth\t\t\tfalse\tfalse\t";
    filter_fixture(modern, rows);
    GtkStringList *model = GTK_STRING_LIST(gtk_drop_down_get_model(GTK_DROP_DOWN(e->category_filter)));
    if (!filter_expect(filter_visible_count(e) == 4 && e->categories->len == 3
        && g_strcmp0(gtk_string_list_get_string(model, 0), "All (4)") == 0
        && g_strcmp0(gtk_string_list_get_string(model, 1), "Technical (1)") == 0,
        "Pronunciation category counts failed.", error, capacity)) return FALSE;
    filter_query(e, "rEpLaCeMeNtOnLy");
    if (!filter_expect(filter_visible_count(e) == 1
        && gtk_widget_get_child_visible(GTK_WIDGET(gtk_list_box_get_row_at_index(e->list, 0))),
        "Replacement-only pronunciation search failed.", error, capacity)) return FALSE;
    filter_query(e, "Technical");
    if (!filter_expect(filter_visible_count(e) == 0,
        "Pronunciation search incorrectly searched category labels.", error, capacity)) return FALSE;
    filter_query(e, "");
    if (!filter_expect(filter_visible_count(e) == 4,
        "Clearing pronunciation search lost unknown or uncategorized entries.", error, capacity)) return FALSE;
    gtk_list_box_select_row(e->list, gtk_list_box_get_row_at_index(e->list, 1));
    gtk_drop_down_set_selected(GTK_DROP_DOWN(e->category_filter), 1);
    vocabulary_send_action(e, "save");
    gchar *word = vocabulary_text(e->fields[1]);
    const gboolean hidden = e->selected == 1 && vocabulary_hidden_selection(e) && !e->busy
        && filter_visible_count(e) == 1 && g_strcmp0(word, "Beta") == 0
        && !filter_action_sensitive(e, "save") && !filter_action_sensitive(e, "delete")
        && !filter_action_sensitive(e, "up") && !filter_action_sensitive(e, "down");
    g_free(word);
    if (!filter_expect(hidden, "A hidden pronunciation selection changed identity or remained writable.",
        error, capacity)) return FALSE;
    filter_query(e, "Second");
    if (!filter_expect(filter_visible_count(e) == 0
        && g_strcmp0(gtk_string_list_get_string(model, 0), "All (4)") == 0,
        "Pronunciation search and category filtering were not conjunctive.", error, capacity)) return FALSE;
    filter_query(e, "");
    gtk_drop_down_set_selected(GTK_DROP_DOWN(e->category_filter), 2);
    if (!filter_expect(filter_visible_count(e) == 1 && !vocabulary_hidden_selection(e) && e->selected == 1
        && filter_action_sensitive(e, "save"),
        "Clearing filters did not restore the selected pronunciation entry.", error, capacity)) return FALSE;
    filter_fixture(modern,
        "\nfixture-b\tBeta\tSecond\tOther\tNames\tfalse\tfalse\t"
        "\nfixture-u\tGamma\tThird\tOther\tImported\tfalse\tfalse\t"
        "\nfixture-a\tAlpha\tFirst\tReplacementOnly\tTechnical\tfalse\tfalse\t"
        "\nfixture-n\tDelta\tFourth\t\t\tfalse\tfalse\t");
    gchar *payload = vocabulary_action_payload(e, "save");
    gchar **fields = g_strsplit(payload, "\t", -1);
    const gboolean identity = g_strcmp0(e->category, "Names") == 0 && e->selected == 0
        && filter_visible_count(e) == 1 && g_strv_length(fields) == 9 && g_strcmp0(fields[1], "fixture-b") == 0;
    g_strfreev(fields); g_free(payload);
    if (!filter_expect(identity, "Pronunciation reload did not preserve category and UUID identity.",
        error, capacity)) return FALSE;
    filter_fixture("\ttrue\ttrue\t\tpronunciationCategories.v1\t3\tTechnical\t1",
        "\nfixture-u\tGamma\tThird\tOther\tImported\tfalse\tfalse\t"
        "\nfixture-a\tAlpha\tFirst\tReplacementOnly\tTechnical\tfalse\tfalse\t"
        "\nfixture-n\tDelta\tFourth\t\t\tfalse\tfalse\t");
    word = vocabulary_text(e->fields[1]);
    const gboolean removed = e->category[0] == '\0' && e->selected == -1 && filter_visible_count(e) == 3
        && word[0] == '\0';
    g_free(word);
    if (!filter_expect(removed, "A removed pronunciation category or entry became another selection.",
        error, capacity)) return FALSE;
    gtk_drop_down_set_selected(GTK_DROP_DOWN(e->category_filter), 1);
    filter_fixture("\ttrue\ttrue\t\tpronunciationCategories.v1\t0", "");
    if (!filter_expect(e->category[0] == '\0' && filter_visible_count(e) == 0 && e->categories->len == 1,
        "An empty pronunciation collection did not reset its category filter.", error, capacity)) return FALSE;
    filter_fixture(legacy, rows);
    if (!filter_expect(e->categories->len == 1 && filter_visible_count(e) == 4,
        "Legacy pronunciation payload handling failed.", error, capacity)) return FALSE;
    const char *invalid[] = {
        "\ttrue\ttrue\t\tpronunciationCategories.v2\t4",
        "\ttrue\ttrue\t\tpronunciationCategories.v1",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t4\tTechnical",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t-1",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t999999999999999999999",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t3",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t4\tTechnical\t-1",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t4\tTechnical\t0",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t4\tTechnical\t2",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t4\tTechnical\t01",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t4\tTechnical\t1\tTechnical\t1",
        "\ttrue\ttrue\t\tpronunciationCategories.v1\t4\t\t1"
    };
    for (guint i = 0; i < G_N_ELEMENTS(invalid); ++i) {
        filter_fixture(invalid[i], rows);
        if (!filter_expect(e->busy && e->rows->len == 4 && !filter_action_sensitive(e, "save")
            && filter_action_sensitive(e, "refresh")
            && g_str_has_prefix(gtk_label_get_text(GTK_LABEL(e->status)), "Invalid pronunciation category metadata"),
            "Malformed modern pronunciation metadata was not explicitly refused.", error, capacity)) return FALSE;
        filter_fixture(modern, rows);
    }
    int minimum = 0;
    gtk_widget_measure(e->root, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, NULL, NULL, NULL);
    gtk_widget_allocate(e->root, 800, 640, -1, NULL);
    graphene_rect_t dropdown, search, list;
    const gboolean bounds = gtk_widget_compute_bounds(e->category_filter, e->root, &dropdown)
        && gtk_widget_compute_bounds(e->search, e->root, &search)
        && gtk_widget_compute_bounds(GTK_WIDGET(e->list), e->root, &list);
    return filter_expect(minimum <= 800 && bounds && dropdown.size.width > 0 && dropdown.size.height > 0
        && dropdown.origin.x >= 0 && dropdown.origin.x + dropdown.size.width <= 800
        && search.origin.y + search.size.height <= dropdown.origin.y
        && dropdown.origin.y + dropdown.size.height <= list.origin.y
        && gtk_widget_get_scale_factor(e->category_filter) >= 1,
        "Pronunciation category controls exceeded minimum-size/scaled bounds.", error, capacity);
}
static gboolean pronunciation_filter_self_test(char *error, size_t capacity) {
    Editor *previous = vocabulary_editors[1];
    GtkWidget *window = gtk_window_new(); g_object_ref_sink(window);
    gtk_window_set_default_size(GTK_WINDOW(window), 800, 640);
    GtkWidget *page = jsti_vocabulary_page_new(1);
    gtk_window_set_child(GTK_WINDOW(window), page);
    gtk_widget_realize(window);
    const gboolean valid = pronunciation_filter_checks(vocabulary_editors[1], error, capacity);
    gtk_window_destroy(GTK_WINDOW(window)); g_object_unref(window);
    vocabulary_editors[1] = previous;
    return valid;
}
int32_t jsti_vocabulary_self_test(char *error, size_t capacity) {
    Editor *previous_legacy = vocabulary_editors[4];
    GtkWidget *legacy_page = jsti_vocabulary_page_new(4); g_object_ref_sink(legacy_page);
    Editor *legacy = vocabulary_editors[4];
    const gchar *legacy_row[] = {"fixture-identity", "Word\t%", "Spoken\nform", "", "", "", "", "", NULL};
    g_ptr_array_add(legacy->rows, g_strdupv((gchar **)legacy_row)); legacy->selected = 0;
    vocabulary_fill(legacy, (gchar **)legacy_row);
    gchar *legacy_payload = vocabulary_action_payload(legacy, "save");
    gchar **legacy_fields = g_strsplit(legacy_payload, "\t", -1);
    gchar *legacy_word = g_strv_length(legacy_fields) == 4 ? g_uri_unescape_string(legacy_fields[2], NULL) : NULL;
    gchar *legacy_value = g_strv_length(legacy_fields) == 4 ? g_uri_unescape_string(legacy_fields[3], NULL) : NULL;
    gboolean legacy_valid = g_strv_length(legacy_fields) == 4
        && g_strcmp0(legacy_fields[0], "save") == 0 && g_strcmp0(legacy_fields[1], legacy_row[0]) == 0
        && g_strcmp0(legacy_word, legacy_row[1]) == 0 && g_strcmp0(legacy_value, legacy_row[2]) == 0
        && !gtk_widget_get_sensitive(legacy->fields[1]) && !gtk_widget_get_sensitive(legacy->fields[2]);
    vocabulary_pending(legacy, FALSE);
    legacy_valid = legacy_valid && gtk_widget_get_sensitive(legacy->fields[1])
        && gtk_widget_get_sensitive(legacy->fields[2]);
    g_free(legacy_word); g_free(legacy_value); g_strfreev(legacy_fields); g_free(legacy_payload);
    legacy_payload = vocabulary_action_payload(legacy, "delete"); legacy_fields = g_strsplit(legacy_payload, "\t", -1);
    legacy_valid = legacy_valid && g_strv_length(legacy_fields) == 4 && g_strcmp0(legacy_fields[0], "delete") == 0
        && g_strcmp0(legacy_fields[1], legacy_row[0]) == 0;
    g_strfreev(legacy_fields); g_free(legacy_payload);
    legacy->selected = -1; vocabulary_fill(legacy, NULL);
    legacy_payload = vocabulary_action_payload(legacy, "save");
    legacy_valid = legacy_valid && g_strcmp0(legacy_payload, "save\t\t\t") == 0;
    g_free(legacy_payload); g_object_unref(legacy_page); vocabulary_editors[4] = previous_legacy;
    if (!legacy_valid) { jsti_set_error(error, capacity, "Legacy dictionary entry identity/escaped fields failed."); return -1; }
    for (int kind = 0; kind < 2; ++kind) {
        Editor *e = vocabulary_editors[kind];
        if (e == NULL) { jsti_set_error(error, capacity, "Vocabulary editor was not constructed."); return -1; }
        gchar *row[] = {"", "Synthetic", "Canonical", "spoken\nvariant\t%", kind == 0 ? "manual" : "Custom",
            kind == 0 ? "work" : "true", kind == 0 ? "low" : "true", "fixture notes", NULL};
        vocabulary_fill(e, row);
        gchar *payload = vocabulary_action_payload(e, "save");
        gchar **fields = g_strsplit(payload, "\t", -1);
        gchar *variant = g_strv_length(fields) == 9 ? g_uri_unescape_string(fields[4], NULL) : NULL;
        gboolean valid = g_strv_length(fields) == 9 && g_strcmp0(variant, row[3]) == 0
            && g_strcmp0(fields[5], row[4]) == 0 && g_strcmp0(fields[7], row[6]) == 0;
        g_free(variant); g_strfreev(fields); g_free(payload);
        vocabulary_set_text(e->preview, "Synthetic\t%\n"); vocabulary_set_text(e->preview_tags, "work");
        payload = vocabulary_action_payload(e, "preview"); fields = g_strsplit(payload, "\t", -1);
        variant = g_strv_length(fields) == 3 ? g_uri_unescape_string(fields[1], NULL) : NULL;
        valid = valid && g_strcmp0(variant, "Synthetic\t%\n") == 0 && g_strcmp0(fields[2], "work") == 0;
        g_free(variant); g_strfreev(fields); g_free(payload);
        vocabulary_fill(e, NULL); vocabulary_set_text(e->preview, ""); vocabulary_set_text(e->preview_tags, "");
        if (!valid) { jsti_set_error(error, capacity, "Vocabulary field and preview events were not preserved."); return -1; }
    }
    Editor *existing_candidates = vocabulary_editors[3];
    GtkWidget *candidate_page = jsti_vocabulary_page_new(3);
    g_object_ref_sink(candidate_page);
    Editor *candidate = vocabulary_editors[3];
    const gchar *fixture[] = {"synthetic\t%", "Synthetic", "Canonical", "2", "Synthetic", "", "", "Pending", NULL};
    g_ptr_array_add(candidate->rows, g_strdupv((gchar **)fixture)); candidate->selected = 0;
    gchar *candidate_payload = vocabulary_action_payload(candidate, "promote");
    gchar **candidate_fields = g_strsplit(candidate_payload, "\t", -1);
    gchar *candidate_id = g_strv_length(candidate_fields) == 2
        ? g_uri_unescape_string(candidate_fields[1], NULL) : NULL;
    gboolean candidate_valid = g_strcmp0(candidate_id, fixture[0]) == 0
        && g_strcmp0(candidate_fields[0], "promote") == 0;
    g_free(candidate_id); g_strfreev(candidate_fields); g_free(candidate_payload);
    candidate_payload = vocabulary_action_payload(candidate, "clear");
    candidate_valid = candidate_valid && g_strcmp0(candidate_payload, "clear") == 0;
    g_free(candidate_payload); g_object_unref(candidate_page); vocabulary_editors[3] = existing_candidates;
    if (!candidate_valid) { jsti_set_error(error, capacity, "Stored candidate events were not preserved."); return -1; }
    return pronunciation_filter_self_test(error, capacity) ? 0 : -1;
}
