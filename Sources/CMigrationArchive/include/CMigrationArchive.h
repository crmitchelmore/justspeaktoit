#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct jsti_zip_reader jsti_zip_reader;
typedef struct jsti_zip_writer jsti_zip_writer;
typedef size_t (*jsti_zip_read)(void *, uint64_t, void *, size_t);
typedef size_t (*jsti_zip_consume)(void *, uint64_t, const void *, size_t);

typedef struct {
    uint64_t uncompressed_bytes;
    uint32_t checksum;
    uint32_t filename_bytes;
    int regular_file;
} jsti_zip_entry;

jsti_zip_reader *jsti_zip_open(uint64_t size, jsti_zip_read read, void *context,
                              size_t index_budget, uint32_t maximum_entries, char *error, size_t error_size);
uint32_t jsti_zip_count(jsti_zip_reader *reader);
int jsti_zip_stat(jsti_zip_reader *reader, uint32_t index, jsti_zip_entry *entry);
uint32_t jsti_zip_filename(jsti_zip_reader *reader, uint32_t index, char *buffer, uint32_t capacity);
int jsti_zip_extract(jsti_zip_reader *reader, uint32_t index, jsti_zip_consume consume, void *context);
const char *jsti_zip_error(jsti_zip_reader *reader);
void jsti_zip_close(jsti_zip_reader *reader);

jsti_zip_writer *jsti_zip_writer_open(jsti_zip_consume write, void *context, size_t index_budget,
                                     uint32_t maximum_entries, char *error, size_t error_size);
int jsti_zip_writer_add_memory(jsti_zip_writer *writer, const char *path, const void *data, size_t bytes);
int jsti_zip_writer_add_file(jsti_zip_writer *writer, const char *path, uint64_t bytes,
                            jsti_zip_read read, void *context);
int jsti_zip_writer_finalize(jsti_zip_writer *writer);
const char *jsti_zip_writer_error(jsti_zip_writer *writer);
void jsti_zip_writer_close(jsti_zip_writer *writer);

#ifdef __cplusplus
}
#endif
