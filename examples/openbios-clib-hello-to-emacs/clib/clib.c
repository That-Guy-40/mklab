/* clib.c — implementation of the tiny client support library (see clib.h).
 *
 * Every routine here bottoms out in write(1, ...) from of1275_io.c, which
 * issues the firmware's IEEE 1275 `write` service against /chosen's stdout
 * ihandle. No libc, no syscalls, no OS — the "system call" IS the firmware
 * callback the client was handed at _start.
 *
 * Built -std=gnu89 (the of1275 sources are K&R; GCC 14 makes implicit-int a
 * hard error otherwise) and freestanding. Keep it allocation-free until the
 * clib grows a claim-backed malloc (Phase 2, for memtest).
 */
#include "clib.h"

unsigned int clib_strlen(const char *s)
{
	unsigned int n = 0;
	while (s[n])
		n++;
	return n;
}

void puts(const char *s)
{
	/* write() takes a non-const buf (it is the 1275 service signature); the
	 * service only reads it, so casting away const is safe here. */
	write(1, (char *)s, (int)clib_strlen(s));
}

void putsn(const char *s)
{
	puts(s);
	puts("\n");
}

void put_udec(unsigned int v)
{
	char buf[11];              /* 2^32 - 1 is 10 digits */
	int i = (int)sizeof(buf);
	buf[--i] = '\0';
	if (v == 0)
		buf[--i] = '0';
	while (v && i > 0) {
		buf[--i] = (char)('0' + (v % 10));
		v /= 10;
	}
	puts(&buf[i]);
}

void put_hex(unsigned int v)
{
	static const char digits[] = "0123456789abcdef";
	char buf[11];              /* "0x" + 8 nibbles + NUL */
	int i = (int)sizeof(buf);
	buf[--i] = '\0';
	do {
		buf[--i] = digits[v & 0xf];
		v >>= 4;
	} while (v && i > 2);
	buf[--i] = 'x';
	buf[--i] = '0';
	puts(&buf[i]);
}
