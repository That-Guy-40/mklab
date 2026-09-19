/* grub/fs.h — minimal grub2fs shim: the grub_fs vtable + registration.
 *
 * grub_fs_register pushes onto a singly-linked grub_fs_list (glue); the shim's
 * package `open` walks that list and calls each fs->fs_open, exactly as OpenBIOS
 * grubfs walks fsys_table[]. */
#ifndef GRUB2FS_GRUB_FS_H
#define GRUB2FS_GRUB_FS_H

#include <grub/types.h>
#include <grub/err.h>
#include <grub/device.h>

/* grub_file is completed by grub/file.h, which includes THIS header (mirrors
 * GRUB: file.h pulls in fs.h). fs_open/fs_read take a pointer, so a forward
 * declaration is enough here and breaks the include cycle. */
struct grub_file;

struct grub_dirhook_info
{
  unsigned dir:1;
  unsigned mtimeset:1;
  unsigned case_insensitive:1;
  unsigned inodeset:1;
  grub_int64_t mtime;
  grub_uint64_t inode;
};

typedef int (*grub_fs_dir_hook_t) (const char *filename,
				   const struct grub_dirhook_info *info,
				   void *data);

struct grub_fs
{
  struct grub_fs *next;
  struct grub_fs **prev;
  const char *name;

  grub_err_t (*fs_dir) (grub_device_t device, const char *path,
			grub_fs_dir_hook_t hook, void *hook_data);
  grub_err_t (*fs_open) (struct grub_file *file, const char *name);
  grub_ssize_t (*fs_read) (struct grub_file *file, char *buf, grub_size_t len);
  grub_err_t (*fs_close) (struct grub_file *file);
  grub_err_t (*fs_label) (grub_device_t device, char **label);
  grub_err_t (*fs_uuid) (grub_device_t device, char **uuid);
  grub_err_t (*fs_mtime) (grub_device_t device, grub_int64_t *timebuf);
  /* GRUB_UTIL-only embed fields are omitted (never compiled here). */
};
typedef struct grub_fs *grub_fs_t;

extern grub_fs_t grub_fs_list;

void grub_fs_register (grub_fs_t fs);
void grub_fs_unregister (grub_fs_t fs);

#endif /* GRUB2FS_GRUB_FS_H */
