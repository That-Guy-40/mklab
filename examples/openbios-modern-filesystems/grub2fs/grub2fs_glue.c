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
/*	heap  (OpenBIOS malloc; note: x86/amd64 malloc is a bump		*/
/*	allocator with free() a no-op — see fs/../lib.c)		*/
/************************************************************************/

void *grub_malloc  (grub_size_t size)             { return malloc (size); }
void  grub_free    (void *ptr)                    { free (ptr); }

/* OpenBIOS provides no realloc (and free() is a no-op on x86/amd64). The ext2
 * slice never calls grub_realloc (0 references in ext2.c/fshelp.c); FAT/ISO do,
 * and that is the point at which grub2fs needs a real heap of its own — see
 * PLAN.md POC-3. Kept minimal here: allocate fresh, no copy (unreachable on the
 * ext2 path, so it cannot silently corrupt a read this slice performs). */
void *grub_realloc (void *ptr __attribute__ ((unused)), grub_size_t size)
{
	return malloc (size);
}

void *
grub_zalloc (grub_size_t size)
{
	void *p = malloc (size);
	if (p)
		memset (p, 0, size);
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
char *grub_strdup     (const char *s)                          { return strdup (s); }

char *
grub_strndup (const char *s, grub_size_t n)
{
	grub_size_t l = strnlen (s, n);
	char *p = malloc (l + 1);
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
	return strdup (buf);
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
	/* disk->read_hook (progress/blocklist) is unused on the plain file-read
	 * path — the package leaves file->read_hook NULL — so it is not called. */
	return GRUB_ERR_NONE;
}
