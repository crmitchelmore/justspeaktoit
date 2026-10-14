#include "include/CMigrationArchive.h"
#include "miniz/miniz.h"
#include <stdio.h>

typedef union {
    size_t size;
    long double alignment;
    void *pointer;
} allocation_header;

typedef struct {
    size_t allocated;
    size_t budget;
    int limit_exceeded;
} allocation_budget;

struct jsti_zip_reader {
    mz_zip_archive archive;
    allocation_budget memory;
};

struct jsti_zip_writer {
    mz_zip_archive archive;
    allocation_budget memory;
    uint32_t maximum_entries;
    const char *failure;
};

static void *allocate(void *opaque, size_t items, size_t size) {
    allocation_budget *reader = opaque;
    if (size != 0 && items > SIZE_MAX / size) {
        reader->limit_exceeded = 1;
        return NULL;
    }
    size_t bytes = items * size;
    if (bytes > reader->budget - reader->allocated || bytes > SIZE_MAX - sizeof(allocation_header)) {
        reader->limit_exceeded = 1;
        return NULL;
    }
    allocation_header *header = malloc(sizeof(*header) + bytes);
    if (!header) return NULL;
    header->size = bytes;
    reader->allocated += bytes;
    return header + 1;
}

static void release(void *opaque, void *address) {
    if (!address) return;
    allocation_budget *reader = opaque;
    allocation_header *header = (allocation_header *)address - 1;
    reader->allocated -= header->size;
    free(header);
}

static void *resize(void *opaque, void *address, size_t items, size_t size) {
    if (!address) return allocate(opaque, items, size);
    allocation_budget *reader = opaque;
    allocation_header *header = (allocation_header *)address - 1;
    if (size != 0 && items > SIZE_MAX / size) {
        reader->limit_exceeded = 1;
        return NULL;
    }
    size_t bytes = items * size;
    size_t other = reader->allocated - header->size;
    if (bytes > reader->budget - other || bytes > SIZE_MAX - sizeof(*header)) {
        reader->limit_exceeded = 1;
        return NULL;
    }
    allocation_header *next = realloc(header, sizeof(*header) + bytes);
    if (!next) return NULL;
    next->size = bytes;
    reader->allocated = other + bytes;
    return next + 1;
}

const char *jsti_zip_error(jsti_zip_reader *reader) {
    if (reader->memory.limit_exceeded) return "The ZIP index exceeds the bounded memory budget.";
    return mz_zip_get_error_string(mz_zip_peek_last_error(&reader->archive));
}

void jsti_zip_close(jsti_zip_reader *reader) {
    if (!reader) return;
    if (reader->archive.m_pState) mz_zip_reader_end(&reader->archive);
    free(reader);
}

jsti_zip_reader *jsti_zip_open(uint64_t size, jsti_zip_read read, void *context,
                              size_t index_budget, uint32_t maximum_entries, char *error, size_t error_size) {
    jsti_zip_reader *reader = calloc(1, sizeof(*reader));
    if (!reader) {
        if (error && error_size) snprintf(error, error_size, "Could not allocate a ZIP reader.");
        return NULL;
    }
    reader->memory.budget = index_budget;
    reader->archive.m_pAlloc = allocate;
    reader->archive.m_pFree = release;
    reader->archive.m_pRealloc = resize;
    reader->archive.m_pAlloc_opaque = &reader->memory;
    reader->archive.m_pRead = read;
    reader->archive.m_pIO_opaque = context;
    if (!mz_zip_reader_init(&reader->archive, size, MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY)) {
        if (error && error_size) snprintf(error, error_size, "%s", jsti_zip_error(reader));
        jsti_zip_close(reader);
        return NULL;
    }
    if (reader->archive.m_total_files > maximum_entries) {
        if (error && error_size) snprintf(error, error_size, "The ZIP contains too many entries.");
        jsti_zip_close(reader);
        return NULL;
    }
    return reader;
}

uint32_t jsti_zip_count(jsti_zip_reader *reader) {
    return mz_zip_reader_get_num_files(&reader->archive);
}

int jsti_zip_stat(jsti_zip_reader *reader, uint32_t index, jsti_zip_entry *entry) {
    mz_zip_archive_file_stat stat;
    if (!mz_zip_reader_file_stat(&reader->archive, index, &stat)) return 0;
    entry->uncompressed_bytes = stat.m_uncomp_size;
    entry->checksum = stat.m_crc32;
    entry->filename_bytes = mz_zip_reader_get_filename(&reader->archive, index, NULL, 0);
    unsigned type = (stat.m_external_attr >> 16) & 0170000;
    entry->regular_file = !stat.m_is_directory && !stat.m_is_encrypted && stat.m_is_supported
        && (type == 0 || type == 0100000);
    return 1;
}

uint32_t jsti_zip_filename(jsti_zip_reader *reader, uint32_t index, char *buffer, uint32_t capacity) {
    return mz_zip_reader_get_filename(&reader->archive, index, buffer, capacity);
}

int jsti_zip_extract(jsti_zip_reader *reader, uint32_t index, jsti_zip_consume consume, void *context) {
    return mz_zip_reader_extract_to_callback(&reader->archive, index, consume, context, 0);
}

const char *jsti_zip_writer_error(jsti_zip_writer *writer) {
    if (writer->memory.limit_exceeded) return "The ZIP writer exceeds the bounded memory budget.";
    if (writer->failure) return writer->failure;
    return mz_zip_get_error_string(mz_zip_peek_last_error(&writer->archive));
}

void jsti_zip_writer_close(jsti_zip_writer *writer) {
    if (!writer) return;
    if (writer->archive.m_pState) mz_zip_writer_end(&writer->archive);
    free(writer);
}

jsti_zip_writer *jsti_zip_writer_open(jsti_zip_consume write, void *context, size_t index_budget,
                                     uint32_t maximum_entries, char *error, size_t error_size) {
    jsti_zip_writer *writer = calloc(1, sizeof(*writer));
    if (!writer) {
        if (error && error_size) snprintf(error, error_size, "Could not allocate a ZIP writer.");
        return NULL;
    }
    writer->memory.budget = index_budget;
    writer->maximum_entries = maximum_entries;
    writer->archive.m_pAlloc = allocate;
    writer->archive.m_pFree = release;
    writer->archive.m_pRealloc = resize;
    writer->archive.m_pAlloc_opaque = &writer->memory;
    writer->archive.m_pWrite = write;
    writer->archive.m_pIO_opaque = context;
    if (!mz_zip_writer_init_v2(&writer->archive, 0, MZ_ZIP_FLAG_WRITE_ZIP64)) {
        if (error && error_size) snprintf(error, error_size, "%s", jsti_zip_writer_error(writer));
        jsti_zip_writer_close(writer);
        return NULL;
    }
    return writer;
}

static int writer_accepts(jsti_zip_writer *writer, const char *path) {
    if (writer->failure) return 0;
    if (!path || !*path || strlen(path) > UINT16_MAX) {
        writer->failure = "Invalid ZIP export entry name.";
        return 0;
    }
    if (writer->archive.m_total_files >= writer->maximum_entries) {
        writer->failure = "The ZIP export contains too many entries.";
        return 0;
    }
    return 1;
}

int jsti_zip_writer_add_memory(jsti_zip_writer *writer, const char *path, const void *data, size_t bytes) {
    if (!writer_accepts(writer, path)) return 0;
    return mz_zip_writer_add_mem(&writer->archive, path, data, bytes, 0);
}

int jsti_zip_writer_add_file(jsti_zip_writer *writer, const char *path, uint64_t bytes,
                            jsti_zip_read read, void *context) {
    if (!writer_accepts(writer, path)) return 0;
    return mz_zip_writer_add_read_buf_callback(
        &writer->archive, path, read, context, bytes, NULL, NULL, 0, 0, NULL, 0, NULL, 0);
}

int jsti_zip_writer_finalize(jsti_zip_writer *writer) {
    if (writer->failure) return 0;
    return mz_zip_writer_finalize_archive(&writer->archive);
}
