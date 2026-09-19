/* grub/mm.h — minimal grub2fs shim: heap. Maps to OpenBIOS malloc in the glue. */
#ifndef GRUB2FS_GRUB_MM_H
#define GRUB2FS_GRUB_MM_H

#include <grub/types.h>

void *grub_malloc (grub_size_t size);
void *grub_zalloc (grub_size_t size);
void *grub_calloc (grub_size_t n, grub_size_t size);
void *grub_realloc (void *ptr, grub_size_t size);
void  grub_free (void *ptr);

#endif /* GRUB2FS_GRUB_MM_H */
