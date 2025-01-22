#include <stddef.h>

#ifndef LFS_NO_MALLOC

#define LFS_MALLOC(sz) custom_lfs_malloc(sz)
#define LFS_FREE(sz) custom_lfs_free(sz)

extern void *custom_lfs_malloc( size_t size );

extern void custom_lfs_free( void *ptr );

#endif

extern int lfs_debug_printf(const char *format, ...);

#define LFS_DEBUG_(fmt, ...) \
    lfs_debug_printf("%s:%d:debug: " fmt "%s\n", __FILE__, __LINE__, __VA_ARGS__)
#define LFS_DEBUG(...) LFS_DEBUG_(__VA_ARGS__, "")