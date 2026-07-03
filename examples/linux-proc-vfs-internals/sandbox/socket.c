/*
 * socket.c — from Ciro S. Costa, "How Linux creates sockets and counts them"
 *   (ops.tips, 2018-10-16).
 *   ../upstream-tutorial/how-linux-creates-sockets.html
 *
 * The socket(2) syscall creates a communication endpoint and returns a file
 * descriptor for it. In the kernel that path is sys_socket → __sock_create →
 * sock_alloc → the family's ->create (for AF_INET/SOCK_STREAM, TCP). The fd it
 * hands back is an ordinary descriptor, so it shows up under /proc/<pid>/fd as a
 * symlink to socket:[inode], and each one is counted in /proc/<pid>/net/sockstat.
 *
 *   Build:  cc -Wall -o socket socket.c
 *   Run  :  ./socket              # open 1 socket, then sleep 3600s
 *           ./socket 100          # the article's variant: open 100 sockets
 *           ./socket 1 0          # open 1 socket and exit at once (for strace)
 *
 * Faithful to the article, with fixes so it builds and is scriptable: the
 * in-page snippet tests an undefined `err` (it means the just-returned fd) and
 * omits <unistd.h> for sleep(). Args: [count] [sleep-seconds].
 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char** argv)
{
	int count = argc > 1 ? atoi(argv[1]) : 1;
	int nap   = argc > 2 ? atoi(argv[2]) : 3600;

	for (int i = 0; i < count; i++) {
		/* AF_INET = IPv4, SOCK_STREAM = reliable byte stream (TCP). */
		int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
		if (listen_fd == -1) {
			perror("socket");
			return 1;
		}
	}

	printf("opened %d socket(s); pid %d — inspect /proc/%d/fd, then sleeping %ds\n",
	       count, getpid(), getpid(), nap);
	fflush(stdout);

	sleep(nap);
	return 0;
}
