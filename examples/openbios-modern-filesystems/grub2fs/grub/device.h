/* grub/device.h — minimal grub2fs shim: a device is just its disk. */
#ifndef GRUB2FS_GRUB_DEVICE_H
#define GRUB2FS_GRUB_DEVICE_H

#include <grub/disk.h>

struct grub_device
{
  struct grub_disk *disk;
  void *net;   /* unused by the fs drivers; kept for layout parity */
};
typedef struct grub_device *grub_device_t;

#endif /* GRUB2FS_GRUB_DEVICE_H */
