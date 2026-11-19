#include <stddef.h>

// iOS 10.3 SDK .tbd exports fortified ___memcpy_chk / ___memmove_chk / ___memset_chk
// in libsystem_c.dylib; provide thin shims for clang-emitted unfortified builtins.
extern void *__memcpy_chk(void *dst, const void *src, size_t len, size_t dstlen);
extern void *__memmove_chk(void *dst, const void *src, size_t len, size_t dstlen);
extern void *__memset_chk(void *dst, int c, size_t len, size_t dstlen);

__attribute__((visibility("hidden")))
void *memcpy(void *dst, const void *src, size_t len) {
    return __memcpy_chk(dst, src, len, (size_t)-1);
}

__attribute__((visibility("hidden")))
void *memmove(void *dst, const void *src, size_t len) {
    return __memmove_chk(dst, src, len, (size_t)-1);
}

__attribute__((visibility("hidden")))
void *memset(void *dst, int c, size_t len) {
    return __memset_chk(dst, c, len, (size_t)-1);
}

__attribute__((visibility("hidden")))
void bzero(void *dst, size_t len) {
    __memset_chk(dst, 0, len, (size_t)-1);
}
