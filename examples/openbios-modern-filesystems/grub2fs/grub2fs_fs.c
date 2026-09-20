/*
 *	/packages/grub2fs-files
 *
 *	OpenBIOS filesystem package backed by GRUB 2's fs drivers.
 *
 *	The GRUB-2 twin of fs/grubfs/grubfs_fs.c: same package method set
 *	(open/read/seek/tell/load/dir/probe), but it walks grub_fs_list and calls
 *	each grub_fs's fs_open/fs_read/fs_dir instead of GRUB 0.97's fsys_table.
 *	Per-file state lives in a struct grub_file (offset/size are real fields),
 *	so revival bug 5's "file_size() returns ~4 GB" class is gone.
 *
 *	Part of the openbios-modern-filesystems lab. GPLv2+ (this file); it drives
 *	GPLv3+ lab-only drivers (see upstream-grub/README.md).
 */

#include "config.h"
#include "libopenbios/bindings.h"
#include "fs/fs.h"
#include "libc/diskio.h"
#include "libc/string.h"
#include "libc/vsprintf.h"

#include <grub/types.h>
#include <grub/err.h>
#include <grub/disk.h>
#include <grub/device.h>
#include <grub/file.h>
#include <grub/fs.h>

#include "grub2fs.h"

typedef struct {
	struct grub_file   file;
	struct grub_device device;
	struct grub_disk   disk;
	struct grub2fs_disk_priv priv;
	int                mounted;
} grub2fs_info_t;

DECLARE_NODE( grub2fs, 0, sizeof(grub2fs_info_t), "+/packages/grub2fs-files" );

/* set up the grub_device/grub_disk over an open OpenBIOS device fd */
static void
grub2fs_bind_disk( grub2fs_info_t *mi, int fd, long long offset )
{
	memset( &mi->disk, 0, sizeof(mi->disk) );
	memset( &mi->device, 0, sizeof(mi->device) );
	mi->priv.fd = fd;
	mi->priv.offset = offset;
	mi->disk.name = "grub2fs";
	mi->disk.total_sectors = ~0ULL;
	mi->disk.log_sector_size = GRUB_DISK_SECTOR_BITS;
	mi->disk.data = &mi->priv;
	mi->device.disk = &mi->disk;
}

/* backslash -> forward slash, like grubfs */
static void
grub2fs_fixup_path( char *path )
{
	char *s = path;
	while (*s) {
		if (*s == '\\')
			*s = '/';
		s++;
	}
}

/************************************************************************/
/*	Standard package methods					*/
/************************************************************************/

/* ( -- success? ) */
static void
grub2fs_files_open( grub2fs_info_t *mi )
{
	char *path = my_args_copy();
	int fd;
	grub_fs_t fs;

	if (path == NULL)
		RET( 0 );

	fd = open_ih( my_parent() );
	if (fd == -1) {
		free( path );
		RET( 0 );
	}

	grub2fs_fixup_path( path );
	grub2fs_bind_disk( mi, fd, 0 );

	/* Walk the registered filesystems. fs_open both mounts and opens the
	 * named file: GRUB_ERR_NONE is a hit; FILE_NOT_FOUND/BAD_FILE_TYPE means
	 * this fs matched but the path is absent (report "File not found"); any
	 * other error means this fs did not match — try the next. */
	for (fs = grub_fs_list; fs; fs = fs->next) {
		grub_err_t err;

		memset( &mi->file, 0, sizeof(mi->file) );
		mi->file.device = &mi->device;
		mi->file.fs = fs;
		mi->file.offset = 0;
		grub_errno = GRUB_ERR_NONE;

		err = fs->fs_open( &mi->file, path );
		if (err == GRUB_ERR_NONE) {
			mi->mounted = 1;
			free( path );
			RET( -1 );
		}
		if (err == GRUB_ERR_FILE_NOT_FOUND || err == GRUB_ERR_BAD_FILE_TYPE) {
			forth_printf("File not found\n");
			close_io( fd );
			free( path );
			RET( 0 );
		}
		/* else: not this filesystem — try the next */
	}

	forth_printf("File not found\n");
	close_io( fd );
	free( path );
	RET( 0 );
}

/* ( -- ) */
static void
grub2fs_files_close( grub2fs_info_t *mi )
{
	if (mi->mounted && mi->file.fs && mi->file.fs->fs_close)
		mi->file.fs->fs_close( &mi->file );
	close_io( mi->priv.fd );
	mi->mounted = 0;
}

/* ( buf len -- actlen ) */
static void
grub2fs_files_read( grub2fs_info_t *mi )
{
	int count = POP();
	char *buf = (char *)cell2pointer(POP());
	grub_ssize_t ret;

	if (!mi->mounted)
		RET( -1 );

	if (mi->file.offset > mi->file.size)
		mi->file.offset = mi->file.size;
	if ((grub_off_t)count > mi->file.size - mi->file.offset)
		count = (int)(mi->file.size - mi->file.offset);

	grub_errno = GRUB_ERR_NONE;
	ret = mi->file.fs->fs_read( &mi->file, buf, count );
	if (ret > 0)
		mi->file.offset += ret;

	RET( (int)ret );
}

/* ( pos.d -- status ) */
static void
grub2fs_files_seek( grub2fs_info_t *mi )
{
	long long pos = DPOP();
	long long newpos;

	if (!mi->mounted)
		RET( -1 );

	/* A negative offset means "seek to EOF" (file_size() in the Linux
	 * loaders), matching grubfs's seek. */
	newpos = (pos < 0) ? (long long)mi->file.size : pos;
	if ((grub_off_t)newpos > mi->file.size)
		newpos = (long long)mi->file.size;

	mi->file.offset = (grub_off_t)newpos;

	if (newpos)
		RET( -1 );
	else
		RET( 0 );
}

/* ( -- pos.d ) */
static void
grub2fs_files_tell( grub2fs_info_t *mi )
{
	PUSH( (int)mi->file.offset );
	PUSH( 0 );
}

/* ( addr -- size ) */
static void
grub2fs_files_load( grub2fs_info_t *mi )
{
	char *buf = (char *)cell2pointer(POP());
	grub_ssize_t ret;

	if (!mi->mounted)
		RET( 0 );

	mi->file.offset = 0;
	grub_errno = GRUB_ERR_NONE;
	ret = mi->file.fs->fs_read( &mi->file, buf, mi->file.size );
	if (ret > 0)
		mi->file.offset += ret;

	RET( (int)ret );
}

/************************************************************************/
/*	blocks-of: the file's DATA BLOCKS on the parent device		*/
/*	(the endgame's read-side addition, design notes §2.6)		*/
/************************************************************************/
/*
 * A file's bytes live in data blocks at known LBAs on the parent device. GRUB's
 * ext2/fat/iso readers already walk the extent/block chain to those blocks to read
 * them; fshelp.c fires disk->read_hook for exactly those FILE-DATA reads (it sets
 * the hook around the data read and clears it after — metadata reads are not
 * hooked). So we re-read the whole file with a recording hook and learn the device
 * segments its content occupies — no new driver code, per §2.6.
 *
 * These segments are what a SAME-LENGTH in-place write (the endgame proper) writes
 * back: the very sectors already allocated to the file, touching no fs metadata.
 * blocks-of is graded by reading those raw device ranges on the host and confirming
 * they reconstruct the file (smoke-fs-blocks.sh).
 */
#define G2_MAXSEG 1024
typedef struct {
	unsigned long long off[G2_MAXSEG];   /* absolute device byte offset */
	unsigned           len[G2_MAXSEG];
	int                n;
	int                overflow;
	unsigned long long partoff;          /* partition byte offset (priv.offset) */
} g2_blkrec_t;
static g2_blkrec_t g2_blkrec;

static grub_err_t
g2_blk_hook( grub_disk_addr_t sector, unsigned offset, unsigned length, void *data )
{
	g2_blkrec_t *r = (g2_blkrec_t *) data;
	if (r->n >= G2_MAXSEG) { r->overflow = 1; return GRUB_ERR_NONE; }
	r->off[r->n] = (unsigned long long) sector * GRUB_DISK_SECTOR_SIZE
		     + (unsigned long long) offset + r->partoff;
	r->len[r->n] = length;
	r->n++;
	return GRUB_ERR_NONE;
}

/* ( -- ) prints the file's device data-block segments as G2BLK: lines */
static void
grub2fs_files_blocks_of( grub2fs_info_t *mi )
{
	static char scratch[8192];
	grub_off_t remaining;
	int i;

	if (!mi->mounted) { forth_printf("G2BLK: not mounted\n"); return; }

	g2_blkrec.n = 0;
	g2_blkrec.overflow = 0;
	g2_blkrec.partoff = (unsigned long long) mi->priv.offset;
	mi->file.read_hook = g2_blk_hook;
	mi->file.read_hook_data = &g2_blkrec;
	mi->file.offset = 0;

	/* read the whole file (in chunks) so the hook sees every data-block read */
	remaining = mi->file.size;
	while (remaining > 0) {
		int chunk = (remaining > (grub_off_t) sizeof(scratch))
			  ? (int) sizeof(scratch) : (int) remaining;
		grub_ssize_t got;
		grub_errno = GRUB_ERR_NONE;
		got = mi->file.fs->fs_read( &mi->file, scratch, chunk );
		if (got <= 0) break;
		mi->file.offset += got;
		remaining -= got;
	}

	mi->file.read_hook = 0;
	mi->file.read_hook_data = 0;
	mi->file.offset = 0;

	forth_printf("G2BLKS: n=%d size=%lld%s\n", g2_blkrec.n,
		     (long long) mi->file.size,
		     g2_blkrec.overflow ? " OVERFLOW" : "");
	for (i = 0; i < g2_blkrec.n; i++)
		forth_printf("G2BLK: off=%lld len=%u\n",
			     (long long) g2_blkrec.off[i], g2_blkrec.len[i]);
}

/************************************************************************/
/*	write-file: SAME-LENGTH in-place overwrite of a file's data	*/
/*	(the endgame, design notes §2.6)				*/
/************************************************************************/
/*
 * Overwrite the open file's DATA blocks in place with `len` bytes at `addr`.
 * SAME-LENGTH ONLY: refuses (returns -2) when len != the file size, so it touches
 * NO filesystem metadata (inode size, extent/block map, bitmaps, free counts) —
 * it writes the very sectors blocks-of located, already allocated to the file, so
 * fsck stays clean. A length change is the general-writer lab, refused BY NAME here.
 *
 * The write path: seek the parent to each data segment's device offset and call its
 * byte-level `write` (the C deblocker, packages/deblocker.c, does the read-modify-
 * write over the disk's write-blocks) — symmetric with grub2fs's own read_io.
 *
 * ( addr len -- actual )   actual = bytes written, or a negative refusal code.
 */
static void
grub2fs_files_write_file( grub2fs_info_t *mi )
{
	static char scratch[8192];
	int len = POP();
	char *src = (char *) cell2pointer( POP() );
	ihandle_t ih;
	xt_t wxt;
	grub_off_t remaining;
	int i, foff = 0, total = 0;

	if (!mi->mounted)
		RET( -1 );
	if ((grub_off_t) len != mi->file.size) {
		forth_printf("write-file: refusing length %d != file size %lld (same-length only)\n",
			     len, (long long) mi->file.size);
		RET( -2 );
	}

	/* recompute the file's device data-block map with the recording hook */
	g2_blkrec.n = 0;
	g2_blkrec.overflow = 0;
	g2_blkrec.partoff = (unsigned long long) mi->priv.offset;
	mi->file.read_hook = g2_blk_hook;
	mi->file.read_hook_data = &g2_blkrec;
	mi->file.offset = 0;
	remaining = mi->file.size;
	while (remaining > 0) {
		int chunk = (remaining > (grub_off_t) sizeof(scratch))
			  ? (int) sizeof(scratch) : (int) remaining;
		grub_ssize_t got;
		grub_errno = GRUB_ERR_NONE;
		got = mi->file.fs->fs_read( &mi->file, scratch, chunk );
		if (got <= 0) break;
		mi->file.offset += got;
		remaining -= got;
	}
	mi->file.read_hook = 0;
	mi->file.read_hook_data = 0;
	mi->file.offset = 0;
	if (g2_blkrec.overflow) { forth_printf("write-file: block map overflow\n"); RET( -3 ); }

	/* the parent's byte-level write (deblocker over write-blocks) */
	ih = get_ih_from_fd( mi->priv.fd );
	wxt = ih ? find_ih_method( "write", ih ) : 0;
	if (!wxt) { forth_printf("write-file: parent device has no write method\n"); RET( -4 ); }

	for (i = 0; i < g2_blkrec.n; i++) {
		int w;
		if (seek_io( mi->priv.fd, (long long) g2_blkrec.off[i] ))
			break;
		PUSH( pointer2cell( src + foff ) );
		PUSH( (int) g2_blkrec.len[i] );
		call_package( wxt, ih );
		w = POP();
		if (w < 0)
			break;
		total += w;
		foff += (int) g2_blkrec.len[i];
	}
	RET( total );
}

/* ( -- cstr ) */
static void
grub2fs_files_get_fstype( grub2fs_info_t *mi )
{
	const char *name = (mi->mounted && mi->file.fs) ? mi->file.fs->name : "unknown";
	PUSH( pointer2cell(strdup(name)) );
}

/* directory-listing hook: count entries, so a mount can be probed with a path */
static int
grub2fs_probe_hook( const char *filename __attribute__((unused)),
		    const struct grub_dirhook_info *info __attribute__((unused)),
		    void *data )
{
	int *seen = (int *)data;
	(*seen)++;
	return 0;
}

/* static method, ( pos.d ih -- flag? ) — does SOME registered fs mount here? */
static void
grub2fs_files_probe( grub2fs_info_t *dummy __attribute__((unused)) )
{
	ihandle_t ih = POP_ih();
	long long offs = DPOP();
	int fd, seen = 0;
	grub_fs_t fs;
	static grub2fs_info_t probe;

	fd = open_ih( ih );
	if (fd == -1)
		RET( 0 );

	grub2fs_bind_disk( &probe, fd, offs );

	for (fs = grub_fs_list; fs; fs = fs->next) {
		if (!fs->fs_dir)
			continue;
		grub_errno = GRUB_ERR_NONE;
		fs->fs_dir( &probe.device, "/", grub2fs_probe_hook, &seen );
		if (grub_errno == GRUB_ERR_NONE) {
			close_io( fd );
			RET( -1 );
		}
	}

	close_io( fd );
	RET( 0 );
}

/* static method, ( pathstr len ihandle -- ) */
static void
grub2fs_files_dir( grub2fs_info_t *dummy __attribute__((unused)) )
{
	forth_printf("dir method not implemented for grub2fs filesystem\n");
	POP();
	POP();
	POP();
}

static void
grub2fs_initializer( grub2fs_info_t *dummy __attribute__((unused)) )
{
	fword("register-fs-package");
}

NODE_METHODS( grub2fs ) = {
	{ "probe",	grub2fs_files_probe	},
	{ "open",	grub2fs_files_open	},
	{ "close",	grub2fs_files_close	},
	{ "read",	grub2fs_files_read	},
	{ "seek",	grub2fs_files_seek	},
	{ "tell",	grub2fs_files_tell	},
	{ "load",	grub2fs_files_load	},
	{ "dir",	grub2fs_files_dir	},
	{ "blocks-of",	grub2fs_files_blocks_of	},
	{ "write-file",	grub2fs_files_write_file },

	/* special */
	{ "get-fstype",	grub2fs_files_get_fstype },

	{ NULL,		grub2fs_initializer	},
};

void
grub2fs_init( void )
{
	/* Populate grub_fs_list from the compiled-in drivers, then register the
	 * package. Each grub_<name>_init is the vendored driver's GRUB_MOD_INIT.
	 * Order is not correctness-critical: open probes every registered fs and
	 * each fs_open returns BAD_FS on a foreign image (distinct superblock magic
	 * for ext2/fat/iso9660), so the matching driver is the one that succeeds. */
	grub_ext2_init( NULL );
	grub_fat_init( NULL );
	grub_iso9660_init( NULL );

	REGISTER_NODE( grub2fs );
}
