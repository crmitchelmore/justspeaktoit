#ifndef JSTI_C_LLAMA_CPP_H
#define JSTI_C_LLAMA_CPP_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct JSTILlamaRun JSTILlamaRun;
/* The verifier sees the immutable snapshot that llama.cpp will load. */
typedef int32_t (*JSTILlamaVerify)(const uint8_t *, size_t, void *);
JSTILlamaRun *jsti_llama_run_create(void);
void jsti_llama_run_cancel(JSTILlamaRun *);
int32_t jsti_llama_run_is_cancelled(JSTILlamaRun *);
void jsti_llama_run_destroy(JSTILlamaRun *);
/* All paths are absolute UTF-8. library must be a privately provisioned b6500
   monolithic CPU runtime, verified by the host before entry. 2 = cancelled.
   No callbacks or native resources survive this synchronous call. */
int32_t jsti_llama_run_complete(
    JSTILlamaRun *, const char *library, const char *model, int64_t model_bytes,
    JSTILlamaVerify, void *verify_context, const char *system_prompt, const char *user_prompt,
    double temperature, char **output, char *error, size_t error_capacity);
void jsti_llama_string_free(char *);
#ifdef __cplusplus
}
#endif
#endif
