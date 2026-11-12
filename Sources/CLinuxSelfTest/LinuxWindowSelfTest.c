/*
 * The window self-test (jsti_window_self_test): runs each page's checks, kept in
 * that page's LinuxWindow*SelfTest.c, in a fixed order, plus the About and icon
 * checks. SpeakLinux links this target, so CI and the desktop checks still run
 * it inside the shipped binary.
 */
#include "LinuxWindowSelfTestInternal.h"
#include "../CLinuxSupport/LinuxWindowAboutState.h"

/* ---------------------------------------------------------- self-test */

ObservedEvent observed;

void observe_event(gint32 event, const char *text, gint32 index, void *context) {
    (void)context;
    observed.event = event;
    g_free(observed.text);
    observed.text = g_strdup(text);
    observed.index = index;
}

static int32_t about_self_test(char *error, size_t capacity) {
    const JSTIAboutLink invalid_about_link = {"Invalid", "file:///not-an-update"};
    if (about_page()->about_details == NULL || about_page()->about_links == NULL ||
        strstr(gtk_label_get_text(about_page()->about_details), "Version:") == NULL ||
        jsti_window_configure_about("bad", NULL, 0) != -1 ||
        jsti_window_configure_about("bad", &invalid_about_link, 1) != -1 ||
        jsti_window_configure_about("\xff", &invalid_about_link, 1) != -1)
        return fail(error, capacity, "About metadata or invalid input refusal failed");
    guint about_count = 0;
    for (GtkWidget *child = gtk_widget_get_first_child(GTK_WIDGET(about_page()->about_links));
         child != NULL; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *button = gtk_flow_box_child_get_child(GTK_FLOW_BOX_CHILD(child));
        const char *uri = g_object_get_data(G_OBJECT(button), "about-uri");
        if (!GTK_IS_BUTTON(button) || uri == NULL || !g_str_has_prefix(uri, "https://"))
            return fail(error, capacity, "About link label or destination was not preserved");
        ++about_count;
    }
    if (about_count != 6) return fail(error, capacity, "About canonical links are missing");
    return 0;
}

int32_t jsti_window_self_test(char *error, size_t capacity) {
    if (jsti_hands_free_guard_self_test(error, capacity) != 0) return -1;
    if (jsti_desktop_palette_self_test(error, capacity) != 0) return -1;
    if (ui.window == NULL) return fail(error, capacity, "the window was not created");
    if (jsti_issue_report_self_test(error, capacity) != 0) return -1;
    if (about_self_test(error, capacity) != 0) return -1;
    if (!cleanup_preview_self_test())
        return fail(error, capacity, "cleanup preview bounds, coalescing, navigation or retirement failed");
    if (local_cleanup_sources_self_test(error, capacity) != 0) return -1;
    if (jsti_visual_density_self_test(GTK_WIDGET(ui.window)) != 0)
        return fail(error, capacity, "layout density geometry, Normal restoration or editing focus failed");
    if (!sidebar_navigation_self_test())
        return fail(error, capacity, "sidebar hints, focus guards or window-local navigation failed");
    if (jsti_action_shortcuts_self_test(error, capacity) != 0) return -1;
    if (jsti_action_shortcut_editor_self_test(ui.window, error, capacity) != 0) return -1;
    if (!action_execution_self_test())
        return fail(error, capacity, "action shortcut native page, event, slot or sensitivity routing failed");
    if (!command_forwarding_self_test())
        return fail(error, capacity, "desktop-bound command parsing, dispatch or lifetime admission failed");
    if (!command_process_self_test(error, capacity)) return -1;
    if (!post_processing_self_test())
        return fail(error, capacity, "Local/Remote post-processing controls, key isolation or callback indexes failed");
    if (storage_self_test(error, capacity) != 0) return -1;
    if (!configuration_self_test())
        return fail(error, capacity, "configuration rows did not populate and emit a complete Apply");
    if (!configuration_reveal_self_test())
        return fail(error, capacity, "settings search did not refuse an unknown field or highlight a known one");
    if (jsti_settings_search_self_test(error, capacity) != 0) return -1;
    if (!text_output_self_test())
        return fail(error, capacity, "clipboard restoration did not follow the session capability and saved choice");
    if (!page_functions_self_test())
        return fail(error, capacity, "a page's functions disagree with the state it keeps to itself");
    const char *icon_name = gtk_window_get_icon_name(ui.window);
    GtkIconTheme *theme = gtk_icon_theme_get_for_display(gtk_widget_get_display(GTK_WIDGET(ui.window)));
    if (g_strcmp0(icon_name, "com.justspeaktoit.JustSpeakToIt") != 0 ||
        !gtk_icon_theme_has_icon(theme, "com.justspeaktoit.JustSpeakToIt")) {
        return fail(error, capacity, "the canonical application icon is not available in the window's theme");
    }
    if (login_item_self_test(error, capacity) != 0) return -1;
    if (automation_self_test(error, capacity) != 0) return -1;
    if (model_picker_self_test(error, capacity) != 0) return -1;
    if (jsti_local_models_self_test(error, capacity) != 0) return -1;
    if (jsti_model_filters_self_test(error, capacity) != 0) return -1;
    if (!model_modes_self_test())
        return fail(error, capacity, "Model picker did not isolate and restore all four Source/Mode choices");
    if (jsti_cloud_sync_self_test(error, capacity) != 0) return -1;
    if (jsti_system_resources_self_test(error, capacity) != 0) return -1;
    if (jsti_history_filters_self_test(error, capacity) != 0) return -1;
    if (jsti_vocabulary_self_test(error, capacity) != 0) return -1;
    if (jsti_profiles_self_test(error, capacity) != 0) return -1;
    if (jsti_troubleshooting_self_test(ui.window, error, capacity) != 0) return -1;
    if (jsti_api_keys_self_test(ui.window, error, capacity) != 0) return -1;
    if (jsti_permissions_self_test(ui.window, error, capacity) != 0) return -1;
    if (jsti_setup_self_test(ui.window, error, capacity) != 0) return -1;
    if (!cancel_key_self_test()) return fail(error, capacity, "Escape cancellation ownership or repeat guards failed");
    if (polish_prompt_self_test(error, capacity) != 0) return -1;
    if (history_records_self_test(error, capacity) != 0) return -1;
    for (gint32 page = JSTI_PAGE_COUNT - 1; page >= 0; page--) {
        show_page(page);
        if (g_strcmp0(gtk_stack_get_visible_child_name(ui.pages), page_name(page)) != 0
            || gtk_list_box_row_get_index(gtk_list_box_get_selected_row(ui.sidebar)) != page) {
            return fail(error, capacity, "a sidebar page could not be shown");
        }
    }
    if (history_presentation_self_test(error, capacity) != 0) return -1;
    if (read_aloud_self_test(SELF_TEST_FIRST_RECORD, error, capacity) != 0) return -1;
    if (voice_favorites_self_test(error, capacity) != 0) return -1;
    if (jsti_voice_credentials_self_test(error, capacity) != 0) return -1;
    if (jsti_voice_sources_self_test(ui.window, error, capacity) != 0) return -1;
    if (history_clear_self_test(error, capacity) != 0) return -1;
    if (gtk_accessible_get_accessible_role(GTK_ACCESSIBLE(ui.status)) != GTK_ACCESSIBLE_ROLE_STATUS)
        return fail(error, capacity, "the window status lost its accessible status role");
    if (jsti_hud_self_test(error, capacity) != 0) return -1;
    if (jsti_comparison_self_test(ui.window, error, capacity) != 0) return -1;
    return jsti_tray_self_test(error, capacity);
}
