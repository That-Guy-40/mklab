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

#endif /* CLIB_H */
