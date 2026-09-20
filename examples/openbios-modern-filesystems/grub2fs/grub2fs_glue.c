/*
 *	grub2fs — the grub_* environment the vendored GRUB 2 fs drivers call.
 *
 *	This is the "libgrub subset" half of the shim: the small set of grub_*
 *	symbols GRUB 2's ext2.c/fshelp.c reference, implemented over OpenBIOS's
 *	own libc + malloc + block I/O. The one that matters is grub_disk_read,
 *	which is byte-for-byte OpenBIOS grubfs's devread() with GRUB-2 argument
 *	names: read `size` bytes at `sector*512 + offset` on the parent device
 *	via seek_io/read_io. No new device code — the seam already existed.
 *
 *	Part of the openbios-modern-filesystems lab. GPLv2+ (OpenBIOS side); the
 *	drivers it serves are GPLv3+ and lab-only (see upstream-grub/README.md).
 */

#include "config.h"
#include "libopenbios/bindings.h"
#include "libc/diskio.h"
#include "libc/stdlib.h"
#include "libc/string.h"
#include "libc/vsprintf.h"

#include <grub/types.h>
#include <grub/err.h>
#include <grub/mm.h>
#include <grub/disk.h>
#include <grub/fs.h>
#include <grub/misc.h>

#include "grub2fs.h"

/************************************************************************/
/*	error								*/
/************************************************************************/

grub_err_t grub_errno;

grub_err_t
grub_error (grub_err_t n, const char *fmt __attribute__ ((unused)), ...)
{
	/* The drivers use the CODE (returned and stored); the message is only
	 * for humans and is dropped here, as the shim has no error string. */
	grub_errno = n;
	return n;
}

void grub_error_push (void) { }
int  grub_error_pop  (void) { return 0; }

/************************************************************************/
/*	heap — grub2fs owns its own							*/
/*									*/
/*	OpenBIOS's x86/amd64 malloc is a 128 KiB bump allocator with	*/
/*	free() a no-op and NO realloc (see arch/{x86,amd64}/lib.c). The	*/
/*	ext2 slice tolerated that (it never calls grub_realloc and its	*/
/*	frees are few), but fat.c/iso9660.c call realloc/calloc and free	*/
/*	heavily, so grub2fs needs a real allocator. This is a self-	*/
/*	contained first-fit free-list with coalescing, over a static 1	*/
/*	MiB arena — ample for FAT/ISO directory + FAT/extent-chain	*/
/*	buffers. (On a real ROM this is 1 MiB of BSS to budget; the	*/
/*	hosted openbios-unix used by the smoke pays nothing.)		*/
/*									*/
/*	EVERY grub_* allocator below (malloc/zalloc/realloc/calloc, and	*/
/*	the string dups + xasprintf) draws from THIS heap, because		*/
/*	grub_free is g2_free — mixing an OpenBIOS-malloc'd pointer with	*/
/*	g2_free would misread the header and corrupt the arena.		*/
/************************************************************************/

#define G2_HEAP_SIZE (1u << 20)          /* 1 MiB */
#define G2_ALIGN     16u

typedef struct g2_blk { grub_size_t size; struct g2_blk *next; int free; } g2_blk_t;

/* header size, rounded up to G2_ALIGN so payloads are aligned */
#define G2_HDR ((grub_size_t) ((sizeof (g2_blk_t) + G2_ALIGN - 1) & ~(grub_size_t) (G2_ALIGN - 1)))

/* Claimed from RAM at first use — NOT a static BSS array. A static G2_HEAP_SIZE
 * array is fine in the hosted openbios-unix process but OVERFLOWS a real firmware
 * ROM image: on ppc (mac99, a 1 MiB ROM — the S0 ceiling) POC-4's link failed with
 * ".bss VMA wraps around address space". RAM claimed post-boot fits any ROM. */
static unsigned char *g2_heap;
static g2_blk_t *g2_head;
static int g2_inited;

static grub_size_t g2_round (grub_size_t n)
{ return (n + G2_ALIGN - 1) & ~(grub_size_t) (G2_ALIGN - 1); }

static void g2_init (void)
{
	/* alloc-mem ( size -- addr ) returns a Forth address that is a usable C
	 * pointer in the firmware's own address space; by the first allocation (a
	 * `load`/mount at the prompt) the memory system is up. If the claim fails,
	 * g2_head stays NULL and g2_malloc returns NULL — the read fails cleanly. */
	g2_inited = 1;
	PUSH (G2_HEAP_SIZE);
	fword ("alloc-mem");
	g2_heap = (unsigned char *) cell2pointer (POP());
	if (!g2_heap)
		return;
	g2_head = (g2_blk_t *) g2_heap;
	g2_head->size = G2_HEAP_SIZE - G2_HDR;
	g2_head->next = NULL;
	g2_head->free = 1;
}

static void *
g2_malloc (grub_size_t size)
{
	g2_blk_t *b;
	if (!g2_inited)
		g2_init ();
	if (size == 0)
		size = 1;
	size = g2_round (size);
	for (b = g2_head; b; b = b->next) {
		if (!b->free || b->size < size)
			continue;
		/* split when the remainder can hold a header + a min payload */
		if (b->size >= size + G2_HDR + G2_ALIGN) {
			g2_blk_t *nb = (g2_blk_t *) ((unsigned char *) b + G2_HDR + size);
			nb->size = b->size - size - G2_HDR;
			nb->next = b->next;
			nb->free = 1;
			b->size = size;
			b->next = nb;
		}
		b->free = 0;
		return (unsigned char *) b + G2_HDR;
	}
	return NULL;   /* arena exhausted */
}

static void g2_coalesce (void)
{
	g2_blk_t *b = g2_head;
	while (b && b->next) {
		if (b->free && b->next->free) {
			b->size += G2_HDR + b->next->size;
			b->next = b->next->next;
		} else
			b = b->next;
	}
}

static void g2_free (void *p)
{
	if (!p)
		return;
	((g2_blk_t *) ((unsigned char *) p - G2_HDR))->free = 1;
	g2_coalesce ();
}

static void *
g2_realloc (void *p, grub_size_t size)
{
	g2_blk_t *b;
	grub_size_t want, copy;
	void *np;
	if (!p)
		return g2_malloc (size);
	if (size == 0) {
		g2_free (p);
		return NULL;
	}
	b = (g2_blk_t *) ((unsigned char *) p - G2_HDR);
	want = g2_round (size);
	if (b->size >= want)
		return p;                       /* shrink/keep in place */
	/* grow into an adjacent free block if it reaches */
	if (b->next && b->next->free && b->size + G2_HDR + b->next->size >= want) {
		b->size += G2_HDR + b->next->size;
		b->next = b->next->next;
		if (b->size >= want + G2_HDR + G2_ALIGN) {
			g2_blk_t *nb = (g2_blk_t *) ((unsigned char *) b + G2_HDR + want);
			nb->size = b->size - want - G2_HDR;
			nb->next = b->next;
			nb->free = 1;
			b->size = want;
			b->next = nb;
		}
		return p;
	}
	/* relocate: allocate, copy the old payload, free the old block */
	np = g2_malloc (size);
	if (!np)
		return NULL;
	copy = (b->size < size) ? b->size : size;
	memcpy (np, p, copy);
	g2_free (p);
	return np;
}

void *grub_malloc  (grub_size_t size)             { return g2_malloc (size); }
void  grub_free    (void *ptr)                    { g2_free (ptr); }
void *grub_realloc (void *ptr, grub_size_t size)  { return g2_realloc (ptr, size); }

void *
grub_zalloc (grub_size_t size)
{
	void *p = g2_malloc (size);
	if (p)
		memset (p, 0, size);
	return p;
}

void *
grub_calloc (grub_size_t n, grub_size_t size)
{
	grub_size_t tot;
	void *p;
	if (__builtin_mul_overflow (n, size, &tot))
		return NULL;
	p = g2_malloc (tot);
	if (p)
		memset (p, 0, tot);
	return p;
}

/************************************************************************/
/*	string / memory  (wrap OpenBIOS libc; implement the few it lacks)*/
/************************************************************************/

void *grub_memcpy  (void *d, const void *s, grub_size_t n) { return memcpy (d, s, n); }
void *grub_memmove (void *d, const void *s, grub_size_t n) { return memmove (d, s, n); }
void *grub_memset  (void *s, int c, grub_size_t n)         { return memset (s, c, n); }
int   grub_memcmp  (const void *a, const void *b, grub_size_t n) { return memcmp (a, b, n); }

grub_size_t grub_strlen (const char *s)                        { return strlen (s); }
int   grub_strcmp     (const char *a, const char *b)           { return strcmp (a, b); }
int   grub_strncmp    (const char *a, const char *b, grub_size_t n) { return strncmp (a, b, n); }
int   grub_strcasecmp (const char *a, const char *b)           { return strcasecmp (a, b); }
char *grub_strcpy     (char *d, const char *s)                 { return strcpy (d, s); }
char *grub_strchr     (const char *s, int c)                   { return strchr (s, c); }
char *grub_strrchr    (const char *s, int c)                   { return strrchr (s, c); }
/* strdup/strndup allocate from the grub2fs heap (not OpenBIOS's), so a later
 * grub_free on the result reads a g2 header, not garbage. */
char *
grub_strdup (const char *s)
{
	grub_size_t l = strlen (s) + 1;
	char *p = g2_malloc (l);
	if (p)
		memcpy (p, s, l);
	return p;
}

char *
grub_strndup (const char *s, grub_size_t n)
{
	grub_size_t l = strnlen (s, n);
	char *p = g2_malloc (l + 1);
	if (!p)
		return NULL;
	memcpy (p, s, l);
	p[l] = '\0';
	return p;
}

int grub_tolower (int c) { return (c >= 'A' && c <= 'Z') ? c - 'A' + 'a' : c; }
int grub_toupper (int c) { return (c >= 'a' && c <= 'z') ? c - 'a' + 'A' : c; }
int grub_isprint (int c) { return (c >= 0x20 && c < 0x7f); }

char *
grub_xasprintf (const char *fmt, ...)
{
	char buf[512];
	va_list ap;
	va_start (ap, fmt);
	vsnprintf (buf, sizeof (buf), fmt, ap);
	va_end (ap);
	return grub_strdup (buf);   /* g2 heap, so grub_free works on the result */
}

/************************************************************************/
/*	filesystem registration						*/
/*	(the grub_fs_list the package walks — grubfs's fsys_table[])	*/
/************************************************************************/

grub_fs_t grub_fs_list;

void
grub_fs_register (grub_fs_t fs)
{
	fs->next = grub_fs_list;
	fs->prev = &grub_fs_list;   /* kept for struct parity; the shim only walks ->next */
	grub_fs_list = fs;
}

void
grub_fs_unregister (grub_fs_t fs)
{
	grub_fs_t *p = &grub_fs_list;
	while (*p) {
		if (*p == fs) {
			*p = fs->next;
			return;
		}
		p = &(*p)->next;
	}
}

/************************************************************************/
/*	the ONE disk primitive: grub_disk_read == grubfs devread	*/
/************************************************************************/

grub_err_t
grub_disk_read (grub_disk_t disk, grub_disk_addr_t sector,
		grub_off_t offset, grub_size_t size, void *buf)
{
	struct grub2fs_disk_priv *p = (struct grub2fs_disk_priv *) disk->data;
	long long pos = (long long) sector * GRUB_DISK_SECTOR_SIZE
		      + (long long) offset + p->offset;

	if (seek_io (p->fd, pos)) {
		grub_errno = GRUB_ERR_READ_ERROR;
		return grub_errno;
	}
	if (read_io (p->fd, buf, size) != (int) size) {
		grub_errno = GRUB_ERR_READ_ERROR;
		return grub_errno;
	}
	/* Honor disk->read_hook. fshelp.c scopes it to the FILE-DATA reads only
	 * (sets it before the data read, clears it after — see fshelp.c), so the
	 * `blocks-of` method sets a recorder and learns the exact device sectors a
	 * file's content sits on — the endgame's block map (design notes §2.6). It
	 * stays NULL on the plain load/read path, so this is a no-op there. */
	if (disk->read_hook)
		disk->read_hook (sector, (unsigned) offset, (unsigned) size,
				 disk->read_hook_data);
	return GRUB_ERR_NONE;
}
