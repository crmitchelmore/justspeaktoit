#include "LinuxSupportInternal.h"

#include <adwaita.h>
#include <string.h>

/*
 * Settings search, at the top of the sidebar. The entry reports each query
 * (debounced by GtkSearchEntry's search-changed) as JSTI_EVENT_SETTINGS_SEARCH;
 * Swift ranks it with the shared DesktopSettingsSearchSession and hands the
 * rows back through jsti_window_set_settings_search_results, applied in call
 * order with the window's other setters. Choosing a row reports
 * JSTI_EVENT_SETTINGS_SEARCH_OPEN with its index; Swift opens the page and
 * reveals the field. While a search is active its results replace the page
 * list; Escape or choosing a result brings the page list back.
 */

enum { SEARCH_MAXIMUM_RESULTS = 50, SEARCH_MAXIMUM_TEXT = 4096 };

typedef struct SearchRow {
    gchar *title;
    gchar *detail;
    gchar *identifier;
} SearchRow;

typedef struct SearchResults {
    SearchRow *rows;
    gsize count;
} SearchResults;

static struct {
    GtkSearchEntry *entry;
    GtkStack *stack;
    GtkListBox *list;
    GtkWidget *empty;
    guint count;
    /* Set by choosing a result or Escape: the page list shows until the query
     * changes or the entry is focused again. */
    gboolean dismissed;
    guint refresh_source;
} search;

/* The window's event callback; the self-test records events instead. */
static void (*search_emit)(int32_t event, const char *text, int32_t index) = jsti_window_emit;

static const char *search_query(void) { return gtk_editable_get_text(GTK_EDITABLE(search.entry)); }

static gboolean search_has_query(void) {
    for (const char *text = search_query(); text != NULL && *text != '\0'; text = g_utf8_next_char(text)) {
        if (!g_unichar_isspace(g_utf8_get_char(text))) return TRUE;
    }
    return FALSE;
}

static gboolean search_contains_focus(void) {
    GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(search.entry));
    GtkWidget *focus = root != NULL ? gtk_root_get_focus(root) : NULL;
    return focus != NULL && (focus == GTK_WIDGET(search.entry) ||
        gtk_widget_is_ancestor(focus, GTK_WIDGET(search.entry)) ||
        gtk_widget_is_ancestor(focus, GTK_WIDGET(search.list)));
}

static gboolean search_active(void) {
    return g_strcmp0(gtk_stack_get_visible_child_name(search.stack), "results") == 0;
}

/* Results replace the page list while there is a query, or recent
 * destinations to offer while the search has focus. */
static void search_refresh(void) {
    if (search.entry == NULL) return;
    gboolean query = search_has_query();
    gboolean active = !search.dismissed && (query || (search.count > 0 && search_contains_focus()));
    gtk_widget_set_visible(search.empty, query && search.count == 0);
    gtk_widget_set_visible(GTK_WIDGET(search.list), search.count > 0);
    gtk_stack_set_visible_child_name(search.stack, active ? "results" : "navigation");
}

static gboolean search_refresh_idle(gpointer data) {
    (void)data;
    search.refresh_source = 0;
    search_refresh();
    return G_SOURCE_REMOVE;
}

/* Focus leaving is reported before it lands; decide once it has. */
static void search_queue_refresh(void) {
    if (search.refresh_source == 0) search.refresh_source = g_idle_add(search_refresh_idle, NULL);
}

static void search_focus_entry(void) {
    GtkRoot *root = gtk_widget_get_root(GTK_WIDGET(search.entry));
    GtkWidget *focus = root != NULL ? gtk_root_get_focus(root) : NULL;
    GtkWidget *entry = GTK_WIDGET(search.entry);
    if (focus == NULL || (focus != entry && !gtk_widget_is_ancestor(focus, entry))) {
        gtk_widget_grab_focus(entry);
    }
}

/* Escape: clears the query and shows the page list again. */
static void search_clear(void) {
    search.dismissed = TRUE;
    if (search_query()[0] != '\0') gtk_editable_set_text(GTK_EDITABLE(search.entry), "");
    search_refresh();
}

static void search_open(gint index) {
    if (index < 0 || (guint)index >= search.count) return;
    /* Reported first: refocusing the entry may ask for recents, replacing the
     * rows `index` refers to. */
    search_emit(JSTI_EVENT_SETTINGS_SEARCH_OPEN, "", index);
    /* Keep focus out of the list it is about to hide. */
    if (search_contains_focus()) search_focus_entry();
    search_clear();
}

static void on_search_changed(GtkSearchEntry *entry, gpointer data) {
    (void)entry; (void)data;
    if (search_has_query()) search.dismissed = FALSE;
    search_emit(JSTI_EVENT_SETTINGS_SEARCH, search_query(), 0);
    search_refresh();
}

static void on_search_activate(GtkSearchEntry *entry, gpointer data) {
    (void)entry; (void)data;
    if (search_active() && search.count > 0) search_open(0);
}

static void on_search_stop(GtkSearchEntry *entry, gpointer data) {
    (void)entry; (void)data;
    search_clear();
}

static void on_search_focus_enter(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller; (void)data;
    search.dismissed = FALSE;
    /* An empty query asks for recent destinations. */
    if (!search_has_query()) search_emit(JSTI_EVENT_SETTINGS_SEARCH, "", 0);
    search_refresh();
}

static void on_search_focus_leave(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller; (void)data;
    search_queue_refresh();
}

/* Down moves from the entry into the results. */
static gboolean on_search_key(GtkEventControllerKey *controller, guint keyval, guint keycode,
                              GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)keycode; (void)modifiers; (void)data;
    if ((keyval != GDK_KEY_Down && keyval != GDK_KEY_KP_Down) || !search_active() || search.count == 0) return FALSE;
    GtkListBoxRow *first = gtk_list_box_get_row_at_index(search.list, 0);
    return first != NULL && gtk_widget_grab_focus(GTK_WIDGET(first));
}

/* Up from the first result returns to the entry; Escape clears from anywhere. */
static gboolean on_results_key(GtkEventControllerKey *controller, guint keyval, guint keycode,
                               GdkModifierType modifiers, gpointer data) {
    (void)controller; (void)keycode; (void)modifiers; (void)data;
    if (keyval == GDK_KEY_Escape) {
        search_focus_entry();
        search_clear();
        return TRUE;
    }
    if (keyval != GDK_KEY_Up && keyval != GDK_KEY_KP_Up) return FALSE;
    GtkWidget *first = GTK_WIDGET(gtk_list_box_get_row_at_index(search.list, 0));
    GtkWidget *focus = gtk_root_get_focus(gtk_widget_get_root(GTK_WIDGET(search.list)));
    if (first == NULL || focus == NULL || (focus != first && !gtk_widget_is_ancestor(focus, first))) return FALSE;
    search_focus_entry();
    return TRUE;
}

static void on_result_activated(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    (void)list; (void)data;
    search_open(gtk_list_box_row_get_index(row));
}

static GtkWidget *search_label(const char *text, const char *style) {
    GtkWidget *label = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_ellipsize(GTK_LABEL(label), PANGO_ELLIPSIZE_END);
    gtk_widget_add_css_class(label, style);
    return label;
}

static GtkWidget *search_row_new(const SearchRow *result) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_box_append(GTK_BOX(box), search_label(result->title, "jsti-search-title"));
    if (result->detail[0] != '\0') {
        GtkWidget *detail = search_label(result->detail, "dim-label");
        gtk_widget_add_css_class(detail, "caption");
        gtk_box_append(GTK_BOX(box), detail);
    }
    GtkWidget *row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    gchar *label = result->detail[0] != '\0' ? g_strdup_printf("%s, %s", result->title, result->detail)
                                             : g_strdup(result->title);
    gtk_accessible_update_property(GTK_ACCESSIBLE(row), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
    g_free(label);
    /* The shared SettingsSearchEntry.resultAccessibilityIdentifier, for
     * inspectors and UI automation. */
    gtk_widget_set_name(row, result->identifier);
    if (result->detail[0] != '\0') gtk_widget_set_tooltip_text(row, result->detail);
    return row;
}

static void search_results_apply(gpointer data) {
    SearchResults *results = data;
    if (search.list == NULL) return;
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(GTK_WIDGET(search.list))) != NULL) {
        gtk_list_box_remove(search.list, child);
    }
    for (gsize i = 0; i < results->count; ++i) gtk_list_box_append(search.list, search_row_new(&results->rows[i]));
    search.count = (guint)results->count;
    search_refresh();
    if (!search_has_query() || search.dismissed) return;
    gchar *announcement = search.count == 0 ? g_strdup("No settings match")
        : g_strdup_printf(g_dngettext(NULL, "%u setting found", "%u settings found", search.count), search.count);
    gtk_accessible_announce(GTK_ACCESSIBLE(search.list), announcement, GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
    g_free(announcement);
}

static void search_results_free(gpointer data) {
    SearchResults *results = data;
    for (gsize i = 0; i < results->count; ++i) {
        g_free(results->rows[i].title);
        g_free(results->rows[i].detail);
        g_free(results->rows[i].identifier);
    }
    g_free(results->rows);
    g_free(results);
}

static gboolean search_text_valid(const char *text) {
    return text != NULL && strlen(text) <= SEARCH_MAXIMUM_TEXT && g_utf8_validate(text, -1, NULL);
}

static SearchResults *search_results_copy(const JSTISettingsSearchResult *results, size_t count) {
    if (count > SEARCH_MAXIMUM_RESULTS || (count > 0 && results == NULL)) return NULL;
    for (size_t i = 0; i < count; ++i) {
        if (!search_text_valid(results[i].title) || !search_text_valid(results[i].detail) ||
            !search_text_valid(results[i].identifier)) return NULL;
    }
    SearchResults *copy = g_new0(SearchResults, 1);
    copy->rows = g_new0(SearchRow, count > 0 ? count : 1);
    copy->count = count;
    for (size_t i = 0; i < count; ++i) {
        copy->rows[i].title = g_strdup(results[i].title);
        copy->rows[i].detail = g_strdup(results[i].detail);
        copy->rows[i].identifier = g_strdup(results[i].identifier);
    }
    return copy;
}

int32_t jsti_window_set_settings_search_results(const JSTISettingsSearchResult *results, size_t count) {
    SearchResults *copy = search_results_copy(results, count);
    if (copy == NULL) return -1;
    return jsti_window_post(search_results_apply, copy, search_results_free);
}

static void on_search_destroy(GtkWidget *widget, gpointer data) {
    (void)widget; (void)data;
    if (search.refresh_source != 0) g_source_remove(search.refresh_source);
    memset(&search, 0, sizeof search);
}

void jsti_settings_search_focus(void) {
    if (search.entry == NULL) return;
    gboolean focused = search_contains_focus();
    search.dismissed = FALSE;
    search_focus_entry();
    gtk_editable_select_region(GTK_EDITABLE(search.entry), 0, -1);
    /* A fresh focus asks for recents itself; an existing one does not. */
    if (focused && !search_has_query()) search_emit(JSTI_EVENT_SETTINGS_SEARCH, "", 0);
    search_refresh();
}

struct _GtkWidget *jsti_settings_search_new(struct _GtkWidget *navigation) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    search.entry = GTK_SEARCH_ENTRY(gtk_search_entry_new());
    gtk_search_entry_set_placeholder_text(search.entry, "Search settings");
    gtk_accessible_update_property(GTK_ACCESSIBLE(search.entry), GTK_ACCESSIBLE_PROPERTY_LABEL, "Search settings", -1);
    gtk_widget_set_tooltip_text(GTK_WIDGET(search.entry), "Search settings (Ctrl+F or Ctrl+K)");
    gtk_widget_add_css_class(GTK_WIDGET(search.entry), "jsti-settings-search");
    gtk_widget_set_margin_start(GTK_WIDGET(search.entry), 8);
    gtk_widget_set_margin_end(GTK_WIDGET(search.entry), 8);
    gtk_widget_set_margin_top(GTK_WIDGET(search.entry), 4);
    gtk_widget_set_margin_bottom(GTK_WIDGET(search.entry), 6);
    g_signal_connect(search.entry, "search-changed", G_CALLBACK(on_search_changed), NULL);
    g_signal_connect(search.entry, "activate", G_CALLBACK(on_search_activate), NULL);
    g_signal_connect(search.entry, "stop-search", G_CALLBACK(on_search_stop), NULL);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(on_search_focus_enter), NULL);
    g_signal_connect(focus, "leave", G_CALLBACK(on_search_focus_leave), NULL);
    gtk_widget_add_controller(GTK_WIDGET(search.entry), focus);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_search_key), NULL);
    gtk_widget_add_controller(GTK_WIDGET(search.entry), keys);
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(search.entry));

    search.list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_list_box_set_selection_mode(search.list, GTK_SELECTION_NONE);
    gtk_widget_add_css_class(GTK_WIDGET(search.list), "navigation-sidebar");
    gtk_widget_add_css_class(GTK_WIDGET(search.list), "jsti-search-results");
    gtk_accessible_update_property(GTK_ACCESSIBLE(search.list), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   "Settings search results", -1);
    g_signal_connect(search.list, "row-activated", G_CALLBACK(on_result_activated), NULL);
    GtkEventController *result_keys = gtk_event_controller_key_new();
    g_signal_connect(result_keys, "key-pressed", G_CALLBACK(on_results_key), NULL);
    gtk_widget_add_controller(GTK_WIDGET(search.list), result_keys);
    GtkEventController *result_focus = gtk_event_controller_focus_new();
    g_signal_connect(result_focus, "leave", G_CALLBACK(on_search_focus_leave), NULL);
    gtk_widget_add_controller(GTK_WIDGET(search.list), result_focus);
    search.empty = gtk_label_new("No settings match");
    gtk_label_set_wrap(GTK_LABEL(search.empty), TRUE);
    gtk_widget_add_css_class(search.empty, "dim-label");
    gtk_widget_add_css_class(search.empty, "jsti-empty");
    gtk_widget_set_visible(search.empty, FALSE);
    GtkWidget *results = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(results), GTK_WIDGET(search.list));
    gtk_box_append(GTK_BOX(results), search.empty);
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), results);

    search.stack = GTK_STACK(gtk_stack_new());
    gtk_stack_set_transition_type(search.stack, GTK_STACK_TRANSITION_TYPE_NONE);
    gtk_widget_set_vexpand(GTK_WIDGET(search.stack), TRUE);
    gtk_stack_add_named(search.stack, navigation, "navigation");
    gtk_stack_add_named(search.stack, scroller, "results");
    gtk_stack_set_visible_child_name(search.stack, "navigation");
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(search.stack));
    g_signal_connect(box, "destroy", G_CALLBACK(on_search_destroy), NULL);
    return box;
}

/* --------------------------------------------------------------- self-test */

static struct {
    gint searches;
    gint opens;
    gint32 opened;
    gchar *query;
} recorded;

static void record_search_emit(int32_t event, const char *text, int32_t index) {
    if (event == JSTI_EVENT_SETTINGS_SEARCH) {
        recorded.searches++;
        g_free(recorded.query);
        recorded.query = g_strdup(text);
    } else if (event == JSTI_EVENT_SETTINGS_SEARCH_OPEN) {
        recorded.opens++;
        recorded.opened = index;
    }
}

static void apply_rows(const JSTISettingsSearchResult *rows, size_t count) {
    SearchResults *copy = search_results_copy(rows, count);
    search_results_apply(copy);
    search_results_free(copy);
}

static const char *check_search(void) {
    const JSTISettingsSearchResult rows[] = {
        { "Launch at login", "General · Start with the desktop", "settingsSearchResult.general.loginItem" },
        { "Language", "Transcription · Matches “locale”", "settingsSearchResult.desktop.field.language" }
    };
    JSTISettingsSearchResult invalid = { "\xff", "", "settingsSearchResult.invalid" };
    JSTISettingsSearchResult many[SEARCH_MAXIMUM_RESULTS + 1];
    for (size_t i = 0; i < G_N_ELEMENTS(many); ++i) many[i] = rows[0];
    if (jsti_window_set_settings_search_results(NULL, 1) != -1 ||
        jsti_window_set_settings_search_results(&invalid, 1) != -1 ||
        jsti_window_set_settings_search_results(many, G_N_ELEMENTS(many)) != -1) {
        return "settings search accepted missing, invalid or too many results";
    }
    gtk_editable_set_text(GTK_EDITABLE(search.entry), "zz");
    g_signal_emit_by_name(search.entry, "search-changed");
    if (recorded.searches == 0 || g_strcmp0(recorded.query, "zz") != 0) return "a settings query was not reported";
    apply_rows(rows, 0);
    if (!search_active() || !gtk_widget_get_visible(search.empty) || gtk_widget_get_visible(GTK_WIDGET(search.list))) {
        return "an unmatched settings query did not say no settings match";
    }
    apply_rows(rows, G_N_ELEMENTS(rows));
    GtkListBoxRow *second = gtk_list_box_get_row_at_index(search.list, 1);
    if (search.count != 2 || second == NULL || gtk_widget_get_visible(search.empty) ||
        g_strcmp0(gtk_widget_get_name(GTK_WIDGET(second)), rows[1].identifier) != 0) {
        return "settings search rows or their identifiers were not shown";
    }
    g_signal_emit_by_name(search.list, "row-activated", second);
    if (recorded.opens != 1 || recorded.opened != 1 || search_query()[0] != '\0' || search_active()) {
        return "choosing a settings result did not report its row and close the search";
    }
    gtk_editable_set_text(GTK_EDITABLE(search.entry), "lang");
    g_signal_emit_by_name(search.entry, "search-changed");
    apply_rows(rows, G_N_ELEMENTS(rows));
    g_signal_emit_by_name(search.entry, "activate");
    if (recorded.opens != 2 || recorded.opened != 0) return "Enter did not open the first settings result";
    gtk_editable_set_text(GTK_EDITABLE(search.entry), "lang");
    g_signal_emit_by_name(search.entry, "search-changed");
    apply_rows(rows, G_N_ELEMENTS(rows));
    g_signal_emit_by_name(search.entry, "stop-search");
    if (search_query()[0] != '\0' || search_active() || recorded.opens != 2) {
        return "Escape did not clear the settings search";
    }
    return NULL;
}

int32_t jsti_settings_search_self_test(char *error, size_t capacity) {
    if (search.entry == NULL) {
        jsti_set_error(error, capacity, "Window self-test: the settings search was not built");
        return -1;
    }
    search_emit = record_search_emit;
    const char *failure = check_search();
    gtk_editable_set_text(GTK_EDITABLE(search.entry), "");
    apply_rows(NULL, 0);
    search.dismissed = FALSE;
    search_refresh();
    search_emit = jsti_window_emit;
    g_clear_pointer(&recorded.query, g_free);
    recorded.searches = recorded.opens = 0;
    recorded.opened = 0;
    if (failure != NULL) {
        jsti_set_error(error, capacity, "Window self-test: %s", failure);
        return -1;
    }
    return 0;
}
