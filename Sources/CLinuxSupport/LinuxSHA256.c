#include "LinuxSupportInternal.h"

#include <string.h>

/* Streaming SHA-256 through GLib's GChecksum, which the adapter already links,
 * for verifying downloaded models. Never logs input bytes. */

struct JSTISHA256 {
    GChecksum *checksum;
};

JSTISHA256 *jsti_sha256_create(char *error, size_t capacity) {
    GChecksum *checksum = g_checksum_new(G_CHECKSUM_SHA256);
    if (checksum == NULL) {
        jsti_set_error(error, capacity, "GLib has no SHA-256 implementation.");
        return NULL;
    }
    JSTISHA256 *hasher = g_new0(JSTISHA256, 1);
    hasher->checksum = checksum;
    return hasher;
}

int32_t jsti_sha256_update(JSTISHA256 *hasher, const void *bytes, size_t count, char *error, size_t capacity) {
    if (hasher == NULL || hasher->checksum == NULL || (count > 0 && bytes == NULL)) {
        jsti_set_error(error, capacity, "The SHA-256 digest was used after it finished.");
        return -1;
    }
    /* g_checksum_update takes a signed length. */
    const guchar *cursor = bytes;
    while (count > 0) {
        size_t chunk = MIN(count, (size_t)1 << 30);
        g_checksum_update(hasher->checksum, cursor, (gssize)chunk);
        cursor += chunk;
        count -= chunk;
    }
    return 0;
}

int32_t jsti_sha256_finish(JSTISHA256 *hasher, char *hex, size_t hex_capacity, char *error, size_t capacity) {
    if (hasher == NULL || hasher->checksum == NULL || hex == NULL || hex_capacity < 65) {
        jsti_set_error(error, capacity, "The SHA-256 digest was used after it finished.");
        return -1;
    }
    const gchar *digest = g_checksum_get_string(hasher->checksum);
    int32_t status = 0;
    if (digest == NULL || strlen(digest) != 64) {
        jsti_set_error(error, capacity, "GLib returned an invalid SHA-256 digest.");
        status = -1;
    } else {
        memcpy(hex, digest, 65);
    }
    g_clear_pointer(&hasher->checksum, g_checksum_free);
    return status;
}

void jsti_sha256_destroy(JSTISHA256 *hasher) {
    if (hasher == NULL) return;
    g_clear_pointer(&hasher->checksum, g_checksum_free);
    g_free(hasher);
}
