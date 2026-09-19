/* grub/safemath.h — minimal grub2fs shim: overflow-checked arithmetic.
 * Each returns true on overflow and stores the result via *res (GCC builtins,
 * exactly as GRUB 2.12's own header does). */
#ifndef GRUB2FS_GRUB_SAFEMATH_H
#define GRUB2FS_GRUB_SAFEMATH_H

#define grub_add(a, b, res) __builtin_add_overflow ((a), (b), (res))
#define grub_sub(a, b, res) __builtin_sub_overflow ((a), (b), (res))
#define grub_mul(a, b, res) __builtin_mul_overflow ((a), (b), (res))

#define grub_cast(value, res) grub_add ((value), 0, (res))

#endif /* GRUB2FS_GRUB_SAFEMATH_H */
