/*
 * limit-open-files.c — from Ciro S. Costa, "Process resource limits under the
 *   hood" (ops.tips, 2018-10-13).
 *   ../upstream-tutorial/proc-pid-limits-under-the-hood.html
 *
 * ulimit, getrlimit(2) and setrlimit(2) all funnel into one syscall: prlimit(2),
 * which can get *and set* the resource limits of any process (given permission).
 * This program uses prlimit() to change another PID's RLIMIT_NOFILE (the "Max
 * open files" line you see in /proc/<pid>/limits), printing the old values it
 * read back — a "get-and-set" in a single call.
 *
 *   Build:  cc -Wall -o limit-open-files limit-open-files.c
 *   Run  :  ./limit-open-files -p <PID> -s <soft> -h <hard>
 *   e.g.:   ./limit-open-files -p 29871 -s 12 -h 12
 *
 * Two things the article demonstrates you can verify with this:
 *   • the change shows up immediately in /proc/<PID>/limits (both read the same
 *     tsk->signal->rlim in the kernel);
 *   • *raising* the hard limit needs CAP_SYS_RESOURCE — without it, prlimit
 *     returns EPERM ("Operation not permitted").
 *
 * The article omits its argument parser "for brevity"; a small getopt() one is
 * provided here so it actually builds and runs. Uses prlimit() → needs
 * _GNU_SOURCE (glibc and musl both expose it there).
 */
#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>

struct cli {
	pid_t          pid;
	rlim_t         soft;
	rlim_t         hard;
};

static void
cli_parse(int argc, char** argv, struct cli* cli)
{
	int opt;

	/* sensible defaults; -p is required */
	cli->pid  = 0;
	cli->soft = 12;
	cli->hard = 12;

	while ((opt = getopt(argc, argv, "p:s:h:")) != -1) {
		switch (opt) {
		case 'p': cli->pid  = (pid_t)atol(optarg); break;
		case 's': cli->soft = (rlim_t)strtoull(optarg, NULL, 10); break;
		case 'h': cli->hard = (rlim_t)strtoull(optarg, NULL, 10); break;
		default:
			fprintf(stderr,
				"usage: %s -p <pid> -s <soft> -h <hard>\n", argv[0]);
			exit(2);
		}
	}

	if (cli->pid == 0) {
		fprintf(stderr, "error: -p <pid> is required\n");
		exit(2);
	}
}

int main(int argc, char** argv)
{
	int err = 0;

	struct cli cli = { 0 };
	cli_parse(argc, argv, &cli);

	/* old: filled by the kernel with the previous values (the "get"). */
	struct rlimit old = { 0 };
	/* new: the values we want to install (the "set"). */
	struct rlimit new = {
		.rlim_cur = cli.soft,
		.rlim_max = cli.hard,
	};

	/* get-and-set in one call: non-NULL new installs it, non-NULL old reads
	 * back the values that were there before. */
	err = prlimit(cli.pid, RLIMIT_NOFILE, &new, &old);
	if (err == -1) {
		perror("prlimit - get and set");
		return 1;
	}
	printf("before: soft=%lld; hard=%lld\n",
	       (long long)old.rlim_cur, (long long)old.rlim_max);

	/* a plain "get" to show the values that are now in effect. */
	err = prlimit(cli.pid, RLIMIT_NOFILE, NULL, &old);
	if (err == -1) {
		perror("prlimit - get");
		return 1;
	}
	printf("now:    soft=%lld; hard=%lld\n",
	       (long long)old.rlim_cur, (long long)old.rlim_max);

	return 0;
}
