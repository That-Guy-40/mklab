/* grub2fs.h — shared internals between the grub2fs package and its glue.
 *
 * The disk private block hangs off grub_disk->data: the OpenBIOS device fd the
 * package opened with open_ih(my_parent()), plus a byte offset added to every
 * read (nonzero only when probing a partition). grub_disk_read (glue) reads it;
 * the package (grub2fs_fs.c) fills it in at open/probe. */
#ifndef GRUB2FS_INTERNAL_H
#define GRUB2FS_INTERNAL_H

#include <grub/dl.h>

struct grub2fs_disk_priv
{
  int       fd;
  long long offset;
};

/* Populate grub_fs_list. Each vendored driver's GRUB_MOD_INIT(name) expands (via
 * the shim's grub/dl.h) to grub_<name>_init(grub_dl_t); the package calls them
 * once at registration, exactly as grubfs's fsys_table is a compile-time list. */
void grub_ext2_init (grub_dl_t mod);

/* package registration entry point, called from packages/init.c */
void grub2fs_init (void);

#endif /* GRUB2FS_INTERNAL_H */
