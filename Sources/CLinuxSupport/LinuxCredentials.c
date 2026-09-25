#include "LinuxSupportInternal.h"

#include <libsecret/secret.h>
#include <string.h>

/* One schema for every provider key. The attribute is the canonical
 * credential identifier shared with Windows Credential Manager and the Apple
 * keychain, so each provider has exactly one saved key per user. */
static const SecretSchema *credential_schema(void) {
    static const SecretSchema schema = {
        "com.justspeaktoit.Credential",
        SECRET_SCHEMA_NONE,
        {
            { "identifier", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        },
        0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    };
    return &schema;
}

static int32_t report(GError *failure, const char *action, char *error, size_t capacity) {
    jsti_set_error(
        error, capacity, "Could not %s the API key in the Secret Service keyring: %s", action,
        failure != NULL ? failure->message : "unknown error");
    g_clear_error(&failure);
    return -1;
}

int32_t jsti_credential_read(
    const char *name, uint8_t *buffer, size_t capacity, size_t *count, char *error, size_t error_capacity) {
    GError *failure = NULL;
    *count = 0;
    SecretValue *value = secret_password_lookup_binary_sync(
        credential_schema(), NULL, &failure, "identifier", name, NULL);
    if (failure != NULL) return report(failure, "read", error, error_capacity);
    if (value == NULL) return 1;
    gsize length = 0;
    const gchar *bytes = secret_value_get(value, &length);
    if (length > capacity) {
        secret_value_unref(value);
        jsti_set_error(error, error_capacity, "The saved API key is too long. Save it again.");
        return -1;
    }
    memcpy(buffer, bytes, length);
    *count = length;
    secret_value_unref(value);
    return 0;
}

int32_t jsti_credential_write(
    const char *name, const uint8_t *bytes, size_t count, char *error, size_t error_capacity) {
    GError *failure = NULL;
    SecretValue *value = secret_value_new((const gchar *)bytes, (gssize)count, "text/plain");
    gchar *label = g_strdup_printf("JustSpeakToIt: %s", name);
    gboolean stored = secret_password_store_binary_sync(
        credential_schema(), SECRET_COLLECTION_DEFAULT, label, value, NULL, &failure, "identifier", name, NULL);
    g_free(label);
    secret_value_unref(value);
    if (!stored) return report(failure, "save", error, error_capacity);
    return 0;
}

int32_t jsti_credential_delete(const char *name, char *error, size_t error_capacity) {
    GError *failure = NULL;
    secret_password_clear_sync(credential_schema(), NULL, &failure, "identifier", name, NULL);
    if (failure != NULL) return report(failure, "remove", error, error_capacity);
    return 0;
}
