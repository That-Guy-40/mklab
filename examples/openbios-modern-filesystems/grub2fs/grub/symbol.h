/* grub/symbol.h — minimal grub2fs shim: no module symbol tables in a static
 * build, so the export decorations are identity. */
#ifndef GRUB2FS_GRUB_SYMBOL_H
#define GRUB2FS_GRUB_SYMBOL_H

#define EXPORT_FUNC(x) x
#define EXPORT_VAR(x)  x

#endif /* GRUB2FS_GRUB_SYMBOL_H */
