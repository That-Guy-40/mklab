/*
 * mem-hog.c — from Ciro S. Costa, "Why top and free inside containers don't show
 *   the correct container memory" (ops.tips, 2018-10-12).
 *   ../upstream-tutorial/why-top-inside-container-wrong-memory.html
 *
 * A deliberately "leaky" allocator: grab memory 1 MiB at a time and touch every
 * page (malloc alone is lazy — the kernel only really hands you pages when you
 * write to them). Run it inside a memory-limited cgroup and it climbs until it
 * hits the limit, at which point the cgroup's page_counter refuses the charge
 * and the kernel OOM-kills it (SIGKILL → shell reports exit 137 = 128 + 9).
 *
 *   Build:  cc -Wall -o mem-hog mem-hog.c
 *   Run  :  ./mem-hog            # 20 MiB, like the article
 *           ./mem-hog 700        # 700 MiB — blows past a smaller cgroup limit
 *
 * Faithful to the article's program; two small changes: the amount is an
 * optional argument (the article hardcodes 20), and progress is printed every
 * 32 MiB instead of every 1 MiB so the OOM isn't buried under hundreds of lines.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MEGABYTE (1 << 20)
#define ALLOCATIONS 20

int main(int argc, char** argv)
{
	int total = argc > 1 ? atoi(argv[1]) : ALLOCATIONS;
	printf("allocating: %dMB\n", total);

	void* p;
	for (int done = 0; done < total; done++) {
		/* Allocate 1 MiB... */
		p = malloc(MEGABYTE);
		if (p == NULL) {
			perror("malloc");
			return 1;
		}
		/* ...and actually fault the pages in, so the cgroup is charged. */
		memset(p, 65, MEGABYTE);

		if ((done % 32) == 0)
			printf("allocated\t%d MiB\n", done);
	}

	printf("done: %d MiB allocated without hitting a limit\n", total);
	return 0;
}
