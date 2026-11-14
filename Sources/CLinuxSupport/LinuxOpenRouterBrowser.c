/* Browse OpenRouter models… (#1618): a search, provider and zero-price filtered
 * list of the shared OpenRouter catalogue with a details pane and a Choose
 * action. The host filters and writes every string (OpenRouterBrowser.h); this
 * window only renders a page and hands the chosen picker slot back. */
#include "LinuxSupportInternal.h"
#include <adwaita.h>
#include <string.h>

typedef struct {
    gchar *title, *subtitle, *details, *url, *identifier;
    gint32 slot;
    gboolean selected;
} Row;

static GMutex lock;
static JSTIOpenRouterBrowserQuery source;
static struct {
    GtkWindow *window;
    GtkLabel *intro, *status, *details;
    GtkSearchEntry *search;
    GtkStringList *providers;
    GtkDropDown *provider;
    GtkCheckButton *zero;
    GtkListBox *list;
    GtkWidget *link, *choose;
    GPtrArray *rows;
    gchar *action, *selected_action;
    gint32 purpose, selected_slot;
    jsti_openrouter_chosen_fn chosen;
    gboolean filling;
} browser;

int32_t jsti_window_set_openrouter_browser_source(JSTIOpenRouterBrowserQuery query) {
    if (query == NULL) return -1;
    g_mutex_lock(&lock);
    source = query;
    g_mutex_unlock(&lock);
    return 0;
}

static void row_free(gpointer data) {
    Row *row = data;
    g_free(row->title); g_free(row->subtitle); g_free(row->details); g_free(row->url); g_free(row->identifier);
    g_free(row);
}

static const char *text(const char *value) { return value != NULL && g_utf8_validate(value, -1, NULL) ? value : ""; }

static Row *current_row(void) {
    GtkListBoxRow *selected = browser.list != NULL ? gtk_list_box_get_selected_row(browser.list) : NULL;
    gint index = selected != NULL ? gtk_list_box_row_get_index(selected) : -1;
    return browser.rows != NULL && index >= 0 && (guint)index < browser.rows->len
        ? g_ptr_array_index(browser.rows, index) : NULL;
}

static void show_details(void) {
    if (browser.window == NULL) return;
    Row *row = current_row();
    gtk_label_set_text(browser.details, row != NULL ? row->details : "Choose a model to see its details.");
    gtk_widget_set_sensitive(browser.link, row != NULL && row->url[0] != '\0');
    gtk_widget_set_sensitive(browser.choose, row != NULL && !row->selected);
    const char *action = row != NULL && row->selected ? browser.selected_action : browser.action;
    gtk_button_set_label(GTK_BUTTON(browser.choose), action != NULL ? action : "Choose");
    if (row != NULL) {
        gchar *description = g_strdup_printf("%s, %s", row->title, row->subtitle);
        gtk_accessible_update_property(GTK_ACCESSIBLE(browser.choose), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION,
                                       description, -1);
        g_free(description);
    }
}

static gboolean same_providers(const JSTIOpenRouterBrowserPage *page) {
    if (g_list_model_get_n_items(G_LIST_MODEL(browser.providers)) != page->provider_count + 1) return FALSE;
    for (size_t index = 0; index < page->provider_count; ++index) {
        if (g_strcmp0(gtk_string_list_get_string(browser.providers, (guint)index + 1), text(page->providers[index])) != 0)
            return FALSE;
    }
    return TRUE;
}

static void receive(const JSTIOpenRouterBrowserPage *page, void *context) {
    (void)context;
    if (page == NULL || browser.window == NULL) return;
    browser.filling = TRUE;
    gtk_window_set_title(browser.window, text(page->title));
    gtk_label_set_text(browser.intro, text(page->intro));
    gtk_search_entry_set_placeholder_text(browser.search, text(page->search_placeholder));
    gtk_check_button_set_label(browser.zero, text(page->zero_prices));
    gtk_button_set_label(GTK_BUTTON(browser.link), text(page->link_title));
    g_free(browser.action); browser.action = g_strdup(text(page->action));
    g_free(browser.selected_action); browser.selected_action = g_strdup(text(page->selected_action));
    if (!same_providers(page)) {
        guint previous = gtk_drop_down_get_selected(browser.provider);
        gchar *name = previous != GTK_INVALID_LIST_POSITION && previous > 0
            ? g_strdup(gtk_string_list_get_string(browser.providers, previous)) : NULL;
        guint keep = 0;
        GPtrArray *names = g_ptr_array_new();
        g_ptr_array_add(names, (gpointer)text(page->all_providers));
        for (size_t index = 0; index < page->provider_count; ++index) {
            g_ptr_array_add(names, (gpointer)text(page->providers[index]));
            if (name != NULL && g_strcmp0(name, text(page->providers[index])) == 0) keep = (guint)index + 1;
        }
        g_ptr_array_add(names, NULL);
        guint existing = g_list_model_get_n_items(G_LIST_MODEL(browser.providers));
        gtk_string_list_splice(browser.providers, 0, existing, (const char *const *)names->pdata);
        g_ptr_array_unref(names);
        gtk_drop_down_set_selected(browser.provider, keep);
        g_free(name);
    }
    Row *previous = current_row();
    gchar *keep = previous != NULL ? g_strdup(previous->identifier) : NULL;
    gtk_list_box_remove_all(browser.list);
    g_clear_pointer(&browser.rows, g_ptr_array_unref);
    browser.rows = g_ptr_array_new_with_free_func(row_free);
    GtkListBoxRow *select = NULL, *chosen = NULL;
    for (size_t index = 0; page->rows != NULL && index < page->row_count; ++index) {
        const JSTIOpenRouterBrowserRow *source_row = &page->rows[index];
        Row *row = g_new0(Row, 1);
        row->title = g_strdup(text(source_row->title)); row->subtitle = g_strdup(text(source_row->subtitle));
        row->details = g_strdup(text(source_row->details)); row->url = g_strdup(text(source_row->url));
        row->identifier = g_strdup(text(source_row->identifier));
        row->slot = source_row->slot; row->selected = source_row->selected != 0;
        g_ptr_array_add(browser.rows, row);
        GtkWidget *widget = adw_action_row_new();
        /* Provider metadata is plain text, never Pango markup. */
        adw_preferences_row_set_use_markup(ADW_PREFERENCES_ROW(widget), FALSE);
        adw_preferences_row_set_title(ADW_PREFERENCES_ROW(widget), row->title);
        adw_action_row_set_subtitle(ADW_ACTION_ROW(widget), row->subtitle);
        gtk_widget_set_name(widget, row->identifier);
        if (row->selected) {
            GtkWidget *mark = gtk_image_new_from_icon_name("object-select-symbolic");
            gtk_accessible_update_property(GTK_ACCESSIBLE(mark), GTK_ACCESSIBLE_PROPERTY_LABEL, "Selected", -1);
            adw_action_row_add_suffix(ADW_ACTION_ROW(widget), mark);
        }
        gtk_list_box_append(browser.list, widget);
        GtkListBoxRow *list_row = GTK_LIST_BOX_ROW(widget);
        if (keep != NULL && g_strcmp0(keep, row->identifier) == 0) select = list_row;
        if (row->selected) chosen = list_row;
    }
    g_free(keep);
    if (select == NULL) select = chosen != NULL ? chosen : gtk_list_box_get_row_at_index(browser.list, 0);
    gtk_list_box_select_row(browser.list, select);
    gtk_label_set_text(browser.status, text(page->status));
    browser.filling = FALSE;
    show_details();
}

static void query(gboolean announce) {
    if (browser.window == NULL) return;
    g_mutex_lock(&lock);
    JSTIOpenRouterBrowserQuery fn = source;
    g_mutex_unlock(&lock);
    guint provider = gtk_drop_down_get_selected(browser.provider);
    gchar *name = g_strdup(provider != GTK_INVALID_LIST_POSITION && provider > 0
        ? gtk_string_list_get_string(browser.providers, provider) : "");
    gchar *search = g_strdup(gtk_editable_get_text(GTK_EDITABLE(browser.search)));
    gint32 result = fn != NULL ? fn(browser.purpose, search, name, gtk_check_button_get_active(browser.zero) ? 1 : 0,
                                    browser.selected_slot, receive, NULL) : -1;
    g_free(search); g_free(name);
    if (result != 0) {
        gtk_list_box_remove_all(browser.list);
        g_clear_pointer(&browser.rows, g_ptr_array_unref);
        gtk_label_set_text(browser.status, "OpenRouter models are not available yet. Refresh models and try again.");
        show_details();
    }
    if (announce) jsti_accessible_announce(GTK_WIDGET(browser.status), gtk_label_get_text(browser.status),
                                           GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
}

static void filters_changed(void) { if (!browser.filling) query(TRUE); }
static void on_search(GtkSearchEntry *entry, gpointer data) { (void)entry; (void)data; filters_changed(); }
static void on_provider(GObject *object, GParamSpec *spec, gpointer data) {
    (void)object; (void)spec; (void)data; filters_changed();
}
static void on_zero(GtkCheckButton *button, gpointer data) { (void)button; (void)data; filters_changed(); }
static void on_row_selected(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    (void)list; (void)row; (void)data;
    if (browser.window != NULL && !browser.filling) show_details();
}

/* Runs as the window is destroyed (Close, Escape, Choose or the owner closing). */
static void on_destroy(GtkWidget *widget, gpointer data) {
    (void)data;
    if (browser.window != GTK_WINDOW(widget)) return;
    browser.window = NULL;
    browser.list = NULL;
    browser.chosen = NULL;
    g_clear_pointer(&browser.rows, g_ptr_array_unref);
    g_clear_pointer(&browser.action, g_free);
    g_clear_pointer(&browser.selected_action, g_free);
    g_clear_object(&browser.providers);
}

void jsti_openrouter_browser_close(void) {
    if (browser.window != NULL) gtk_window_destroy(browser.window);
}

static void choose(void) {
    Row *row = current_row();
    if (row == NULL || row->selected) return;
    jsti_openrouter_chosen_fn chosen = browser.chosen;
    gint32 slot = row->slot;
    jsti_openrouter_browser_close();
    if (chosen != NULL) chosen(slot);
}
static void on_choose(GtkButton *button, gpointer data) { (void)button; (void)data; choose(); }
static void on_row_activated(GtkListBox *list, GtkListBoxRow *row, gpointer data) {
    (void)list; (void)row; (void)data; choose();
}
static void on_close(GtkButton *button, gpointer data) { (void)button; (void)data; jsti_openrouter_browser_close(); }

static void link_finished(GObject *object, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(object), result, &error)) {
        (void)jsti_window_update("The OpenRouter model page could not be opened.", NULL, -1);
        g_clear_error(&error);
    }
}
static void on_link(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    Row *row = current_row();
    if (row == NULL || row->url[0] == '\0' || browser.window == NULL) return;
    GtkUriLauncher *launcher = gtk_uri_launcher_new(row->url);
    gtk_uri_launcher_launch(launcher, browser.window, NULL, link_finished, NULL);
    g_object_unref(launcher);
}

void jsti_openrouter_browser_open(GtkWindow *owner, int32_t purpose, int32_t selected_slot,
                                  jsti_openrouter_chosen_fn chosen) {
    jsti_openrouter_browser_close();
    GtkWidget *column;
    browser.window = jsti_tool_window_new(owner, "Browse OpenRouter models", 720, &column);
    gtk_window_set_modal(browser.window, TRUE);
    g_signal_connect(browser.window, "destroy", G_CALLBACK(on_destroy), NULL);
    browser.purpose = purpose; browser.selected_slot = selected_slot; browser.chosen = chosen;
    gtk_widget_set_name(GTK_WIDGET(browser.window), "openRouterBrowser");

    browser.intro = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(browser.intro, TRUE);
    gtk_label_set_xalign(browser.intro, 0);
    gtk_widget_add_css_class(GTK_WIDGET(browser.intro), "dim-label");
    gtk_box_append(GTK_BOX(column), GTK_WIDGET(browser.intro));

    GtkWidget *filters = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    browser.search = GTK_SEARCH_ENTRY(gtk_search_entry_new());
    gtk_widget_set_hexpand(GTK_WIDGET(browser.search), TRUE);
    gtk_widget_set_name(GTK_WIDGET(browser.search), "openRouterBrowser.search");
    gtk_accessible_update_property(GTK_ACCESSIBLE(browser.search), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   "Search OpenRouter models", -1);
    g_signal_connect(browser.search, "search-changed", G_CALLBACK(on_search), NULL);
    gtk_box_append(GTK_BOX(filters), GTK_WIDGET(browser.search));
    browser.providers = gtk_string_list_new(NULL);
    browser.provider = GTK_DROP_DOWN(gtk_drop_down_new(G_LIST_MODEL(g_object_ref(browser.providers)), NULL));
    jsti_accessible_set_name(GTK_WIDGET(browser.provider), "Provider");
    gtk_widget_set_name(GTK_WIDGET(browser.provider), "openRouterBrowser.provider");
    g_signal_connect(browser.provider, "notify::selected", G_CALLBACK(on_provider), NULL);
    gtk_box_append(GTK_BOX(filters), GTK_WIDGET(browser.provider));
    browser.zero = GTK_CHECK_BUTTON(gtk_check_button_new_with_label("Zero listed prices"));
    gtk_widget_set_name(GTK_WIDGET(browser.zero), "openRouterBrowser.zeroPrices");
    g_signal_connect(browser.zero, "toggled", G_CALLBACK(on_zero), NULL);
    gtk_box_append(GTK_BOX(filters), GTK_WIDGET(browser.zero));
    gtk_box_append(GTK_BOX(column), filters);

    browser.list = GTK_LIST_BOX(gtk_list_box_new());
    gtk_list_box_set_selection_mode(browser.list, GTK_SELECTION_BROWSE);
    gtk_widget_add_css_class(GTK_WIDGET(browser.list), "boxed-list");
    gtk_widget_set_name(GTK_WIDGET(browser.list), "openRouterBrowser.models");
    gtk_accessible_update_property(GTK_ACCESSIBLE(browser.list), GTK_ACCESSIBLE_PROPERTY_LABEL, "OpenRouter models", -1);
#if GTK_CHECK_VERSION(4, 18, 0)
    gtk_list_box_set_tab_behavior(browser.list, GTK_LIST_TAB_ITEM);
#endif
    g_signal_connect(browser.list, "row-selected", G_CALLBACK(on_row_selected), NULL);
    g_signal_connect(browser.list, "row-activated", G_CALLBACK(on_row_activated), NULL);
    GtkWidget *models = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(models), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(models), 240);
    gtk_widget_set_vexpand(models, TRUE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(models), GTK_WIDGET(browser.list));
    gtk_box_append(GTK_BOX(column), models);

    browser.details = GTK_LABEL(gtk_label_new(""));
    gtk_label_set_wrap(browser.details, TRUE);
    gtk_label_set_wrap_mode(browser.details, PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(browser.details, 0);
    gtk_label_set_yalign(browser.details, 0);
    gtk_label_set_selectable(browser.details, TRUE);
    gtk_widget_set_focusable(GTK_WIDGET(browser.details), FALSE);
    gtk_widget_set_can_focus(GTK_WIDGET(browser.details), FALSE);
    gtk_widget_set_name(GTK_WIDGET(browser.details), "openRouterBrowser.details");
    gtk_accessible_update_property(GTK_ACCESSIBLE(browser.details), GTK_ACCESSIBLE_PROPERTY_LABEL, "Model details", -1);
    GtkWidget *details = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(details), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(details), 170);
    gtk_widget_set_can_focus(details, FALSE);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(details), GTK_WIDGET(browser.details));
    gtk_box_append(GTK_BOX(column), details);

    GtkWidget *footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    browser.status = GTK_LABEL(gtk_label_new(""));
    gtk_accessible_update_role(GTK_ACCESSIBLE(browser.status), GTK_ACCESSIBLE_ROLE_STATUS);
    gtk_label_set_wrap(browser.status, TRUE);
    gtk_label_set_xalign(browser.status, 0);
    gtk_widget_set_hexpand(GTK_WIDGET(browser.status), TRUE);
    gtk_widget_add_css_class(GTK_WIDGET(browser.status), "dim-label");
    gtk_widget_set_name(GTK_WIDGET(browser.status), "openRouterBrowser.status");
    gtk_box_append(GTK_BOX(footer), GTK_WIDGET(browser.status));
    browser.link = gtk_button_new_with_label("Model details on OpenRouter");
    gtk_widget_set_name(browser.link, "openRouterBrowser.openPage");
    g_signal_connect(browser.link, "clicked", G_CALLBACK(on_link), NULL);
    gtk_box_append(GTK_BOX(footer), browser.link);
    GtkWidget *close = gtk_button_new_with_label("Close");
    gtk_widget_set_name(close, "openRouterBrowser.close");
    g_signal_connect(close, "clicked", G_CALLBACK(on_close), NULL);
    gtk_box_append(GTK_BOX(footer), close);
    browser.choose = gtk_button_new_with_label("Choose");
    gtk_widget_add_css_class(browser.choose, "suggested-action");
    gtk_widget_set_name(browser.choose, "openRouterBrowser.choose");
    g_signal_connect(browser.choose, "clicked", G_CALLBACK(on_choose), NULL);
    gtk_box_append(GTK_BOX(footer), browser.choose);
    gtk_box_append(GTK_BOX(column), footer);

    query(FALSE);
    gtk_window_present(browser.window);
    gtk_widget_grab_focus(GTK_WIDGET(browser.search));
}

/* The self-test's catalogue: two providers, one zero-priced model, the second selected. */
static int32_t fixture_query(int32_t purpose, const char *search, const char *provider, int32_t zero_prices_only,
                             int32_t selected_slot, JSTIOpenRouterBrowserReceive deliver, void *context) {
    if (purpose != JSTI_OPENROUTER_BROWSER_CLEANUP) return -1;
    static const char *const providers[] = { "Meta Llama", "OpenAI" };
    JSTIOpenRouterBrowserRow all[] = {
        { "Llama Free", "Meta Llama · Free", "Llama Free\nInput / output: Free tokens", "", "openRouterBrowser.cleanup.llama",
          4, 0 },
        { "GPT <Mini> & Co", "OpenAI · $1 / $2", "GPT\nInput / output: $1 / $2 per 1M tokens",
          "https://openrouter.ai/openai/gpt", "openRouterBrowser.cleanup.gpt", 7, 0 },
    };
    JSTIOpenRouterBrowserRow rows[2];
    size_t count = 0;
    for (size_t index = 0; index < 2; ++index) {
        all[index].selected = all[index].slot == selected_slot;
        if (zero_prices_only && index != 0) continue;
        if (provider[0] != '\0' && !g_str_has_prefix(all[index].subtitle, provider)) continue;
        if (search[0] != '\0' && strstr(all[index].title, search) == NULL) continue;
        rows[count++] = all[index];
    }
    JSTIOpenRouterBrowserPage page = {
        "Browse OpenRouter models", "Intro", "Use for cleanup", "Selected for cleanup", "Search", "All providers",
        "Zero listed prices", "Model details on OpenRouter", count == 0 ? "No models match." : "Some models",
        providers, 2, rows, count,
    };
    deliver(&page, context);
    return 0;
}

static gint32 fixture_chosen = -1;
static void fixture_choose(int32_t slot) { fixture_chosen = slot; }

int32_t jsti_openrouter_browser_self_test(GtkWindow *owner, char *error, size_t capacity) {
    g_mutex_lock(&lock);
    JSTIOpenRouterBrowserQuery saved = source;
    source = fixture_query;
    g_mutex_unlock(&lock);
    fixture_chosen = -1;
    const char *failure = NULL;
    jsti_openrouter_browser_open(owner, JSTI_OPENROUTER_BROWSER_CLEANUP, 7, fixture_choose);
    Row *row = current_row();
    if (browser.window == NULL || !gtk_window_get_modal(browser.window) || browser.rows == NULL || browser.rows->len != 2)
        failure = "the browser did not open modally with both fixture models";
    else if (g_list_model_get_n_items(G_LIST_MODEL(browser.providers)) != 3)
        failure = "the provider filter did not list All providers and both providers";
    else if (row == NULL || !row->selected || gtk_widget_get_sensitive(browser.choose)
             || g_strcmp0(gtk_button_get_label(GTK_BUTTON(browser.choose)), "Selected for cleanup") != 0)
        failure = "the current choice was not preselected with its disabled Selected action";
    else if (g_strcmp0(adw_preferences_row_get_title(ADW_PREFERENCES_ROW(gtk_list_box_get_row_at_index(browser.list, 1))),
                       "GPT <Mini> & Co") != 0
             || g_strcmp0(gtk_widget_get_name(GTK_WIDGET(gtk_list_box_get_row_at_index(browser.list, 1))),
                          "openRouterBrowser.cleanup.gpt") != 0)
        failure = "a row lost its plain-text title or automation ID";
    if (failure == NULL) {
        gtk_check_button_set_active(browser.zero, TRUE);
        row = current_row();
        if (browser.rows->len != 1 || row == NULL || row->slot != 4 || !gtk_widget_get_sensitive(browser.choose)
            || gtk_widget_get_sensitive(browser.link))
            failure = "Zero listed prices did not narrow the list to the free model";
    }
    if (failure == NULL) {
        gtk_check_button_set_active(browser.zero, FALSE);
        gtk_drop_down_set_selected(browser.provider, 2);
        if (browser.rows->len != 1 || g_strcmp0(((Row *)g_ptr_array_index(browser.rows, 0))->title, "GPT <Mini> & Co") != 0)
            failure = "the provider filter did not narrow the list";
    }
    if (failure == NULL) {
        gtk_drop_down_set_selected(browser.provider, 0);
        gtk_editable_set_text(GTK_EDITABLE(browser.search), "nothing");
        query(FALSE);
        if (browser.rows->len != 0 || gtk_widget_get_sensitive(browser.choose)
            || g_strcmp0(gtk_label_get_text(browser.status), "No models match.") != 0)
            failure = "an empty search did not show the empty status";
    }
    if (failure == NULL) {
        gtk_editable_set_text(GTK_EDITABLE(browser.search), "Llama");
        query(FALSE);
        g_signal_emit_by_name(browser.choose, "clicked");
        if (fixture_chosen != 4 || browser.window != NULL) failure = "Choose did not hand back the slot and close";
    }
    jsti_openrouter_browser_close();
    g_mutex_lock(&lock);
    source = saved;
    g_mutex_unlock(&lock);
    if (failure != NULL) {
        jsti_set_error(error, capacity, "OpenRouter browser self-test: %s", failure);
        return -1;
    }
    return 0;
}
