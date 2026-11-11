/* The GTK window: its shared state, window construction, activation and jsti_window_run. */
#include "LinuxWindowInternal.h"
#include "LinuxWindowDashboardPage.h"
#include "LinuxWindowHistoryPage.h"
#include "LinuxWindowModelsPage.h"
#include "LinuxWindowPolishPage.h"
#include "LinuxWindowStoragePage.h"

EscapePolicy escape_policy = { .enabled = TRUE };

void escape_publish(EscapePolicy *policy, gint32 recording, gint32 enabled, gboolean close) {
    g_mutex_lock(&policy->mutex);
    if (recording >= 0) policy->recording = recording == JSTI_STATE_RECORDING || recording == JSTI_STATE_WORKING;
    if (enabled >= 0) policy->enabled = enabled != 0;
    if (close) policy->closed = TRUE;
    gboolean active = policy->recording && policy->enabled && !policy->closed;
    if ((gboolean)(policy->epoch & 1u) != active) ++policy->epoch;
    g_mutex_unlock(&policy->mutex);
}

guint64 escape_token(EscapePolicy *policy) {
    g_mutex_lock(&policy->mutex);
    guint64 token = policy->epoch & 1u ? policy->epoch : 0;
    g_mutex_unlock(&policy->mutex);
    return token;
}

gboolean escape_enabled(void) {
    g_mutex_lock(&escape_policy.mutex);
    gboolean enabled = escape_policy.enabled;
    g_mutex_unlock(&escape_policy.mutex);
    return enabled;
}

int32_t jsti_window_set_escape_cancellation(int32_t enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    escape_publish(&escape_policy, -1, enabled, FALSE);
    return 0;
}

int32_t jsti_window_escape_is_current(uint64_t token) {
    return (token & 1u) && token == escape_token(&escape_policy);
}

CleanupPreview cleanup_preview;

void retire_cleanup_preview(void) {
    g_mutex_lock(&cleanup_preview.lock);
    ++cleanup_preview.ticket;
    cleanup_preview.active = FALSE;
    g_clear_pointer(&cleanup_preview.text, g_free);
    g_mutex_unlock(&cleanup_preview.lock);
}

UI ui;
ConfigurationState configuration;
/* Fields in the first configuration, which builds the rows; any thread. */
ReadAloud read_aloud;



static gboolean on_close_request(GtkWindow *window, gpointer data) {
    (void)window; (void)data;
    retire_cleanup_preview();
    jsti_issue_reports_close();
    jsti_troubleshooting_close();
    jsti_api_keys_close();
    jsti_permissions_close();
    jsti_voice_sources_close();
    jsti_voice_credentials_close();
    jsti_action_shortcut_editor_close();
    jsti_setup_close();
    ui.closing = TRUE;
    escape_publish(&escape_policy, -1, -1, TRUE);
    retire_migration_restore();
    if (storage_page()->backup_chooser != NULL) g_cancellable_cancel(storage_page()->backup_chooser);
    g_clear_object(&storage_page()->backup_chooser);
    if (storage_page()->location_chooser != NULL) g_cancellable_cancel(storage_page()->location_chooser);
    g_clear_object(&storage_page()->location_chooser);
    g_clear_handle_id(&ui.state_announcement, g_source_remove);
    jsti_hud_destroy();
    jsti_tray_stop();
    emit(JSTI_EVENT_CLOSING, "", 0);
    close_posts();
    if (models_page()->model_catalog != NULL) { models_free(models_page()->model_catalog); models_page()->model_catalog = NULL; }
    g_clear_pointer(&history_page()->all_history_ids, g_free);
    return FALSE;
}

static void build_window(void) {
    jsti_style_install();
    GtkWidget *window = adw_application_window_new(GTK_APPLICATION(ui.application));
    ui.window = GTK_WINDOW(window);
    jsti_issue_reports_bind(ui.window);
    gtk_window_set_title(ui.window, "Just Speak to It");
    gtk_window_set_default_size(ui.window, 1080, 760);
    /* Settings editors need a usable desktop width; a 360px minimum let
     * controls overflow in small floating windows on HiDPI displays. */
    gtk_widget_set_size_request(window, 640, 480);
    g_signal_connect(window, "close-request", G_CALLBACK(on_close_request), NULL);
    GtkEventController *cancel_keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(cancel_keys, GTK_PHASE_CAPTURE);
    g_signal_connect(cancel_keys, "key-pressed", G_CALLBACK(cancel_key_pressed), NULL);
    g_signal_connect(cancel_keys, "key-released", G_CALLBACK(action_key_released), NULL);
    gtk_widget_add_controller(window, cancel_keys);
    GtkEventController *navigation_keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(navigation_keys, GTK_PHASE_BUBBLE);
    g_signal_connect(navigation_keys, "key-pressed", G_CALLBACK(sidebar_key_pressed), NULL);
    gtk_widget_add_controller(window, navigation_keys);
    GtkEventController *releases = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(releases, GTK_PHASE_CAPTURE);
    g_signal_connect(releases, "key-released", G_CALLBACK(action_key_released), NULL);
    gtk_widget_add_controller(window, releases);
    g_signal_connect(window, "notify::is-active", G_CALLBACK(action_window_active), NULL);

    /* One transcript buffer: the dashboard and the selected History card show
     * the same displayed text, which Copy, Export and Read aloud act on. */
    GtkTextBuffer *buffer = gtk_text_buffer_new(NULL);
    ui.pages = GTK_STACK(gtk_stack_new());
    /* A wide hidden settings page must not impose its minimum width on Dashboard. */
    gtk_stack_set_hhomogeneous(ui.pages, FALSE);
    gtk_stack_set_vhomogeneous(ui.pages, FALSE);
    gtk_stack_set_transition_type(ui.pages, GTK_STACK_TRANSITION_TYPE_CROSSFADE);
    GtkWidget *sidebar = build_sidebar();
    add_page(JSTI_PAGE_DASHBOARD, build_dashboard(buffer));
    add_page(JSTI_PAGE_HISTORY, build_history(buffer));
    add_page(JSTI_PAGE_VOICE_OUTPUT, build_voice_output());
    add_page(JSTI_PAGE_GENERAL, build_general());
    add_page(JSTI_PAGE_TRANSCRIPTION, build_transcription());
    add_page(JSTI_PAGE_POST_PROCESSING, build_post_processing());
    add_page(JSTI_PAGE_CORRECTIONS, jsti_vocabulary_page_new(0));
    ui.configuration_columns[4] = jsti_vocabulary_learning_preferences();
    add_page(JSTI_PAGE_PRONUNCIATION, jsti_vocabulary_page_new(1));
    add_page(JSTI_PAGE_PROFILES, jsti_profiles_page_new());
    add_page(JSTI_PAGE_KEYBOARD, build_keyboard());
    add_page(JSTI_PAGE_CLOUD_SYNC, build_cloud_sync());
    add_page(JSTI_PAGE_ABOUT, build_about());
    g_object_unref(buffer);

    GtkWidget *content = adw_toolbar_view_new();
    GtkWidget *header = adw_header_bar_new();
    ui.title = ADW_WINDOW_TITLE(adw_window_title_new("Dashboard", ""));
    adw_header_bar_set_title_widget(ADW_HEADER_BAR(header), GTK_WIDGET(ui.title));
    GtkButton *import_button = GTK_BUTTON(gtk_button_new_from_icon_name("document-open-symbolic"));
    history_page()->import_button = import_button;
    gtk_widget_set_tooltip_text(GTK_WIDGET(import_button), "Import audio…");
    gtk_accessible_update_property(GTK_ACCESSIBLE(import_button), GTK_ACCESSIBLE_PROPERTY_LABEL, "Import audio", -1);
    g_signal_connect(import_button, "clicked", G_CALLBACK(on_import), NULL);
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), GTK_WIDGET(import_button));
    ui.header_record = GTK_BUTTON(gtk_button_new());
    GtkWidget *record_content = adw_button_content_new();
    adw_button_content_set_icon_name(ADW_BUTTON_CONTENT(record_content), "audio-input-microphone-symbolic");
    adw_button_content_set_label(ADW_BUTTON_CONTENT(record_content), "Record");
    gtk_button_set_child(ui.header_record, record_content);
    gtk_widget_add_css_class(GTK_WIDGET(ui.header_record), "suggested-action");
    g_signal_connect(ui.header_record, "clicked", G_CALLBACK(on_record), NULL);
    adw_header_bar_pack_end(ADW_HEADER_BAR(header), GTK_WIDGET(ui.header_record));
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(content), header);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(content), GTK_WIDGET(ui.pages));
    GtkWidget *statusbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(statusbar, "jsti-statusbar");
    /* The status role lets screen readers and agents find the app's current state. */
    dashboard_page()->status = GTK_LABEL(g_object_new(GTK_TYPE_LABEL, "label", "Starting…",
                                       "accessible-role", GTK_ACCESSIBLE_ROLE_STATUS, NULL));
    gtk_label_set_wrap(dashboard_page()->status, TRUE);
    gtk_label_set_xalign(dashboard_page()->status, 0);
    gtk_label_set_selectable(dashboard_page()->status, TRUE);
    gtk_widget_set_hexpand(GTK_WIDGET(dashboard_page()->status), TRUE);
    gtk_box_append(GTK_BOX(statusbar), GTK_WIDGET(dashboard_page()->status));
    adw_toolbar_view_add_bottom_bar(ADW_TOOLBAR_VIEW(content), statusbar);

    ui.split = ADW_NAVIGATION_SPLIT_VIEW(adw_navigation_split_view_new());
    adw_navigation_split_view_set_min_sidebar_width(ui.split, 210);
    adw_navigation_split_view_set_max_sidebar_width(ui.split, 280);
    adw_navigation_split_view_set_sidebar(ui.split, adw_navigation_page_new(sidebar, "Just Speak to It"));
    adw_navigation_split_view_set_content(ui.split, adw_navigation_page_new(content, "Just Speak to It"));
    /* AdwApplicationWindow applies only the last matching breakpoint, not all
     * matching conditions. Keep the compact setters together so stacking cannot
     * accidentally override sidebar collapse on a narrow/HiDPI desktop. */
    AdwBreakpoint *compact = adw_breakpoint_new(adw_breakpoint_condition_parse("max-width: 900sp"));
    GValue collapsed = G_VALUE_INIT;
    g_value_init(&collapsed, G_TYPE_BOOLEAN);
    g_value_set_boolean(&collapsed, TRUE);
    adw_breakpoint_add_setter(compact, G_OBJECT(ui.split), "collapsed", &collapsed);
    g_value_unset(&collapsed);
    GValue vertical = G_VALUE_INIT;
    g_value_init(&vertical, GTK_TYPE_ORIENTATION);
    g_value_set_enum(&vertical, GTK_ORIENTATION_VERTICAL);
    adw_breakpoint_add_setter(compact, G_OBJECT(dashboard_page()->columns), "orientation", &vertical);
    g_value_unset(&vertical);
    GValue unequal = G_VALUE_INIT;
    g_value_init(&unequal, G_TYPE_BOOLEAN);
    g_value_set_boolean(&unequal, FALSE);
    adw_breakpoint_add_setter(compact, G_OBJECT(dashboard_page()->columns), "homogeneous", &unequal);
    g_value_unset(&unequal);
    add_compact_hero_setters(compact, GTK_WIDGET(ui.pages));
    adw_application_window_add_breakpoint(ADW_APPLICATION_WINDOW(window), compact);
    /* The content paints the window background, so snapshots of it are opaque. */
    gtk_widget_add_css_class(GTK_WIDGET(ui.split), "jsti-root");
    adw_application_window_set_content(ADW_APPLICATION_WINDOW(window), GTK_WIDGET(ui.split));
    show_page(JSTI_PAGE_DASHBOARD);
    /* Start on the page list, not the search entry ahead of it, so typing and
     * Ctrl+digit page shortcuts behave as before. */
    gtk_window_set_focus(ui.window, GTK_WIDGET(gtk_list_box_get_selected_row(ui.sidebar)));
    refresh_actions();
}

/* -------------------------------------------------------- application */

typedef struct RunModels {
    const JSTIModelRow *rows;
    size_t count;
    gint32 selected;
} RunModels;

static RunModels initial_models;

static void on_toggle_action(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action; (void)parameter; (void)data;
    emit(JSTI_EVENT_COMMAND_TOGGLE, selected_microphone(), selected_model_slot());
}

static gboolean emit_ready(gpointer data) {
    (void)data;
    emit(JSTI_EVENT_READY, "", 0);
    return G_SOURCE_REMOVE;
}

static void on_activate(GApplication *application, gpointer data) {
    (void)application; (void)data;
    if (ui.window != NULL) {
        gtk_window_present(ui.window);
        return;
    }
    jsti_app_icon_install();
    build_window();
    gtk_window_set_icon_name(ui.window, "com.justspeaktoit.JustSpeakToIt");
    jsti_hands_free_guard_start();
    jsti_tray_start();
    ui.suppress = TRUE;
    apply_models(initial_models.rows, initial_models.count, initial_models.selected);
    ui.suppress = FALSE;
    open_posts();
    if (ui.start_minimized) {
        /* Minimised before it is first shown, and shown without the focus
         * request present() makes, so nothing is taken from the login session. */
        gtk_window_minimize(ui.window);
        gtk_widget_set_visible(GTK_WIDGET(ui.window), TRUE);
    } else {
        gtk_window_present(ui.window);
    }
    if (!ui.ready_sent) {
        ui.ready_sent = TRUE;
        /* The smoke test inspects and captures a laid-out, drawn window. */
        if (ui.flags & JSTI_WINDOW_SMOKE_TEST) g_timeout_add(750, emit_ready, NULL);
        else emit(JSTI_EVENT_READY, "", 0);
    }
}

int32_t jsti_window_run(
    const char *app_id, int argc, char **argv, const JSTIModelRow *models, size_t model_count,
    int32_t selected_model, jsti_window_event_fn callback, void *context, int32_t flags, char *error,
    size_t capacity) {
    if (ui.application != NULL) {
        jsti_set_error(error, capacity, "The window is already running.");
        return -1;
    }
    GApplicationFlags application_flags = G_APPLICATION_HANDLES_COMMAND_LINE;
    if (flags & JSTI_WINDOW_SMOKE_TEST) application_flags |= G_APPLICATION_NON_UNIQUE;
    /* NON_UNIQUE still exports an object path. Keep the smoke window's path
     * separate from the private command fixture's real application identity. */
    gchar *fixture_id = (flags & JSTI_WINDOW_SMOKE_TEST) &&
        g_strcmp0(g_getenv("JSTI_COMMAND_FORWARDING_CHECK"), "1") == 0
        ? g_strconcat(app_id, ".CommandFixture", NULL) : NULL;
    ui.application = adw_application_new(fixture_id != NULL ? fixture_id : app_id, application_flags);
    g_free(fixture_id);
    if (ui.application == NULL) {
        jsti_set_error(error, capacity, "Could not create the application.");
        return -1;
    }
    ui.callback = callback;
    ui.context = context;
    ui.flags = flags;
    history_page()->presented_variant = -1;
    initial_models = (RunModels){ .rows = models, .count = model_count, .selected = selected_model };
    GSimpleAction *toggle = g_simple_action_new("toggle-recording", NULL);
    g_signal_connect(toggle, "activate", G_CALLBACK(on_toggle_action), NULL);
    g_action_map_add_action(G_ACTION_MAP(ui.application), G_ACTION(toggle));
    g_object_unref(toggle);
    g_signal_connect(ui.application, "activate", G_CALLBACK(on_activate), NULL);
    g_signal_connect(ui.application, "command-line", G_CALLBACK(on_command_line), NULL);
    int status = g_application_run(G_APPLICATION(ui.application), argc, argv);
    jsti_issue_reports_close();
    jsti_hands_free_guard_stop();
    jsti_setup_close();
    retire_migration_restore();
    close_posts();
    ui.callback = NULL;
    read_aloud.picker_callback = NULL;
    read_aloud.picker_context = NULL;
    g_clear_pointer(&read_aloud.identifiers, g_ptr_array_unref);
    g_clear_pointer(&read_aloud.favorite_ranks, g_array_unref);
    g_clear_pointer(&read_aloud.favorite_indices, g_array_unref);
    g_clear_object(&read_aloud.voices);
    g_clear_object(&read_aloud.favorite_names);
    reveal_cancel();
    configuration.callback = NULL;
    configuration.context = NULL;
    g_clear_pointer(&configuration.revision, g_free);
    g_clear_pointer(&configuration.rows, g_ptr_array_unref);
    g_clear_pointer(&configuration.choices, g_ptr_array_unref);
    g_clear_pointer(&configuration.booleans, g_array_unref);
    g_clear_pointer(&configuration.overlay_settings, g_array_unref);
    g_clear_pointer(&configuration.hands_free_settings, g_array_unref);
    configuration.recovery_group = NULL;
    configuration.recovery_row = NULL;
    configuration.recovery_count = 0;
    g_clear_pointer(&polish_page()->polish_catalog, g_ptr_array_unref);
    g_clear_pointer(&polish_page()->polish_slots, g_array_unref);
    g_clear_pointer(&polish_page()->polish_local_notice, g_free);
    g_clear_object(&ui.application);
    ui.window = NULL;
    jsti_app_icon_clear();
    if (status != 0) {
        jsti_set_error(error, capacity, "The window exited with status %d.", status);
        return -1;
    }
    return 0;
}
