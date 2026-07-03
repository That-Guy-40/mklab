/*
 * accept.c — from Ciro S. Costa, "Using /proc to get a process' current stack
 *   trace" (ops.tips, 2018-10-14).
 *   ../upstream-tutorial/using-procfs-to-get-process-stack-trace.html
 *
 * A minimal TCP server: open a listening socket, then loop accept()ing. With
 * nothing connecting, the process BLOCKS inside accept(), deep in the kernel.
 * That is the whole setup for the article's question — "what is this process
 * doing right now?" — answered by looking at /proc:
 *   • /proc/<pid>/status  → State: S (sleeping)
 *   • /proc/<pid>/wchan   → the exact KERNEL function it is parked in
 *                           (inet_csk_accept) — readable unprivileged
 *   • /proc/<pid>/stack   → the full kernel stack (needs CAP_SYS_ADMIN)
 *   • gdb -p / gstack     → the USERSPACE stack (main → … → accept)
 *
 *   Build:  cc -Wall -o accept accept.c
 *   Run  :  ./accept &        # blocks in accept(); inspect /proc/<pid>/…
 *
 * The article prints server_accept_and_close() and main() verbatim but pulls
 * server_listen() from a companion post
 * (https://ops.tips/blog/a-tcp-server-in-c/); it is implemented here so the
 * program is complete and self-contained.
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define PORT 32000
#define BACKLOG 128

/* server_listen — set up the passive (listening) socket. Returns its fd, or -1. */
int server_listen()
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd == -1) {
		perror("socket");
		return -1;
	}

	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family      = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	addr.sin_port        = htons(PORT);

	if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) == -1) {
		perror("bind");
		return -1;
	}
	if (listen(fd, BACKLOG) == -1) {
		perror("listen");
		return -1;
	}

	printf("listening on port %d (pid %d) — now blocking in accept()\n",
	       PORT, getpid());
	fflush(stdout);
	return fd;
}

/* server_accept_and_close — block until a connection arrives, then close it. */
int server_accept_and_close(int listen_fd)
{
	int                conn_fd;
	int                err;
	socklen_t          client_len;
	struct sockaddr_in client_addr;

	client_len = sizeof(client_addr);

	/* Pops the next completed connection off the queue; blocks (sleeps in
	 * the kernel) while the queue is empty — this is where we get parked. */
	err = (conn_fd =
	           accept(listen_fd, (struct sockaddr*)&client_addr, &client_len));
	if (err == -1) {
		perror("accept");
		return err;
	}

	err = close(conn_fd);
	if (err == -1) {
		perror("close");
		return err;
	}

	return 0;
}

int main(int argc, char** argv)
{
	int err;
	int listen_fd = server_listen();

	if (listen_fd == -1)
		return 1;

	for (;;) {
		err = server_accept_and_close(listen_fd);
		if (err == -1)
			return 1;
	}

	return 0;
}
