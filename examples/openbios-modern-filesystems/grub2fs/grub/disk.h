/* grub/disk.h — minimal grub2fs shim: the one disk primitive.
 *
 * grub_disk_read(disk, sector, offset, size, buf) reads `size` bytes at
 * `sector * 512 + offset` from the parent device — byte-for-byte OpenBIOS's own
 * grubfs devread(), implemented in the glue over seek_io/read_io. The fd (and any
 * partition offset) live in disk->data. */
#ifndef GRUB2FS_GRUB_DISK_H
#define GRUB2FS_GRUB_DISK_H

#include <grub/types.h>
#include <grub/err.h>

#define GRUB_DISK_SECTOR_SIZE 0x200
#define GRUB_DISK_SECTOR_BITS 9

struct grub_disk;
typedef struct grub_disk *grub_disk_t;

/* Called once per covered sector during a read (progress/blocklist). Unused on
 * the plain file-read path — left NULL — but honored by the glue if set. */
typedef grub_err_t (*grub_disk_read_hook_t) (grub_disk_addr_t sector,
					     unsigned offset, unsigned length,
					     void *data);

struct grub_disk
{
  const char *name;
  grub_uint64_t total_sectors;
  unsigned int log_sector_size;
  grub_disk_read_hook_t read_hook;
  void *read_hook_data;
  /* grub2fs private: the OpenBIOS device fd + partition byte offset. */
  void *data;
};

grub_err_t grub_disk_read (grub_disk_t disk, grub_disk_addr_t sector,
			   grub_off_t offset, grub_size_t size, void *buf);

#endif /* GRUB2FS_GRUB_DISK_H */
