/*
 * list-pids.c — from Ciro S. Costa, "How is /proc able to list process IDs?"
 *   (ops.tips, 2018-10-11)  ../upstream-tutorial/how-is-proc-able-to-list-pids.html
 *
 * `strace -f ls /proc` shows that listing a directory is really two syscalls:
 * openat(..., O_DIRECTORY) to get a descriptor, then a loop of getdents64() to
 * pull the entries. This program skips `ls` AND libc's readdir() wrapper and
 * calls the *raw* getdents64 syscall itself on /proc. The numeric entries it
 * prints are PIDs — they exist nowhere on disk; the kernel's proc_pid_readdir()
 * synthesizes them on the fly by walking the caller's PID namespace (which is
 * why, inside a container, you only see the container's PIDs).
 *
 *   Build:  cc -Wall -o list-pids list-pids.c
 *   Run  :  ./list-pids            # lists /proc
 *           ./list-pids /tmp       # any directory works
 *
 * ⚠ DIVERGENCE (glibc vs musl): this pulls <linux/types.h> and uses the raw
 * SYS_getdents64 number rather than libc's readdir(). The kernel UAPI headers
 * that provide <linux/types.h> ship with libc6-dev on Debian, but on Alpine you
 * must `apk add linux-headers` or the compile fails with "linux/types.h: No
 * such file or directory". The struct below deliberately uses plain `long` /
 * `off_t` (not glibc's ino64_t/off64_t), so the same source builds on both
 * glibc and musl once the header is present. See ../RUNBOOK.md.
 */
#include <fcntl.h>
#include <linux/types.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Total size of the stack buffer we hand the kernel to fill with entries. */
#define BUF_SIZE 1024

/*
 * The kernel's directory-entry layout for getdents64 (see the kernel's
 * include/linux/dirent.h). getdents64 is not wrapped by a dedicated glibc/musl
 * function on every libc, so we define the struct ourselves and invoke the
 * syscall by number.
 */
struct linux_dirent64 {
	long           d_ino;    /* 64-bit inode number         */
	off_t          d_off;    /* 64-bit offset to next struct */
	unsigned short d_reclen; /* size of this dirent          */
	unsigned char  d_type;   /* file type                    */
	char           d_name[]; /* filename (null-terminated)   */
};

int main(int argc, char** argv)
{
	const char* path = argc > 1 ? argv[1] : "/proc";
	char buf[BUF_SIZE];
	int fd, err = 0, nread;

	/* Open the directory; the kernel sets up the file description. */
	fd = open(path, O_RDONLY | O_DIRECTORY);
	if (fd == -1) {
		perror("open");
		return 1;
	}

	for (;;) {
		/* Ask the kernel to fill `buf` with directory entries. */
		nread = syscall(SYS_getdents64, fd, buf, BUF_SIZE);
		if (nread == -1) {
			perror("SYS_getdents64");
			err = 1;
			break;
		}
		if (nread == 0) /* no more entries */
			break;

		/* Walk the packed entries using each one's d_reclen. */
		for (int off = 0; off < nread;) {
			struct linux_dirent64* entry =
			    (struct linux_dirent64*)(buf + off);
			printf("%s\n", entry->d_name);
			off += entry->d_reclen;
		}
	}

	close(fd); /* free the underlying kernel structures */
	return err;
}
