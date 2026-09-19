/* grub/types.h — minimal grub2fs shim: base types + byte order.
 *
 * Part of the grub2fs read shim (OpenBIOS modern-filesystems lab). This is NOT
 * GRUB's own header; it is a minimal adapter that provides exactly what the
 * vendored GRUB 2 fs drivers use — the same approach OpenBIOS's fs/grubfs/ takes
 * for the GRUB 0.97 drivers (its own filesys.h/fs.h, not GRUB's originals).
 *
 * The byte-order accessors are the four-arch control: every multi-byte on-disk
 * field is read through grub_le_to_cpuNN (little-endian ext4/FAT/ISO), so a
 * big-endian ppc reads the same value an x86 does — never the CPU's raw order.
 */
#ifndef GRUB2FS_GRUB_TYPES_H
#define GRUB2FS_GRUB_TYPES_H

typedef unsigned char       grub_uint8_t;
typedef signed char         grub_int8_t;
typedef unsigned short      grub_uint16_t;
typedef short               grub_int16_t;
typedef unsigned int        grub_uint32_t;
typedef int                 grub_int32_t;
typedef unsigned long long  grub_uint64_t;
typedef long long           grub_int64_t;

typedef __SIZE_TYPE__       grub_size_t;
typedef __PTRDIFF_TYPE__    grub_ssize_t;

typedef grub_uint64_t       grub_off_t;
typedef grub_uint64_t       grub_disk_addr_t;
typedef grub_uint64_t       grub_addr_t;

/* used by some drivers for alignment-safe scratch; harmless if unreferenced */
typedef grub_uint64_t       grub_properly_aligned_t;
#define GRUB_PROPERLY_ALIGNED_ARRAY(name, size) \
  grub_properly_aligned_t name[((size) + sizeof (grub_properly_aligned_t) - 1) \
                               / sizeof (grub_properly_aligned_t)]

#ifndef NULL
# define NULL ((void *) 0)
#endif

/* ── byte order ──────────────────────────────────────────────────────────
 * Runtime swaps (inline) and constant-expression swaps (macros, usable in
 * static initializers and case labels — that is what *_compile_time needs).
 */
static inline grub_uint16_t grub_swap_bytes16 (grub_uint16_t x)
{ return (grub_uint16_t) ((x << 8) | (x >> 8)); }
static inline grub_uint32_t grub_swap_bytes32 (grub_uint32_t x)
{ return __builtin_bswap32 (x); }
static inline grub_uint64_t grub_swap_bytes64 (grub_uint64_t x)
{ return __builtin_bswap64 (x); }

#define grub_swap_bytes16_c(x) \
  ((grub_uint16_t) ((((grub_uint16_t)(x) & 0xff) << 8) | (((grub_uint16_t)(x) >> 8) & 0xff)))
#define grub_swap_bytes32_c(x) \
  ((grub_uint32_t) ((((grub_uint32_t)(x) & 0x000000ffUL) << 24) \
                  | (((grub_uint32_t)(x) & 0x0000ff00UL) << 8)  \
                  | (((grub_uint32_t)(x) & 0x00ff0000UL) >> 8)  \
                  | (((grub_uint32_t)(x) & 0xff000000UL) >> 24)))

#if defined(__BYTE_ORDER__) && (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
/* big-endian target (ppc, sparc): LE fields need a swap, BE fields are native */
# define grub_le_to_cpu16(x) grub_swap_bytes16 (x)
# define grub_le_to_cpu32(x) grub_swap_bytes32 (x)
# define grub_le_to_cpu64(x) grub_swap_bytes64 (x)
# define grub_cpu_to_le16(x) grub_swap_bytes16 (x)
# define grub_cpu_to_le32(x) grub_swap_bytes32 (x)
# define grub_cpu_to_le64(x) grub_swap_bytes64 (x)
# define grub_cpu_to_le16_compile_time(x) grub_swap_bytes16_c (x)
# define grub_cpu_to_le32_compile_time(x) grub_swap_bytes32_c (x)
# define grub_be_to_cpu16(x) ((grub_uint16_t) (x))
# define grub_be_to_cpu32(x) ((grub_uint32_t) (x))
# define grub_be_to_cpu64(x) ((grub_uint64_t) (x))
#else
/* little-endian target (x86, amd64): LE fields are native, BE fields swap */
# define grub_le_to_cpu16(x) ((grub_uint16_t) (x))
# define grub_le_to_cpu32(x) ((grub_uint32_t) (x))
# define grub_le_to_cpu64(x) ((grub_uint64_t) (x))
# define grub_cpu_to_le16(x) ((grub_uint16_t) (x))
# define grub_cpu_to_le32(x) ((grub_uint32_t) (x))
# define grub_cpu_to_le64(x) ((grub_uint64_t) (x))
# define grub_cpu_to_le16_compile_time(x) ((grub_uint16_t) (x))
# define grub_cpu_to_le32_compile_time(x) ((grub_uint32_t) (x))
# define grub_be_to_cpu16(x) grub_swap_bytes16 (x)
# define grub_be_to_cpu32(x) grub_swap_bytes32 (x)
# define grub_be_to_cpu64(x) grub_swap_bytes64 (x)
#endif

/* ── unaligned accessors (POC-3: fat.c/iso9660.c read unaligned on-disk ints) ─
 * Structs + get accessors copied from GRUB 2.12 grub/types.h; a packed 1-field
 * struct is the portable "read a possibly-unaligned integer" idiom. */
#define GRUB_PACKED __attribute__ ((packed))

struct grub_unaligned_uint16 { grub_uint16_t val; } GRUB_PACKED;
struct grub_unaligned_uint32 { grub_uint32_t val; } GRUB_PACKED;
struct grub_unaligned_uint64 { grub_uint64_t val; } GRUB_PACKED;

static inline grub_uint16_t grub_get_unaligned16 (const void *ptr)
{ return ((const struct grub_unaligned_uint16 *) ptr)->val; }
static inline grub_uint32_t grub_get_unaligned32 (const void *ptr)
{ return ((const struct grub_unaligned_uint32 *) ptr)->val; }
static inline grub_uint64_t grub_get_unaligned64 (const void *ptr)
{ return ((const struct grub_unaligned_uint64 *) ptr)->val; }

#endif /* GRUB2FS_GRUB_TYPES_H */
