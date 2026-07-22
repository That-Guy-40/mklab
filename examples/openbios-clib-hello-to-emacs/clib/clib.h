/* clib.h — a tiny C support library for OpenBIOS client programs.
 *
 * This is the lab's answer to Open Firmware's clients/lib: a libc-substitute
 * that lets a plain C program run standalone on the firmware. It sits on top
 * of the raw IEEE 1275 client interface (of1275.{c,h}, of1275_io.c — the
 * of_client_interface callback the firmware hands us at _start). Everything
 * here is ultimately one firmware `write` service call away from the metal.
 *
 * Phase 0 seed: strlen + the number/string console helpers a `hello` and a
 * `memtest` need. It GROWS with the ladder (malloc-via-`claim`, a fuller
 * printf) — see PLAN.md. The rule: nothing here assumes an OS. There isn't one.
 */
#ifndef CLIB_H
#define CLIB_H

/* Provided by of1275_io.c — the three POSIX-shaped primitives, each a thin
 * shim over a client-interface service (write/read → stdout/stdin ihandle;
 * exit → the firmware's `exit` service). */
int  write(int fd, char *buf, int len);
int  read(int fd, char *buf, int len);
int  exit(int status);

/* string.h, the three-function edition */
unsigned int clib_strlen(const char *s);

/* console output, built on write(1, ...) */
void puts(const char *s);            /* string, no trailing newline added */
void putsn(const char *s);           /* string + newline */
void put_udec(unsigned int v);       /* unsigned decimal */
void put_hex(unsigned int v);        /* 0x-prefixed hex */

/* memory, built on the firmware's `claim`/`release` services and the /memory
 * device node — this is the clib's Phase-2 growth for memtest. There is no
 * OS heap; `claim` IS the allocator. */
void        *clib_claim(unsigned int size);      /* claim size bytes, page-aligned; 0 on failure */
void         clib_release(void *p, unsigned int size);
unsigned int clib_ram_bytes(void);               /* total RAM per /memory "reg" (0 if unknown) */

/* interactive console — the editor half (Phase 4). read() polls the firmware
 * stdin (0 bytes when no key waits), so getch blocks by spinning; ANSI escapes
 * drive a real terminal (the muxed-stdio console). No termcap, no OS — just the
 * `read`/`write` client-interface services and escape sequences. */
int  getch(void);                    /* one keystroke, blocking */
void put_char(int c);                /* one byte to stdout */
void cls(void);                      /* clear screen + home cursor (ANSI) */
void gotoxy(int row, int col);       /* 1-based cursor position (ANSI) */

#endif /* CLIB_H */
