/* grub/misc.h — minimal grub2fs shim: string/memory + formatted-alloc, plus a
 * no-op grub_dprintf. Implemented in the glue over OpenBIOS libc; declared here
 * so the vendored drivers compile. */
#ifndef GRUB2FS_GRUB_MISC_H
#define GRUB2FS_GRUB_MISC_H

#include <grub/types.h>
#include <grub/i18n.h>

void *grub_memcpy  (void *dest, const void *src, grub_size_t n);
void *grub_memmove (void *dest, const void *src, grub_size_t n);
void *grub_memset  (void *s, int c, grub_size_t n);
int   grub_memcmp  (const void *s1, const void *s2, grub_size_t n);

grub_size_t grub_strlen  (const char *s);
int   grub_strcmp   (const char *s1, const char *s2);
int   grub_strncmp  (const char *s1, const char *s2, grub_size_t n);
int   grub_strcasecmp (const char *s1, const char *s2);
char *grub_strcpy   (char *dest, const char *src);
char *grub_strchr   (const char *s, int c);
char *grub_strrchr  (const char *s, int c);
char *grub_strdup   (const char *s);
char *grub_strndup  (const char *s, grub_size_t n);

int   grub_tolower  (int c);
int   grub_toupper  (int c);
int   grub_isprint  (int c);

/* Allocate and format a string (used by the drivers on error/label paths). */
char *grub_xasprintf (const char *fmt, ...)
  __attribute__ ((format (printf, 1, 2)));

/* Debug tracing compiles to nothing in the shim. */
#define grub_dprintf(condition, ...) ((void) 0)

#endif /* GRUB2FS_GRUB_MISC_H */
