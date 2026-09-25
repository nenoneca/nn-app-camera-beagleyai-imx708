/* SPDX-License-Identifier: Apache-2.0 */
/* strlcpy for the cross build.  glibc only gained strlcpy in 2.38; the
 * cross toolchain here is 2.35, so linking would fail even though the
 * TARGET (2.41) has it.  Providing it locally keeps the build independent
 * of both libc versions. */
#include <stddef.h>
#include <string.h>

size_t strlcpy(char *dst, const char *src, size_t size);
size_t strlcpy(char *dst, const char *src, size_t size)
{
    size_t len = strlen(src);
    if (size) {
        size_t n = len < size - 1 ? len : size - 1;
        memcpy(dst, src, n);
        dst[n] = '\0';
    }
    return len;
}
