/* grub/err.h — minimal grub2fs shim: error codes + grub_error/grub_errno. */
#ifndef GRUB2FS_GRUB_ERR_H
#define GRUB2FS_GRUB_ERR_H

#include <grub/types.h>

/* Values/order match GRUB 2.12's include/grub/err.h for the codes the fs
 * drivers raise; the shim only ever compares against GRUB_ERR_NONE / passes the
 * code up, so the exact integer values are not load-bearing beyond NONE == 0. */
typedef enum
  {
    GRUB_ERR_NONE = 0,
    GRUB_ERR_OUT_OF_MEMORY,
    GRUB_ERR_BAD_FILE_TYPE,
    GRUB_ERR_FILE_NOT_FOUND,
    GRUB_ERR_BAD_FS,
    GRUB_ERR_BAD_NUMBER,
    GRUB_ERR_OUT_OF_RANGE,
    GRUB_ERR_READ_ERROR,
    GRUB_ERR_SYMLINK_LOOP,
    GRUB_ERR_BAD_FILENAME,
    GRUB_ERR_NOT_IMPLEMENTED_YET,
    GRUB_ERR_IO,
    GRUB_ERR_BAD_DEVICE,
    GRUB_ERR_EOF
  }
grub_err_t;

extern grub_err_t grub_errno;

/* Set grub_errno and return it. The message is formatted for debug builds and
 * otherwise ignored — the driver only uses the returned/stored CODE. */
grub_err_t grub_error (grub_err_t n, const char *fmt, ...)
  __attribute__ ((format (printf, 2, 3)));

void grub_error_push (void);
int grub_error_pop (void);

#endif /* GRUB2FS_GRUB_ERR_H */
