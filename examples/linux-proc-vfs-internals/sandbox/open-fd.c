/*
 * open-fd.c — from Ciro S. Costa, "What is /proc?" (ops.tips, 2018-10-10).
 *   ../upstream-tutorial/what-is-slash-proc.html
 *
 * The article's whole point in ~20 lines: a file descriptor is just a small
 * integer index into the kernel's *per-process* open-file table — and that
 * table is exactly what /proc/<pid>/fd/ exposes to userspace. open() hands back
 * the lowest unused index (0,1,2 are already taken by stdin/stdout/stderr, so
 * the first file you open is usually fd 3). While this process is alive, that
 * number appears as a symlink under /proc/self/fd/.
 *
 *   Build:  cc -Wall -o open-fd open-fd.c
 *   Run  :  ./open-fd            # opens /tmp/file.txt
 *           ./open-fd /etc/hostname
 *
 * Faithful to the article's snippet, with two fixes so it actually compiles and
 * runs: the in-page `printf("fd=%d\n", fd)` drops its trailing ';', and the
 * snippet assumes /tmp/file.txt already exists (demo.sh creates it first).
 */
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char** argv)
{
	const char* path = argc > 1 ? argv[1] : "/tmp/file.txt";

	int fd = open(path, O_RDONLY); /* the article passes the raw flag `0` == O_RDONLY */
	if (fd == -1) {
		perror("open");
		return 1;
	}

	printf("fd=%d\n", fd); /* the article's result: fd=3 */

	close(fd);
	return 0;
}
