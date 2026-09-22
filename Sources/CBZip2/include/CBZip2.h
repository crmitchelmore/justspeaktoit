#ifndef JSTI_CBZIP2_H
#define JSTI_CBZIP2_H

/* Unmodified upstream libbz2 1.0.8 (see PROVENANCE.md), built without its
 * stdio file API. Only the core streaming decompression calls are used. */
#ifndef BZ_NO_STDIO
#define BZ_NO_STDIO 1
#endif
#include "bzlib.h"

#ifdef __cplusplus
extern "C" {
#endif

/* libbz2 reports impossible internal states through bz_internal_error when
 * built with BZ_NO_STDIO. This build records the code for the calling thread
 * instead of terminating the process. Returns and clears it (0 when none);
 * callers check it after every BZ2_bzDecompress call and fail the stream. */
int jsti_bzip2_take_internal_error(void);

#ifdef __cplusplus
}
#endif

#endif
