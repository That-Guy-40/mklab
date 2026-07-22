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
#include "endian.h"

/* The raw client-interface wrappers we lean on (declared in of1275.h, but
 * that header pulls in the whole service-struct zoo; forward-declare the few
 * we use to keep this translation unit small). */
int of1275_claim(void *virt, int size, int align, void **baseaddr);
int of1275_release(void *virt, int size);
int of1275_finddevice(const char *device_specifier, int *phandle);
int of1275_getprop(int phandle, const char *name, void *buf, int buflen, int *size);
int read(int fd, char *buf, int len);

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

void *clib_claim(unsigned int size)
{
	void *base = (void *)0;
	/* virt = 0 → let the firmware place it; page-aligned. On success the
	 * `claim` service returns the base both as its value and in baseaddr. */
	if (of1275_claim((void *)0, (int)size, 0x1000, &base) < 0)
		return (void *)0;
	if (base == (void *)-1)
		return (void *)0;
	return base;
}

void clib_release(void *p, unsigned int size)
{
	of1275_release(p, (int)size);
}

unsigned int clib_ram_bytes(void)
{
	unsigned int cells[32];
	unsigned int total = 0;
	int ph, size = 0, i, ncells;

	if (of1275_finddevice("/memory", &ph) < 0)
		return 0;
	of1275_getprop(ph, "reg", cells, (int)sizeof(cells), &size);
	if (size <= 0)
		return 0;
	/* "reg" is a list of (base, size) pairs; sum the sizes. Assumes one
	 * address cell + one size cell (true on qemu-system-ppc). The cells are
	 * big-endian by 1275 convention — ntohl is a no-op on ppc, a swap on x86. */
	ncells = size / (int)sizeof(unsigned int);
	for (i = 1; i < ncells; i += 2)
		total += ntohl(cells[i]);
	return total;
}

int getch(void)
{
	char c;
	/* The firmware read is non-blocking (0 bytes when no key waits); spin
	 * until one arrives. An editor's main loop is one big getch(). */
	while (read(0, &c, 1) <= 0)
		;
	return (int)(unsigned char)c;
}

void put_char(int c)
{
	char b = (char)c;
	write(1, &b, 1);
}

void cls(void)
{
	puts("\033[2J\033[H");        /* erase display, cursor home */
}

void gotoxy(int row, int col)
{
	puts("\033[");
	put_udec((unsigned int)row);
	put_char(';');
	put_udec((unsigned int)col);
	put_char('H');
}
