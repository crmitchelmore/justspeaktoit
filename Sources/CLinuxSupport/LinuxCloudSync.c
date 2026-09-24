#include "LinuxSupportInternal.h"

#include <gio/gio.h>
#include <string.h>

/*
 * iCloud sync's desktop pieces: opening Apple's sign-in page in the default
 * browser. Swift runs the flow itself (DesktopHostCloudSync).
 */

static gboolean trusted_host(const char *host) {
    gchar *lower = g_ascii_strdown(host, -1);
    gboolean trusted = g_strcmp0(lower, "apple.com") == 0 || g_strcmp0(lower, "icloud.com") == 0 ||
        g_str_has_suffix(lower, ".apple.com") || g_str_has_suffix(lower, ".icloud.com");
    g_free(lower);
    return trusted;
}

/* Only an https page on apple.com or icloud.com, without credentials in it. */
static gboolean trusted_sign_in_page(const char *url) {
    GUri *uri = url != NULL ? g_uri_parse(url, G_URI_FLAGS_NONE, NULL) : NULL;
    if (uri == NULL) return FALSE;
    const char *scheme = g_uri_get_scheme(uri), *host = g_uri_get_host(uri);
    gboolean trusted = scheme != NULL && g_ascii_strcasecmp(scheme, "https") == 0 && g_uri_get_userinfo(uri) == NULL &&
        host != NULL && trusted_host(host);
    g_uri_unref(uri);
    return trusted;
}

int32_t jsti_open_sign_in_page(const char *url, char *error, size_t capacity) {
    if (!trusted_sign_in_page(url)) {
        jsti_set_error(error, capacity, "Only Apple's own sign-in page can be opened.");
        return -1;
    }
    /* Inside Flatpak GIO hands the page to the OpenURI portal. */
    GError *failure = NULL;
    if (!g_app_info_launch_default_for_uri(url, NULL, &failure)) {
        jsti_set_error(
            error, capacity, "The browser could not be opened for Apple ID sign-in: %s",
            failure != NULL ? failure->message : "no browser is set.");
        g_clear_error(&failure);
        return -1;
    }
    return 0;
}
