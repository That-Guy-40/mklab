/* grub/file.h — minimal grub2fs shim: per-file state (replaces GRUB 0.97's
 * filepos/filemax globals — this is the field set the drivers touch). */
#ifndef GRUB2FS_GRUB_FILE_H
#define GRUB2FS_GRUB_FILE_H

#include <grub/types.h>
#include <grub/device.h>
#include <grub/fs.h>   /* full grub_fs + grub_dirhook_info; drivers include only file.h */

struct grub_file
{
  char *name;
  grub_device_t device;
  grub_fs_t fs;
  grub_off_t offset;
  grub_off_t size;
  int not_easily_seekable;
  void *data;
  grub_disk_read_hook_t read_hook;
  void *read_hook_data;
};
typedef struct grub_file *grub_file_t;

#endif /* GRUB2FS_GRUB_FILE_H */
