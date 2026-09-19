/* grub/dl.h — minimal grub2fs shim: module glue.
 *
 * There are no loadable modules in this static build: GRUB_MOD_INIT(name)
 * becomes a plain function grub_<name>_init() the shim calls once at
 * registration, the ref-counting is a no-op, and LICENSE/DEP/NAME vanish.
 */
#ifndef GRUB2FS_GRUB_DL_H
#define GRUB2FS_GRUB_DL_H

typedef struct grub_dl *grub_dl_t;

/* Emit a prototype before the definition so -Wmissing-prototypes (an error in
 * OpenBIOS's build) is satisfied for every driver's grub_<name>_init/fini. */
#define GRUB_MOD_INIT(name) \
  void grub_##name##_init (grub_dl_t mod); \
  void grub_##name##_init (grub_dl_t mod __attribute__ ((unused)))
#define GRUB_MOD_FINI(name) \
  void grub_##name##_fini (grub_dl_t mod); \
  void grub_##name##_fini (grub_dl_t mod __attribute__ ((unused)))

#define GRUB_MOD_LICENSE(license)
#define GRUB_MOD_DEP(name)
#define GRUB_MOD_NAME(name)

static inline void grub_dl_ref   (grub_dl_t mod __attribute__ ((unused))) { }
static inline void grub_dl_unref (grub_dl_t mod __attribute__ ((unused))) { }

#endif /* GRUB2FS_GRUB_DL_H */
