#include "bzlib_private.h"
#include "CBZip2.h"

/* Required by upstream libbz2 when BZ_NO_STDIO is defined. Its AssertH sites
 * on the decompression path are unreachable states; record them so the
 * caller fails the archive, and never exit the application. */
static _Thread_local int lastInternalError = 0;

void bz_internal_error(int errcode) {
    lastInternalError = errcode ? errcode : -1;
}

int jsti_bzip2_take_internal_error(void) {
    const int value = lastInternalError;
    lastInternalError = 0;
    return value;
}
