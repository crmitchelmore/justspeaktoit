/* The vocabulary editor pages: the editor table, construction, filters and the
 * field/payload codec. Button actions are in LinuxVocabularyActions.c and host
 * payloads in LinuxVocabularyPresentation.c. */
#include "LinuxVocabularyInternal.h"
#include <adwaita.h>
#include <string.h>

GtkWidget *jsti_vocabulary_page_new(int kind);

static Editor *vocabulary_editors[5];
Editor *vocabulary_editor(int kind) {
    return kind >= 0 && kind < (int)G_N_ELEMENTS(vocabulary_editors) ? vocabulary_editors[kind] : NULL;
}
void vocabulary_set_editor(int kind, Editor *editor) {
    if (kind >= 0 && kind < (int)G_N_ELEMENTS(vocabulary_editors)) vocabulary_editors[kind] = editor;
}
GtkWidget *jsti_vocabulary_learning_preferences(void) {
    return vocabulary_editors[0] != NULL ? vocabulary_editors[0]->learning_preferences : NULL;
}
static const char *activations[] = { "automatic", "requireContextMatch", "manual", NULL };
static const char *confidences[] = { "high", "medium", "low", NULL };
static gboolean filter(GtkListBoxRow *row, gpointer data);
gboolean vocabulary_hidden_selection(Editor *e) {
    if ((e->kind != 1 && e->kind != 4) || e->selected < 0) return FALSE;
    GtkListBoxRow *row = gtk_list_box_get_row_at_index(e->list, e->selected);
    return row == NULL || !filter(row, e);
}
void vocabulary_selection_controls(Editor *e) {
    if (e->kind != 1 && e->kind != 4) return;
    const gboolean hidden = vocabulary_hidden_selection(e);
    for (guint i = 0; i < e->buttons->len; ++i) {
        GtkWidget *button = g_ptr_array_index(e->buttons, i);
        const char *action = g_object_get_data(G_OBJECT(button), "vocabulary-action");
        if (g_strcmp0(action, "save") == 0 || g_strcmp0(action, "delete") == 0
            || g_strcmp0(action, "up") == 0 || g_strcmp0(action, "down") == 0)
            gtk_widget_set_sensitive(button, !e->busy && !hidden);
    }
}
void vocabulary_apply_filters(Editor *e) {
    const gint selected = e->selected;
    e->filling = TRUE;
    gtk_list_box_invalidate_filter(e->list);
    GtkListBoxRow *row = selected >= 0 ? gtk_list_box_get_row_at_index(e->list, selected) : NULL;
    if (row != NULL && filter(row, e)) gtk_list_box_select_row(e->list, row);
    else gtk_list_box_unselect_all(e->list);
    e->selected = selected; e->filling = FALSE;
    vocabulary_selection_controls(e);
}

static gchar *escape(const char *text) {
    GString *result = g_string_new(NULL);
    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        switch (*p) {
        case '%': g_string_append(result, "%25"); break;
        case '\t': g_string_append(result, "%09"); break;
        case '\r': g_string_append(result, "%0D"); break;
        case '\n': g_string_append(result, "%0A"); break;
        default: g_string_append_c(result, (char)*p); break;
        }
    }
    return g_string_free(result, FALSE);
}
gchar *vocabulary_text(GtkWidget *widget) {
    if (GTK_IS_TEXT_VIEW(widget)) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget));
        GtkTextIter a, b; gtk_text_buffer_get_bounds(buffer, &a, &b);
        return gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    }
    return g_strdup(gtk_editable_get_text(GTK_EDITABLE(widget)));
}
void vocabulary_set_text(GtkWidget *widget, const char *value) {
    if (GTK_IS_TEXT_VIEW(widget)) gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(widget)), value, -1);
    else gtk_editable_set_text(GTK_EDITABLE(widget), value);
}
static gboolean combo(Editor *e, int i) { return e->kind == 0 && (i == 4 || i == 6); }
static gboolean check(Editor *e, int i) { return e->kind == 1 && (i == 5 || i == 6); }
void vocabulary_fill(Editor *e, gchar **row) {
    if (e->kind == 3) {
        gchar *details = row == NULL ? g_strdup(
            "Select a stored candidate. Learning requires separate local session consent.")
            : g_strdup_printf("%s -> %s\nSeen: %s\nSource apps: %s\nFirst seen: %s\nLast seen: %s\nState: %s",
                row[1], row[2], row[3], row[4], row[5], row[6], row[7]);
        gtk_label_set_text(GTK_LABEL(e->fields[1]), details); g_free(details); return;
    }
    for (int i = 1; i < (e->kind == 4 ? 3 : 8); ++i) {
        if (e->kind == 1 && i == 7) continue;
        const char *value = row != NULL ? row[i] : "";
        if (combo(e, i)) {
            const char **choices = i == 4 ? activations : confidences;
            guint selected = 0;
            for (guint j = 0; j < 3; ++j) if (g_strcmp0(value, choices[j]) == 0) selected = j;
            gtk_drop_down_set_selected(GTK_DROP_DOWN(e->fields[i]), selected);
        } else if (check(e, i)) {
            gtk_check_button_set_active(GTK_CHECK_BUTTON(e->fields[i]), g_strcmp0(value, "true") == 0);
        } else vocabulary_set_text(e->fields[i], value);
    }
}
static gboolean action_available(const char *action, gboolean busy) {
    return !busy || g_strcmp0(action, "stopLearning") == 0;
}
int32_t jsti_vocabulary_learning_controls_contract_self_test(void) {
    /* The same predicate drives the actual GTK buttons while a Host queue
     * is held; this fixture creates no widgets and performs no UI actions. */
    return action_available("stopLearning", TRUE) && action_available("stopLearning", FALSE)
        && !action_available("allowObservationalLearning", TRUE) && !action_available("save", TRUE)
        && action_available("allowObservationalLearning", FALSE) ? 0 : -1;
}
void vocabulary_pending(Editor *e, gboolean busy) {
    e->busy = busy;
    for (guint i = 0; i < e->buttons->len; ++i) {
        GtkWidget *button = g_ptr_array_index(e->buttons, i);
        const char *action = g_object_get_data(G_OBJECT(button), "vocabulary-action");
        gtk_widget_set_sensitive(button, action_available(action, busy));
    }
    gtk_widget_set_sensitive(GTK_WIDGET(e->list), !busy);
    if (e->kind == 4) {
        gtk_widget_set_sensitive(e->fields[1], !busy);
        gtk_widget_set_sensitive(e->fields[2], !busy);
        gtk_widget_set_sensitive(e->search, !busy);
    }
    vocabulary_selection_controls(e);
}
void vocabulary_append_field(GString *payload, const char *value) {
    gchar *escaped = escape(value);
    g_string_append_c(payload, '\t'); g_string_append(payload, escaped); g_free(escaped);
}
static void selected(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    (void)list;
    Editor *e = data;
    if (e->filling) return;
    e->selected = row != NULL ? gtk_list_box_row_get_index(row) : -1;
    if (e->selected >= 0) vocabulary_fill(e, g_ptr_array_index(e->rows, (guint)e->selected));
    vocabulary_selection_controls(e);
}
gchar *vocabulary_action_payload(Editor *e, const char *action) {
    GString *payload = g_string_new(action);
    if (e->kind == 4) {
        gchar **row = e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL;
        vocabulary_append_field(payload, row != NULL ? row[0] : "");
        for (int i = 1; i <= 2; ++i) {
            gchar *value = vocabulary_text(e->fields[i]); vocabulary_append_field(payload, value); g_free(value);
        }
    } else if (e->kind == 3) {
        if (g_strcmp0(action, "clear") != 0) {
            gchar **row = e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL;
            vocabulary_append_field(payload, row != NULL ? row[0] : "");
        }
    } else if (g_strcmp0(action, "preview") == 0) {
        gchar *sample = vocabulary_text(e->preview), *tags = vocabulary_text(e->preview_tags);
        vocabulary_append_field(payload, sample); vocabulary_append_field(payload, tags); g_free(sample); g_free(tags);
    } else if (g_strcmp0(action, "preferences") == 0) {
        vocabulary_append_field(payload, gtk_check_button_get_active(e->include_rules) ? "true" : "false");
        vocabulary_append_field(payload, gtk_check_button_get_active(e->include_tags) ? "true" : "false");
        vocabulary_append_field(payload, gtk_editable_get_text(GTK_EDITABLE(e->tags)));
    } else if (g_strcmp0(action, "defaults") != 0) {
        gchar **row = e->selected >= 0 ? g_ptr_array_index(e->rows, (guint)e->selected) : NULL;
        vocabulary_append_field(payload, row != NULL ? row[0] : "");
        for (int i = 1; i < 8; ++i) {
            if (e->kind == 1 && i == 7) { vocabulary_append_field(payload, ""); continue; }
            if (combo(e, i)) {
                guint choice = gtk_drop_down_get_selected(GTK_DROP_DOWN(e->fields[i]));
                vocabulary_append_field(payload, choice < 3 ? (i == 4 ? activations : confidences)[choice] : "");
            } else if (check(e, i)) {
                vocabulary_append_field(payload, gtk_check_button_get_active(GTK_CHECK_BUTTON(e->fields[i])) ? "true" : "false");
            } else {
                gchar *value = vocabulary_text(e->fields[i]); vocabulary_append_field(payload, value); g_free(value);
            }
        }
    }
    return g_string_free(payload, FALSE);
}
static gboolean filter(GtkListBoxRow *row, gpointer data) {
    Editor *e = data;
    const char *query = gtk_editable_get_text(GTK_EDITABLE(e->search));
    if (e->kind == 1) {
        const gint index = gtk_list_box_row_get_index(row);
        if (index < 0 || (guint)index >= e->rows->len) return FALSE;
        gchar **fields = g_ptr_array_index(e->rows, (guint)index);
        if (e->category[0] != '\0' && g_strcmp0(fields[4], e->category) != 0) return FALSE;
        gchar *needle = g_utf8_casefold(query, -1);
        gboolean match = FALSE;
        for (guint i = 1; i <= 3; ++i) {
            gchar *haystack = g_utf8_casefold(fields[i], -1);
            match = match || strstr(haystack, needle) != NULL;
            g_free(haystack);
        }
        g_free(needle); return match;
    }
    GtkWidget *label = gtk_list_box_row_get_child(row);
    gchar *haystack = g_utf8_casefold(gtk_label_get_text(GTK_LABEL(label)), -1), *needle = g_utf8_casefold(query, -1);
    gboolean match = strstr(haystack, needle) != NULL;
    g_free(haystack); g_free(needle); return match;
}
static void search_changed(GtkSearchEntry *search, gpointer data) {
    (void)search; Editor *e = data;
    if (e->kind == 1 || e->kind == 4) vocabulary_apply_filters(e);
    else gtk_list_box_invalidate_filter(e->list);
}
static void category_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; Editor *e = data;
    if (e->filling) return;
    const guint selected = gtk_drop_down_get_selected(GTK_DROP_DOWN(e->category_filter));
    if (selected >= e->categories->len) return;
    Category *category = g_ptr_array_index(e->categories, selected);
    g_free(e->category); e->category = g_strdup(category->value);
    vocabulary_apply_filters(e);
}
GtkWidget *vocabulary_multiline(GtkWidget **view) {
    *view = gtk_text_view_new();
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(*view), GTK_WRAP_WORD_CHAR);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 80);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), *view);
    return scroll;
}
static void destroy_editor(gpointer data) {
    Editor *e = data;
    if (e->kind == 0 && e->consent_token != 0)
        jsti_atspi_observational_consent(0, e->consent_token);
    if (vocabulary_editors[e->kind] == e) vocabulary_editors[e->kind] = NULL;
    g_ptr_array_unref(e->rows); g_ptr_array_unref(e->categories); g_ptr_array_unref(e->buttons);
    g_free(e->category); g_free(e);
}
GtkWidget *jsti_vocabulary_page_new(int kind) {
    Editor *e = g_new0(Editor, 1); e->kind = kind; e->selected = -1;
    e->rows = g_ptr_array_new_with_free_func((GDestroyNotify)g_strfreev);
    e->categories = g_ptr_array_new_with_free_func(vocabulary_category_free); e->category = g_strdup("");
    e->buttons = g_ptr_array_new();
    GtkWidget *column, *page = jsti_page_new(&column); e->root = page; vocabulary_editors[kind] = e;
    g_object_set_data_full(G_OBJECT(page), "vocabulary-editor", e, destroy_editor);
    GtkWidget *hero = jsti_hero_new("settings", kind == 0 ? "Corrections" : kind == 4 ? "Legacy word dictionary"
        : kind == 3 ? "Stored correction candidates" : "Pronunciation Dictionary",
        kind == 0 ? "Preferred spellings before post-processing. The original provider transcript stays in History."
        : kind == 4 ? "Mac word-to-pronunciation settings. Words can seed AssemblyAI; modern Read aloud entries stay separate."
        : kind == 3 ? "Review stored candidates. Optional session-consented AT-SPI observation is not acknowledged insertion."
        : "Your Read aloud dictionary. Deepgram uses text replacements, not IPA phoneme tags.", NULL, NULL);
    gtk_box_append(GTK_BOX(column), hero);
    if (kind == 0) {
        e->learning_preferences = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        gtk_box_append(GTK_BOX(column), e->learning_preferences);
    }
    e->search = gtk_search_entry_new();
    gtk_widget_set_tooltip_text(e->search, "Search saved entries");
    g_signal_connect(e->search, "search-changed", G_CALLBACK(search_changed), e);
    gtk_box_append(GTK_BOX(column), e->search);
    if (kind == 1) {
        GtkWidget *label = gtk_label_new_with_mnemonic("Category _filter");
        gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_box_append(GTK_BOX(column), label);
        const char *initial[] = {"All (0)", NULL};
        e->category_filter = gtk_drop_down_new_from_strings(initial);
        gtk_label_set_mnemonic_widget(GTK_LABEL(label), e->category_filter);
        gtk_accessible_update_property(GTK_ACCESSIBLE(e->category_filter), GTK_ACCESSIBLE_PROPERTY_LABEL,
            "Category filter", -1);
        g_signal_connect(e->category_filter, "notify::selected", G_CALLBACK(category_changed), e);
        gtk_box_append(GTK_BOX(column), e->category_filter);
    }
    e->list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_widget_add_css_class(GTK_WIDGET(e->list), "boxed-list");
    gtk_list_box_set_filter_func(e->list, filter, e, NULL);
    g_signal_connect(e->list, "row-selected", G_CALLBACK(selected), e);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 160);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroll), 260);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), GTK_WIDGET(e->list));
    gtk_box_append(GTK_BOX(column), scroll);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    if (kind == 3) {
        const char *titles[] = {"_Approve", "_Dismiss", "_Remove", "_Clear all", "Re_load"};
        const char *commands[] = {"promote", "dismiss", "remove", "clear", "refresh"};
        for (int i = 0; i < 5; ++i) gtk_box_append(GTK_BOX(actions), vocabulary_button(e, titles[i], commands[i]));
        gtk_box_append(GTK_BOX(column), actions);
        e->fields[1] = gtk_label_new("");
        gtk_label_set_xalign(GTK_LABEL(e->fields[1]), 0);
        gtk_label_set_wrap(GTK_LABEL(e->fields[1]), TRUE);
        gtk_label_set_selectable(GTK_LABEL(e->fields[1]), TRUE);
        gtk_box_append(GTK_BOX(column), e->fields[1]);
        e->status = gtk_label_new("Reload to inspect stored candidates.");
        gtk_label_set_wrap(GTK_LABEL(e->status), TRUE);
        gtk_label_set_xalign(GTK_LABEL(e->status), 0);
        gtk_box_append(GTK_BOX(column), e->status);
        vocabulary_fill(e, NULL); vocabulary_pending(e, TRUE); return page;
    }
    const char *names[] = {"_New", "_Delete", "Move _up", "Move _down", "_Reload"};
    const char *values[] = {"new", "delete", "up", "down", "refresh"};
    for (int i = 0; i < 5; ++i)
        if (kind != 4 || (i != 2 && i != 3)) gtk_box_append(GTK_BOX(actions), vocabulary_button(e, names[i], values[i]));
    gtk_box_append(GTK_BOX(column), actions);
    const char *rules[] = {"Display name", "Canonical spelling", "Spoken variants (one per line)", "Activation",
        "Context tags (comma-separated)", "Confidence", "Notes"};
    const char *speech[] = {"Word or pattern", "Pronunciation", "Text replacement", "Category",
        "Regular expression", "Case sensitive", "Notes (not stored)"};
    for (int i = 1; i < (kind == 4 ? 3 : 8); ++i) {
        if (kind == 1 && i == 7) continue;
        const char *title = kind == 4 ? (i == 1 ? "Word" : "Pronunciation") : (kind == 0 ? rules : speech)[i - 1];
        GtkWidget *label = gtk_label_new(title);
        gtk_label_set_xalign(GTK_LABEL(label), 0); gtk_box_append(GTK_BOX(column), label);
        GtkWidget *widget;
        if (combo(e, i)) {
            const char *a[] = {"Automatic", "Require context match", "Manual confirmation", NULL};
            const char *c[] = {"High", "Medium", "Low", NULL};
            widget = gtk_drop_down_new_from_strings(i == 4 ? a : c); e->fields[i] = widget;
        } else if (check(e, i)) {
            widget = gtk_check_button_new_with_label(speech[i - 1]); e->fields[i] = widget;
        } else if ((kind == 0 && i == 3) || kind == 4) widget = vocabulary_multiline(&e->fields[i]);
        else { widget = gtk_entry_new(); e->fields[i] = widget; }
        gtk_label_set_mnemonic_widget(GTK_LABEL(label), e->fields[i]);
        gtk_accessible_update_property(GTK_ACCESSIBLE(e->fields[i]), GTK_ACCESSIBLE_PROPERTY_LABEL,
            title, -1);
        gtk_box_append(GTK_BOX(column), widget);
    }
    gtk_box_append(GTK_BOX(column), vocabulary_button(e, "_Save entry", "save"));
    if (kind == 4) {
        e->status = gtk_label_new("Loading legacy word dictionary...");
        gtk_label_set_wrap(GTK_LABEL(e->status), TRUE); gtk_label_set_selectable(GTK_LABEL(e->status), TRUE);
        gtk_label_set_xalign(GTK_LABEL(e->status), 0); gtk_box_append(GTK_BOX(column), e->status);
        vocabulary_fill(e, NULL); vocabulary_pending(e, TRUE); return page;
    }
    if (kind == 1) {
        gtk_box_append(GTK_BOX(column), vocabulary_button(e, "Add default _entries", "defaults"));
        GtkWidget *transfers = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
        gtk_box_append(GTK_BOX(transfers), vocabulary_button(e, "_Import JSON (merge)", "importMerge"));
        gtk_box_append(GTK_BOX(transfers), vocabulary_button(e, "Import JSON (replace)", "importReplace"));
        gtk_box_append(GTK_BOX(transfers), vocabulary_button(e, "_Export JSON", "export"));
        gtk_box_append(GTK_BOX(column), transfers);
        gtk_box_append(GTK_BOX(column), vocabulary_button(e, "Legacy _word dictionary", "legacyDictionary"));
    }
    GtkWidget *label = gtk_label_new("Preview text (saved entries are used)");
    gtk_label_set_xalign(GTK_LABEL(label), 0); gtk_box_append(GTK_BOX(column), label);
    gtk_box_append(GTK_BOX(column), vocabulary_multiline(&e->preview));
    gtk_accessible_update_property(GTK_ACCESSIBLE(e->preview), GTK_ACCESSIBLE_PROPERTY_LABEL, "Preview text", -1);
    e->preview_tags = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(e->preview_tags), "Preview context tags, comma-separated");
    gtk_accessible_update_property(GTK_ACCESSIBLE(e->preview_tags), GTK_ACCESSIBLE_PROPERTY_LABEL,
        "Preview context tags, comma-separated", -1);
    gtk_box_append(GTK_BOX(column), e->preview_tags);
    gtk_box_append(GTK_BOX(column), vocabulary_button(e, "_Preview", "preview"));
    if (kind == 0) {
        e->include_rules = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Include rules in post-processing"));
        e->include_tags = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Include context tags in post-processing"));
        e->tags = GTK_ENTRY(gtk_entry_new());
        gtk_entry_set_placeholder_text(e->tags, "Recording context tags, comma-separated");
        gtk_accessible_update_property(GTK_ACCESSIBLE(e->tags), GTK_ACCESSIBLE_PROPERTY_LABEL,
            "Recording context tags, comma-separated", -1);
        gtk_box_append(GTK_BOX(column), GTK_WIDGET(e->include_rules));
        gtk_box_append(GTK_BOX(column), GTK_WIDGET(e->include_tags));
        gtk_box_append(GTK_BOX(column), GTK_WIDGET(e->tags));
        gtk_box_append(GTK_BOX(column), vocabulary_button(e, "Save _context settings", "preferences"));
        gtk_box_append(GTK_BOX(column), vocabulary_button(e, "Review stored _candidates", "candidates"));
        label = gtk_label_new("Observational learning is off until you explicitly allow it for this session. "
            "App-origin changes can also be learned. Only supported AT-SPI fields qualify; paste never does. "
            "Enable and apply Correction learning above first. Accessibility availability depends on the desktop and toolkit, "
            "including on Wayland; no OS accessibility setting is changed.");
        gtk_label_set_wrap(GTK_LABEL(label), TRUE); gtk_box_append(GTK_BOX(column), label);
        gtk_box_append(GTK_BOX(column), vocabulary_button(e, "_Allow observational learning...", "allowObservationalLearning"));
        gtk_box_append(GTK_BOX(column), vocabulary_button(e, "_Stop learning", "stopLearning"));
    }
    e->status = gtk_label_new("Select Reload to load saved entries.");
    gtk_label_set_wrap(GTK_LABEL(e->status), TRUE); gtk_label_set_selectable(GTK_LABEL(e->status), TRUE);
    gtk_label_set_xalign(GTK_LABEL(e->status), 0); gtk_box_append(GTK_BOX(column), e->status);
    vocabulary_fill(e, NULL); return page;
}
