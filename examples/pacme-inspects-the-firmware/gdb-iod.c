/* gdb-iod.c -- `pokegdb`: GNU poke with a gdbstub-backed foreign IO device.
 *
 * This is Spike 5 of the pacme lab: the one honest UNKNOWN the rest of the lab
 * left standing.  Over the QMP-NBD bridge, poke reads the firmware's *block*
 * store live, but the firmware's *RAM* was only ever a SNAPSHOT (a QMP pmemsave
 * / a file poke opens after the fact).  A gdbstub IO device closes that gap:
 * libpoke lets an embedding program register a "foreign" IOD (pk_register_iod),
 * and QEMU's own gdbstub answers memory reads/writes for the LIVE guest.  So
 * `pokegdb` is poke, embedded, with one extra device whose pread/pwrite are gdb
 * Remote Serial Protocol `m`/`M` packets to a running QEMU.
 *
 *   pokegdb gdb://HOST:PORT 'STATEMENT;' ['STATEMENT;' ...]
 *
 * It registers the IOD, `open`s the handler (which becomes the current IO
 * space), then compiles+executes each Poke STATEMENT in order, so
 *   pokegdb gdb://127.0.0.1:1234 'set_endian(ENDIAN_LITTLE);' \
 *           'printf("%u32x\n", uint<32> @ 0x100000#B);'
 * prints the live 32-bit word at guest-physical 0x100000.
 *
 * MEASURED, NOT ASSUMED (2026-10-02, QEMU 8.2 + OpenBIOS x86, see the lab README):
 *  - QEMU's gdbstub answers `m`/`M` while the guest RUNS -- no stop/halt needed;
 *    a cold `\x03` interrupt is neither required nor reliably acked, so we never
 *    send one.  We do the minimal handshake (read greeting, `+`, qSupported) and
 *    then read/write memory.
 *  - OpenBIOS x86 runs with CR0.PG=0 (no paging), so a gdb linear address IS the
 *    guest physical address, and a read here equals QMP `xp` at the same address.
 *    That equivalence is the lab's oracle; it does NOT hold on a paged guest, and
 *    this tool makes no translation claim -- the IOD offset is passed to `m`/`M`
 *    verbatim as a byte address.  (On x86 OpenBIOS, a *Forth* address is NOT this
 *    address -- `l!`'s ofmem offset is real -- which is why the smoke LOCATES a
 *    firmware-written value by scanning physical RAM, never by assuming an addr.)
 *
 * libpoke is GPLv3; this file is GPLv3 and stays on the HOST beside QEMU, never
 * linked into the GPLv2-only firmware (the lab's standing wall).  It compiles
 * against the vendored vendor/libpoke.h and links the shipped libpoke.so.
 *
 * Copyright (C) 2026 the mklab authors.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netdb.h>

#include "libpoke.h"

/* ---------------------------------------------------------------------- */
/* Minimal terminal interface for the embedded compiler (output -> stdio). */
/* ---------------------------------------------------------------------- */
static void t_flush (pk_compiler p) { (void)p; fflush (stdout); }
static void t_puts (pk_compiler p, const char *s) { (void)p; fputs (s, stdout); }
static void t_printf (pk_compiler p, const char *f, ...)
{ (void)p; va_list a; va_start (a, f); vprintf (f, a); va_end (a); }
static void t_indent (pk_compiler p, unsigned l, unsigned s)
{ (void)p; for (unsigned i = 0; i < l * s; i++) putchar (' '); }
static void t_class (pk_compiler p, const char *c) { (void)p; (void)c; }
static int  t_eclass (pk_compiler p, const char *c) { (void)p; (void)c; return 1; }
static void t_hlink (pk_compiler p, const char *u, const char *i) { (void)p; (void)u; (void)i; }
static int  t_ehlink (pk_compiler p) { (void)p; return 1; }
static struct pk_color t_col (pk_compiler p) { (void)p; struct pk_color c = { -1, -1, -1 }; return c; }
static void t_scol (pk_compiler p, struct pk_color c) { (void)p; (void)c; }
static struct pk_term_if TIF = {
  t_flush, t_puts, t_printf, t_indent, t_class, t_eclass,
  t_hlink, t_ehlink, t_col, t_col, t_scol, t_scol
};

/* ---------------------------------------------------------------------- */
/* gdb Remote Serial Protocol client -- just enough for `m` and `M`.       */
/* ---------------------------------------------------------------------- */
struct gdb_dev
{
  int fd;              /* TCP socket to QEMU's gdbstub */
  uint64_t flags;      /* PK_IOS_F_* as opened */
};

/* The single registered device (pk only supports one foreign IOD), so main()
   can detach it on exit even if the compiler does not call close().  */
static struct gdb_dev *G_DEV = NULL;

static const char HEX[] = "0123456789abcdef";

/* Send one RSP packet: $<data>#<csum>.  Returns 0 on success, -1 on error. */
static int
rsp_send (int fd, const char *data)
{
  size_t n = strlen (data);
  char *pkt = malloc (n + 5);
  if (!pkt)
    return -1;
  unsigned char csum = 0;
  for (size_t i = 0; i < n; i++)
    csum = (unsigned char) (csum + (unsigned char) data[i]);
  int len = snprintf (pkt, n + 5, "$%s#%c%c", data, HEX[csum >> 4], HEX[csum & 0xf]);
  const char *p = pkt;
  int left = len, rc = 0;
  while (left > 0)
    {
      ssize_t w = write (fd, p, left);
      if (w <= 0) { rc = -1; break; }
      p += w; left -= (int) w;
    }
  free (pkt);
  return rc;
}

/* Receive one RSP reply payload into BUF (NUL-terminated), skipping leading
   `+`/`-` acks.  Acks our receipt with `+`.  Returns payload length or -1. */
static int
rsp_recv (int fd, char *buf, size_t cap)
{
  /* read until we see '$', then until '#', then two checksum chars */
  int state = 0;        /* 0=await $, 1=collecting, 2=after #, want 2 csum */
  size_t out = 0;
  int csum_left = 2;
  for (;;)
    {
      char c;
      ssize_t r = read (fd, &c, 1);
      if (r <= 0)
        return -1;
      if (state == 0)
        {
          if (c == '$') state = 1;
          /* ignore '+', '-', and stray bytes before the packet */
        }
      else if (state == 1)
        {
          if (c == '#') state = 2;
          else
            {
              if (out + 1 >= cap)
                return -1;
              buf[out++] = c;
            }
        }
      else /* state 2: consume checksum */
        {
          if (--csum_left == 0)
            break;
        }
    }
  buf[out] = '\0';
  /* ack */
  if (write (fd, "+", 1) != 1)
    return -1;
  return (int) out;
}

/* One request/reply round-trip. */
static int
rsp_xfer (int fd, const char *req, char *resp, size_t cap)
{
  if (rsp_send (fd, req) != 0)
    return -1;
  return rsp_recv (fd, resp, cap);
}

/* ---- the IOD interface functions ---- */

static const char *
gdb_if_name (void)
{
  return "GDB";
}

static char *
gdb_handler_normalize (const char *handler, uint64_t flags, int *error)
{
  (void) flags;
  if (error)
    *error = PK_IOD_OK;
  if (strncmp (handler, "gdb://", 6) == 0)
    return strdup (handler);
  return NULL;  /* not ours -> poke tries the next backend */
}

static void *
gdb_open (const char *handler, uint64_t flags, int *error, void *data)
{
  (void) data;
  /* handler is "gdb://HOST:PORT" -- parse host and port */
  const char *hp = handler + 6;
  const char *colon = strrchr (hp, ':');
  if (!colon)
    { if (error) *error = PK_IOD_EINVAL; return NULL; }
  char host[256];
  size_t hlen = (size_t) (colon - hp);
  if (hlen == 0 || hlen >= sizeof host)
    { if (error) *error = PK_IOD_EINVAL; return NULL; }
  memcpy (host, hp, hlen);
  host[hlen] = '\0';
  const char *port = colon + 1;

  struct addrinfo hints, *res = NULL;
  memset (&hints, 0, sizeof hints);
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  if (getaddrinfo (host, port, &hints, &res) != 0 || !res)
    { if (error) *error = PK_IOD_ERROR; return NULL; }
  int fd = socket (res->ai_family, res->ai_socktype, res->ai_protocol);
  if (fd < 0 || connect (fd, res->ai_addr, res->ai_addrlen) != 0)
    {
      if (fd >= 0) close (fd);
      freeaddrinfo (res);
      if (error) *error = PK_IOD_ERROR;
      return NULL;
    }
  freeaddrinfo (res);

  /* minimal handshake: drain any greeting, ack, negotiate features */
  char tmp[1024];
  if (write (fd, "+", 1) != 1)
    { close (fd); if (error) *error = PK_IOD_ERROR; return NULL; }
  /* Plain qSupported -- do NOT enable multiprocess+, or QEMU rejects the bare
     `D` (detach) packet with E22 (it then expects `D;pid`), and we would leave
     the guest paused.  We only need `m`/`M`, so no feature negotiation matters. */
  (void) rsp_xfer (fd, "qSupported", tmp, sizeof tmp);

  struct gdb_dev *dev = malloc (sizeof *dev);
  if (!dev)
    { close (fd); if (error) *error = PK_IOD_ENOMEM; return NULL; }
  dev->fd = fd;
  dev->flags = flags;
  G_DEV = dev;
  if (error)
    *error = PK_IOD_OK;
  return dev;
}

/* Detach: QEMU's gdbstub HALTS the vCPU when a client attaches and leaves it
   halted on a bare disconnect -- which would freeze the guest for everything
   else (its serial console, the next tool).  The `D` (detach) packet resumes
   the target and detaches, so pokegdb leaves the guest RUNNING, as it found it.
   (Measured 2026-10-02: without this, query-status reports `paused` after
   pokegdb exits, and the firmware's serial prompt stops responding.) */
static void
gdb_detach (struct gdb_dev *dev)
{
  if (dev && dev->fd >= 0)
    {
      char resp[32];
      int n = rsp_xfer (dev->fd, "D", resp, sizeof resp);
      if (getenv ("POKEGDB_DEBUG"))
        fprintf (stderr, "[detach] fd=%d D-reply(n=%d)=%s\n", dev->fd, n, n > 0 ? resp : "<none>");
      close (dev->fd);
      dev->fd = -1;
    }
  else if (getenv ("POKEGDB_DEBUG"))
    fprintf (stderr, "[detach] skipped (dev=%p fd=%d)\n",
             (void *) dev, dev ? dev->fd : -999);
}

static int
gdb_close (void *d)
{
  struct gdb_dev *dev = d;
  if (dev)
    {
      gdb_detach (dev);  /* no-op if main() already detached (fd == -1) */
      if (dev == G_DEV)
        G_DEV = NULL;
      free (dev);
    }
  return PK_IOD_OK;
}

static int
gdb_pread (void *d, void *buf, size_t count, pk_iod_off offset)
{
  struct gdb_dev *dev = d;
  char req[64];
  snprintf (req, sizeof req, "m%llx,%zx",
            (unsigned long long) offset, count);
  /* reply is 2 hex chars per byte, plus room for an 'E'rror code */
  size_t cap = count * 2 + 8;
  char *resp = malloc (cap);
  if (!resp)
    return PK_IOD_ENOMEM;
  int n = rsp_xfer (dev->fd, req, resp, cap);
  if (n < 0 || (n >= 1 && resp[0] == 'E') || (size_t) n != count * 2)
    { free (resp); return PK_IOD_EOF; }
  unsigned char *out = buf;
  for (size_t i = 0; i < count; i++)
    {
      int hi = resp[2 * i], lo = resp[2 * i + 1];
      hi = (hi <= '9') ? hi - '0' : (hi | 0x20) - 'a' + 10;
      lo = (lo <= '9') ? lo - '0' : (lo | 0x20) - 'a' + 10;
      out[i] = (unsigned char) ((hi << 4) | lo);
    }
  free (resp);
  return PK_IOD_OK;
}

static int
gdb_pwrite (void *d, const void *buf, size_t count, pk_iod_off offset)
{
  struct gdb_dev *dev = d;
  const unsigned char *in = buf;
  /* "M<addr>,<len>:" + 2 hex/byte */
  size_t cap = 32 + count * 2 + 1;
  char *req = malloc (cap);
  if (!req)
    return PK_IOD_ENOMEM;
  int off = snprintf (req, cap, "M%llx,%zx:",
                      (unsigned long long) offset, count);
  for (size_t i = 0; i < count; i++)
    {
      req[off++] = HEX[in[i] >> 4];
      req[off++] = HEX[in[i] & 0xf];
    }
  req[off] = '\0';
  char resp[32];
  int n = rsp_xfer (dev->fd, req, resp, sizeof resp);
  free (req);
  if (n < 0 || resp[0] == 'E' || strncmp (resp, "OK", 2) != 0)
    return PK_IOD_EOF;
  return PK_IOD_OK;
}

static uint64_t
gdb_get_flags (void *d)
{
  (void) d;
  /* The gdbstub lets us read AND write live guest memory, regardless of the
     flags poke's single-argument open() passed (which can be 0 -> a "wrong
     permissions" error on the first access if echoed back).  Report both, as
     the upstream foreign-IOD example does. */
  return PK_IOS_F_READ | PK_IOS_F_WRITE;
}

static pk_iod_off
gdb_size (void *d)
{
  (void) d;
  /* The guest's address space; we do not probe it. Report 4 GiB so poke never
     refuses a targeted read/write as out of bounds -- bounds are the guest's. */
  return (pk_iod_off) 1 << 32;
}

static int
gdb_flush (void *d, pk_iod_off offset)
{
  (void) d; (void) offset;
  return PK_IOD_OK;
}

static struct pk_iod_if gdb_iod = {
  gdb_if_name,
  gdb_handler_normalize,
  gdb_open,
  gdb_close,
  gdb_pread,
  gdb_pwrite,
  gdb_get_flags,
  gdb_size,
  gdb_flush,
  NULL
};

/* ---------------------------------------------------------------------- */
int
main (int argc, char *argv[])
{
  if (argc < 3 || strncmp (argv[1], "gdb://", 6) != 0)
    {
      fprintf (stderr,
        "usage: %s gdb://HOST:PORT 'POKE-STATEMENT;' ['POKE-STATEMENT;' ...]\n"
        "  Registers a gdbstub-backed foreign IO device, opens it as the\n"
        "  current IO space, and runs each Poke statement in order.\n"
        "  Example: %s gdb://127.0.0.1:1234 'printf(\"%%u8x\\n\", byte @ 0#B);'\n",
        argv[0], argv[0]);
      return 2;
    }

  pk_compiler pk = pk_compiler_new (&TIF);
  if (!pk)
    { fprintf (stderr, "pokegdb: cannot create the poke compiler\n"); return 3; }

  if (pk_register_iod (pk, &gdb_iod) != PK_OK)
    { fprintf (stderr, "pokegdb: pk_register_iod failed\n"); return 3; }

  /* Build ONE Poke program: open the gdb handler (becomes the current IO
     space), then the caller's statements in order.  pk_compile_buffer runs a
     whole program -- declarations (`var`), loops and top-level statements --
     which a per-statement pk_compile_statement call cannot (it takes a single
     expression-statement and rejects `var`). */
  size_t len = strlen (argv[1]) + 32;
  for (int i = 2; i < argc; i++)
    len += strlen (argv[i]) + 2;
  char *prog = malloc (len);
  if (!prog)
    { fprintf (stderr, "pokegdb: out of memory\n"); pk_compiler_free (pk); return 3; }
  int off = snprintf (prog, len, "open (\"%s\");\n", argv[1]);
  for (int i = 2; i < argc; i++)
    off += snprintf (prog + off, len - (size_t) off, "%s\n", argv[i]);

  int rc = 0;
  const char *end = NULL;
  pk_val exc = PK_NULL;
  if (pk_compile_buffer (pk, prog, &end, &exc) != PK_OK)
    { fprintf (stderr, "pokegdb: error executing program (open %s failed, or a statement did)\n", argv[1]); rc = 5; }
  else if (exc != PK_NULL)
    { fprintf (stderr, "pokegdb: the program raised an unhandled exception\n"); rc = 6; }

  free (prog);
  /* Leave the guest running (resume + detach) BEFORE tearing down the compiler,
     whether or not the program closed the IOS -- pk_compiler_free does not
     reliably call the IOD's close. */
  gdb_detach (G_DEV);
  pk_compiler_free (pk);
  return rc;
}
