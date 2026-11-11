#ifndef JSTI_WINDOWS_PRIVATE_STORAGE_H
#define JSTI_WINDOWS_PRIVATE_STORAGE_H
/* Credentials, private file staging and the recording registry. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Generic credentials scoped to this Windows user; names are automatically
 * prefixed with com.justspeaktoit/. Read: 1 missing, 2 buffer too small (required
 * byte count returned). No terminator is appended to credential bytes. */
int jsti_credential_write(const char *name, const uint8_t *bytes, size_t count,
                          char *error, size_t error_capacity);
int jsti_credential_read(const char *name, uint8_t *bytes, size_t capacity, size_t *count,
                         char *error, size_t error_capacity);
int jsti_credential_delete(const char *name, char *error, size_t error_capacity);

/* App-owned sensitive-file staging only. Absolute local paths; relative paths,
 * alternate data streams and all reparse points in the path are rejected.
 * Directory preparation creates/repairs only the supplied leaf directory; its
 * parent must exist and an existing leaf must belong to the current user.
 * Both APIs apply an explicit protected DACL granting only the current user
 * and SYSTEM full control. File creation is exclusive: existing files are
 * never opened, truncated or followed. No parent ACL is changed. */
int jsti_private_directory_prepare(const char *path, char *error, size_t error_capacity);
/* Exclusive private leaf creation, including explicit current-user ownership
 * when the process is elevated. An existing directory is never changed. */
int jsti_private_directory_create(const char *path, char *error, size_t error_capacity);
int jsti_private_file_create(const char *path, char *error, size_t error_capacity);
/* Opt-in held capture capability; not wired to the host/default Swift factory.
 * root must already exist. IDs must be UUID strings. Creation is exclusive in
 * a new private UUID directory and never repairs the caller-selected root.
 * Reuses private-staging ACLs and pinned, non-reparse ancestor traversal.
 * Calls must be serialized. Destroy exactly once, after close; destroy also
 * closes an abandoned capability, but never deletes retained audio.
 * Discard marks only the held file for deletion; directories are never removed.
 * Close is idempotent and reports teardown failures without retrying handles. */
typedef struct JSTIOwnedCaptureFile JSTIOwnedCaptureFile;
int jsti_owned_capture_file_create(const char *root, const char *directory_id, const char *recording_id,
                                   JSTIOwnedCaptureFile **result, char *error, size_t error_capacity);
int jsti_owned_capture_file_write(JSTIOwnedCaptureFile *file, const uint8_t *bytes, size_t count,
                                  char *error, size_t error_capacity);
int jsti_owned_capture_file_seek(JSTIOwnedCaptureFile *file, uint64_t offset,
                                 char *error, size_t error_capacity);
int jsti_owned_capture_file_flush(JSTIOwnedCaptureFile *file, char *error, size_t error_capacity);
int jsti_owned_capture_file_validate(JSTIOwnedCaptureFile *file, char *error, size_t error_capacity);
int jsti_owned_capture_file_discard(JSTIOwnedCaptureFile *file, char *error, size_t error_capacity);
int jsti_owned_capture_file_close(JSTIOwnedCaptureFile *file, char *error, size_t error_capacity);
void jsti_owned_capture_file_destroy(JSTIOwnedCaptureFile *file);
/* Native qualification fixture. Caller supplies an exclusively owned
 * test root; only new UUID children and synthetic bytes are used. */
int jsti_owned_capture_file_self_test(const char *root, char *error, size_t error_capacity);
/* Copies a private regular source into private destination-side staging, then
 * publishes exclusively. The source is retained. 0 committed, 2 cancelled
 * before commit, -1 failed, 3 committed with a handle-cleanup error (never
 * retry or delete that destination). Cancellation is checked between bounded chunks.
 * Existing destinations and reparse paths are never replaced or followed. */
typedef int (*jsti_file_publication_cancelled_fn)(void *context);
/* Opt-in private immutable recording namespace. Identity is native FILE_ID_INFO,
 * never a Foundation systemFileNumber conversion. initialize exclusively creates
 * the named namespace; open never repairs permissions or manufactures missing records.
 * append returns 0 success, 2 cancelled, -1 failure; published is set once rename
 * commits, including post-commit cancellation/close failure. Never retry/delete a
 * published leaf. Every writer is closed before append returns. Maximum leaf 16 KiB;
 * enumeration caps at 4096 NUL-terminated ASCII names. The verified provider must
 * enforce the aggregate byte/record budget and decode/bind records before granting authority.
 * Held directory sharing excludes a competing namespace capability and replacement;
 * callers serialize operations and do not close/destroy during another call. */
typedef struct JSTIRecordingRegistry JSTIRecordingRegistry;
int jsti_recording_registry_open(const char *history, int initialize, JSTIRecordingRegistry **result,
                                 char *error, size_t error_capacity);
int jsti_recording_registry_identity(JSTIRecordingRegistry *registry, uint64_t *history_volume,
                                     uint8_t *history_id16, uint64_t *namespace_volume, uint8_t *namespace_id16,
                                     char *error, size_t error_capacity);
int jsti_recording_registry_names(JSTIRecordingRegistry *registry, char *names, size_t names_capacity,
                                  size_t *written, uint32_t *count, char *error, size_t error_capacity);
int jsti_recording_registry_read(JSTIRecordingRegistry *registry, const char *name,
                                 uint8_t *bytes, size_t bytes_capacity, size_t *written,
                                 char *error, size_t error_capacity);
int jsti_recording_registry_append(JSTIRecordingRegistry *registry, const char *name,
                                   const uint8_t *bytes, size_t count,
                                   jsti_file_publication_cancelled_fn cancelled, void *context, int *published,
                                   char *error, size_t error_capacity);
int jsti_recording_registry_close(JSTIRecordingRegistry *registry, char *error, size_t error_capacity);
void jsti_recording_registry_destroy(JSTIRecordingRegistry *registry);
int jsti_recording_registry_self_test(const char *history, char *error, size_t error_capacity);
/* Qualification-only additive ABI. No shared POSIX identity conversion.
 * Caller supplies a writable outcome header (two uint32_t fields) describing
 * the entire available storage. Invalid version/size returns -1 without writes.
 * Valid outcomes preserve all causes; native codes are unsigned bit patterns.
 * Calls and destruction must be serialized; cancellation is synchronous and
 * borrowed. Close attempts are terminal even when native release is unconfirmed.
 * No published leaf is removed or retried. No raw native handle is exported. */
#define JSTI_REGISTRY_ABI_V2 2u
#define JSTI_REGISTRY_MAX_RESOURCES_V2 256u
#define JSTI_REGISTRY_MAX_CAUSES_V2 512u
#define JSTI_REGISTRY_MAX_LEAF_BYTES_V2 16384u
#define JSTI_REGISTRY_MAX_NAMES_V2 4096u
#define JSTI_REGISTRY_MAX_NAMES_BYTES_V2 262144u
#define JSTI_REGISTRY_MAX_PATH_UTF8_BYTES_V2 128000u
#define JSTI_REGISTRY_MAX_LEAF_NAME_BYTES_V2 64u
enum {
    JSTI_REGISTRY_DOMAIN_NONE_V2 = 0, JSTI_REGISTRY_DOMAIN_WIN32_V2 = 1,
    JSTI_REGISTRY_DOMAIN_NTSTATUS_V2 = 2, JSTI_REGISTRY_DOMAIN_HRESULT_V2 = 3,
    JSTI_REGISTRY_DOMAIN_CONTRACT_V2 = 4
};
enum { JSTI_REGISTRY_EFFECT_NOT_PUBLISHED_V2 = 0, JSTI_REGISTRY_EFFECT_PUBLISHED_V2 = 1 };
enum {
    JSTI_REGISTRY_CAUSE_PRIMARY_V2 = 1, JSTI_REGISTRY_CAUSE_SECONDARY_V2 = 2,
    JSTI_REGISTRY_CAUSE_CLEANUP_V2 = 3
};
enum {
    JSTI_REGISTRY_CONTRACT_INVALID_V2 = 1, JSTI_REGISTRY_CONTRACT_BUDGET_V2 = 2,
    JSTI_REGISTRY_CONTRACT_CLOSED_V2 = 3, JSTI_REGISTRY_CONTRACT_REENTRANT_V2 = 4,
    JSTI_REGISTRY_CONTRACT_CANCELLED_V2 = 5, JSTI_REGISTRY_CONTRACT_UNSUPPORTED_V2 = 6,
    JSTI_REGISTRY_CONTRACT_IDENTITY_V2 = 7, JSTI_REGISTRY_CONTRACT_CHANGED_V2 = 8,
    JSTI_REGISTRY_CONTRACT_TEARDOWN_UNCONFIRMED_V2 = 9, JSTI_REGISTRY_CONTRACT_ALLOCATION_V2 = 10
};
enum {
    JSTI_REGISTRY_STAGE_ADMISSION_V2 = 1, JSTI_REGISTRY_STAGE_OPEN_V2 = 2,
    JSTI_REGISTRY_STAGE_IDENTITY_V2 = 3, JSTI_REGISTRY_STAGE_ENUMERATE_V2 = 4,
    JSTI_REGISTRY_STAGE_READ_V2 = 5, JSTI_REGISTRY_STAGE_WRITE_V2 = 6,
    JSTI_REGISTRY_STAGE_READONLY_V2 = 7, JSTI_REGISTRY_STAGE_FLUSH_V2 = 8,
    JSTI_REGISTRY_STAGE_PRECOMMIT_V2 = 9, JSTI_REGISTRY_STAGE_PUBLISH_V2 = 10,
    JSTI_REGISTRY_STAGE_POSTCOMMIT_V2 = 11, JSTI_REGISTRY_STAGE_FENCE_ANCESTRY_V2 = 12,
    JSTI_REGISTRY_STAGE_FENCE_IDENTITY_V2 = 13, JSTI_REGISTRY_STAGE_FENCE_CONTENT_V2 = 14,
    JSTI_REGISTRY_STAGE_FENCE_ACL_V2 = 15, JSTI_REGISTRY_STAGE_FENCE_ATTRIBUTES_V2 = 16,
    JSTI_REGISTRY_STAGE_FENCE_LINKS_V2 = 17, JSTI_REGISTRY_STAGE_DISCARD_V2 = 18,
    JSTI_REGISTRY_STAGE_CLOSE_V2 = 19, JSTI_REGISTRY_STAGE_DESTROY_V2 = 20
};
enum {
    JSTI_REGISTRY_CHECK_ADMISSION_V2 = 1, JSTI_REGISTRY_CHECK_PRECOMMIT_V2 = 2,
    JSTI_REGISTRY_CHECK_POSTCOMMIT_V2 = 3
};
typedef struct { uint64_t volume_serial; uint8_t file_id[16]; } JSTIRegistryIdentityV2;
typedef struct {
    uint32_t kind, domain, native_code, stage;
    uint64_t resource_id;
} JSTIRegistryCauseV2;
typedef struct {
    uint32_t abi_version, struct_size, effect, cause_count, primary_index, cleanup_count;
    uint32_t close_attempt_count, release_unconfirmed_count, capability_poisoned;
    JSTIRegistryCauseV2 causes[JSTI_REGISTRY_MAX_CAUSES_V2];
} JSTIRegistryOutcomeV2;
typedef struct JSTIRecordingRegistryV2 JSTIRecordingRegistryV2;
typedef int (*jsti_registry_cancelled_v2_fn)(void *context, uint32_t checkpoint);
int jsti_recording_registry_open_v2(const uint8_t *history_utf8, size_t history_count, int initialize,
                                   JSTIRecordingRegistryV2 **result, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_identity_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryIdentityV2 *history,
                                       JSTIRegistryIdentityV2 *namespace_identity, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_names_v2(JSTIRecordingRegistryV2 *registry, uint8_t *names, size_t capacity,
                                    size_t *written, uint32_t *count, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_read_v2(JSTIRecordingRegistryV2 *registry, const uint8_t *name, size_t name_count,
                                   uint8_t *bytes, size_t capacity, size_t *written, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_append_v2(JSTIRecordingRegistryV2 *registry, const uint8_t *name, size_t name_count,
                                     const uint8_t *bytes, size_t count, jsti_registry_cancelled_v2_fn cancelled,
                                     void *context, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_validate_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_close_v2(JSTIRecordingRegistryV2 *registry, JSTIRegistryOutcomeV2 *outcome);
int jsti_recording_registry_destroy_v2(JSTIRecordingRegistryV2 **registry, JSTIRegistryOutcomeV2 *outcome);
int jsti_private_file_publish(const char *source, const char *destination,
                              jsti_file_publication_cancelled_fn cancelled, void *context,
                              char *error, size_t error_capacity);
/* Uses a unique temporary directory and synthetic bytes only; verifies ACLs,
 * directory repair, existing-file preservation and junction refusal. */
int jsti_private_storage_self_test(char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
