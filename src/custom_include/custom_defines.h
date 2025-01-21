#include <stddef.h>

#ifndef LFS_NO_MALLOC

#define LFS_MALLOC(sz) custom_lfs_malloc(sz)
#define LFS_FREE(sz) custom_lfs_free(sz)

extern void *custom_lfs_malloc( size_t size );

extern void custom_lfs_free( void *ptr );

#endif