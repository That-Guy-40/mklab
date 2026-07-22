/* memtest.c — rung 3 of the ladder: a RAM tester as an OpenBIOS client.
 *
 * OFW ships a `memtest` client; this is the same idea on the modern codebase.
 * With no operating system, the client asks the *firmware* for everything it
 * needs: how much RAM exists (`/memory` "reg", via clib_ram_bytes) and a block
 * to hammer (the `claim` service, via clib_claim). It then runs the classic
 * memtest patterns over the claimed block and reports over the console — every
 * line a `write` back through the IEEE 1275 client interface.
 *
 * Deliberately strict C89 (all declarations at the top of a block, no mixed
 * decl/code) to match the K&R clib and keep -std=gnu89 happy. Emulated RAM is
 * reliable, so the expected verdict is PASS: the point is the *mechanism* — a
 * memory tester running on the bare machine, served entirely by firmware.
 */
#include "clib.h"

#define TEST_MB 4u

/* Fill the whole block with val, then verify every cell. Returns error count. */
static unsigned int verify_fill(volatile unsigned int *m, unsigned int words,
				unsigned int val)
{
	unsigned int i, errs;
	for (i = 0; i < words; i++)
		m[i] = val;
	for (i = 0, errs = 0; i < words; i++)
		if (m[i] != val)
			errs++;
	return errs;
}

int main(void)
{
	static const unsigned int pats[4] = {
		0x00000000u, 0xFFFFFFFFu, 0xAAAAAAAAu, 0x55555555u
	};
	volatile unsigned int *m;
	unsigned int ram, size, words, i, errs, e;

	ram   = clib_ram_bytes();
	size  = TEST_MB << 20;
	words = size / (unsigned int)sizeof(unsigned int);
	errs  = 0;

	putsn("OpenBIOS memtest client -- a RAM tester with no OS, served by the firmware.");
	if (ram) {
		puts("  /memory reports ");
		put_udec(ram >> 20);
		putsn(" MiB of RAM");
	}

	m = (volatile unsigned int *)clib_claim(size);
	if (!m) {
		putsn("memtest: FAIL -- claim failed");
		return 1;
	}
	puts("  claimed ");
	put_udec(TEST_MB);
	puts(" MiB at ");
	put_hex((unsigned int)m);
	putsn("");

	/* 1. address uniqueness — each cell holds its own index (stuck/aliased
	 *    address lines show up as cells reading back a neighbour's value). */
	puts("  address test ......... ");
	for (i = 0; i < words; i++)
		m[i] = i;
	for (i = 0, e = 0; i < words; i++)
		if (m[i] != i)
			e++;
	errs += e;
	putsn(e ? "FAIL" : "ok");

	/* 2. data patterns — all-zeros, all-ones, and the two alternating fills. */
	for (i = 0; i < 4; i++) {
		puts("  pattern ");
		put_hex(pats[i]);
		puts(" ... ");
		e = verify_fill(m, words, pats[i]);
		errs += e;
		putsn(e ? "FAIL" : "ok");
	}

	/* 3. walking bit — each cell = 1 << (index mod 32), so every bit position
	 *    is exercised across the block in a single pass. */
	puts("  walking-bit test ..... ");
	for (i = 0; i < words; i++)
		m[i] = 1u << (i & 31);
	for (i = 0, e = 0; i < words; i++)
		if (m[i] != (1u << (i & 31)))
			e++;
	errs += e;
	putsn(e ? "FAIL" : "ok");

	clib_release((void *)m, size);

	if (errs) {
		puts("memtest: FAIL -- ");
		put_udec(errs);
		putsn(" errors");
		return 1;
	}
	putsn("memtest: PASS -- all patterns verified");
	return 0;
}
