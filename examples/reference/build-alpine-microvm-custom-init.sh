#!/usr/bin/env bash
# Build a microvm initramfs that uses a HAND-ROLLED C binary as PID 1.
#
# The point is to demystify what an init actually does — no busybox magic,
# no inittab, just a ~150-line C program that makes all the syscalls you'd
# read about in a kernel/OS textbook: mount(), fork(), setsid(),
# ioctl(TIOCSCTTY), waitpid(), reboot().
#
# Produces:
#   ~/.cache/lab-create/netboot/alpine-3.19-x86_64/vmlinuz-virt
#     (shared with the busybox-init flavour — kernel is userspace-agnostic)
#   ~/.cache/lab-create/netboot/alpine-3.19-x86_64/microvm-custom-initramfs.gz
#     (distinct filename so both flavours coexist)
#
# Usage:
#   build-alpine-microvm-custom-init.sh [suite] [arch] [patch]

set -euo pipefail

SUITE="${1:-3.19}"
ARCH="${2:-x86_64}"
PATCH="${3:-5}"

CACHE_ROOT="${HOME}/.cache/lab-create/netboot/alpine-${SUITE}-${ARCH}"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${SUITE}/releases/${ARCH}"

TAR="alpine-minirootfs-${SUITE}.${PATCH}-${ARCH}.tar.gz"
KERNEL="vmlinuz-virt"
OUT_INITRAMFS="microvm-custom-initramfs.gz"

log() { printf '[build-alpine-microvm-custom] %s\n' "$*" >&2; }

command -v cc >/dev/null 2>&1 \
    || { echo "cc not found — install build-essential (Debian/Ubuntu) or gcc (Fedora/Rocky)"; exit 1; }

mkdir -p "$CACHE_ROOT"
cd       "$CACHE_ROOT"

# 1. Kernel (reused across flavours).
if [[ ! -s "$KERNEL" ]]; then
    log "downloading $MIRROR/netboot/$KERNEL"
    curl --fail --location -o "$KERNEL" "$MIRROR/netboot/$KERNEL"
fi

# 2. Minirootfs tarball (reused across flavours).
if [[ ! -s "$TAR" ]]; then
    log "downloading $MIRROR/$TAR"
    curl --fail --location -o "$TAR" "$MIRROR/$TAR"
fi

# 3. Scratch dir for this build.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

log "extracting minirootfs → $work"
tar -xzf "$TAR" -C "$work"

# 4. Emit the C init program and compile statically.  Static linking means
#    the binary needs nothing from the initramfs's /lib — it's entirely
#    self-contained, which keeps the demo concern-separated: it runs even
#    if /lib is empty.
log "writing /tmp/myinit.c"
cat > "$work/myinit.c" <<'MYINIT_C'
/*
 * myinit.c — a minimal hand-rolled PID 1 for a Linux microvm.
 *
 * What a PID 1 has to do (and how this program does each one):
 *
 *   1. Mount the pseudo-filesystems the rest of userspace expects.
 *        mount("none", "/proc", "proc",     0, NULL)
 *        mount("none", "/sys",  "sysfs",    0, NULL)
 *        mount("none", "/dev",  "devtmpfs", 0, NULL)   // + /tmp, /run
 *
 *   2. Spawn an interactive shell on the serial console, WITH a
 *      controlling tty so Ctrl-C etc. work inside it.  The magic
 *      sequence is:
 *        fork() -> setsid() -> open("/dev/ttyS0") -> ioctl(TIOCSCTTY)
 *
 *   3. Reap children.  Every zombie in the whole system eventually
 *      reparents to PID 1; we waitpid(-1) forever.
 *
 *   4. Respawn the shell when it exits (so `exit` doesn't kernel-panic).
 *
 *   5. Shut down gracefully when asked.  `poweroff` sends SIGUSR2 to
 *      PID 1; `reboot` sends SIGTERM (on busybox).  We catch those,
 *      sync(), and call reboot(RB_POWER_OFF) / reboot(RB_AUTOBOOT).
 *
 * The whole thing is ~150 lines and reads top to bottom.  Compare the
 * syscall sequence to `strace -f busybox init` and you'll find they're
 * doing exactly the same dance.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t want_poweroff = 0;
static volatile sig_atomic_t want_reboot   = 0;

/* ── signal handlers ─────────────────────────────────────────────────── */
static void on_poweroff(int _)   { (void)_; want_poweroff = 1; }
static void on_rebootreq(int _)  { (void)_; want_reboot   = 1; }

/* ── one-shot mount helper that tolerates "already mounted" ──────────── */
static void try_mount(const char *src, const char *tgt, const char *type) {
    if (mount(src, tgt, type, 0, NULL) < 0 && errno != EBUSY) {
        fprintf(stderr, "[myinit] mount %s (%s) failed: %s\n",
                tgt, type, strerror(errno));
    }
}

/* ── fork + setsid + TIOCSCTTY + exec sh on /dev/ttyS0 ───────────────── */
static pid_t spawn_shell(void) {
    pid_t pid = fork();
    if (pid < 0) { perror("[myinit] fork"); return -1; }
    if (pid > 0) return pid;                     /* parent: keep supervising */

    /* Child: start a new session (detaches from any previous ctty and
     * makes us the session leader — the precondition for acquiring a
     * controlling tty via ioctl below).                                   */
    if (setsid() < 0) perror("[myinit] setsid");

    /* Open the serial console.  Because we're the session leader and
     * haven't got a ctty yet, the TIOCSCTTY ioctl below will attach
     * this fd's underlying tty as our ctty — which is what makes
     * Ctrl-C deliver SIGINT to the foreground process group.           */
    int tty = open("/dev/ttyS0", O_RDWR);
    if (tty < 0) { perror("[myinit] open /dev/ttyS0"); _exit(1); }
    if (ioctl(tty, TIOCSCTTY, 0) < 0) perror("[myinit] TIOCSCTTY");

    /* Wire stdin/stdout/stderr to the serial line. */
    dup2(tty, 0); dup2(tty, 1); dup2(tty, 2);
    if (tty > 2) close(tty);

    /* Reset signal dispositions — PID 1 blocks most signals by default
     * for safety; the shell wants the normal set.                        */
    struct sigaction dfl = { .sa_handler = SIG_DFL };
    sigaction(SIGINT,  &dfl, NULL);
    sigaction(SIGQUIT, &dfl, NULL);
    sigaction(SIGTSTP, &dfl, NULL);
    sigaction(SIGTTIN, &dfl, NULL);
    sigaction(SIGTTOU, &dfl, NULL);

    /* argv[0] as "-sh" makes busybox's ash run as a login shell, which
     * reads /etc/profile and gives a nicer prompt.                       */
    execl("/bin/sh", "-sh", (char *)NULL);
    perror("[myinit] exec /bin/sh");
    _exit(127);
}

int main(void) {
    /* 1. Pseudo-filesystems.  Create mountpoints first (cpio may not
     *    include them at the right modes), then mount.                    */
    mkdir("/proc", 0555);  mkdir("/sys", 0555);
    mkdir("/dev",  0755);  mkdir("/tmp", 01777);  mkdir("/run", 0755);
    try_mount("none", "/proc", "proc");
    try_mount("none", "/sys",  "sysfs");
    try_mount("none", "/dev",  "devtmpfs");
    try_mount("none", "/tmp",  "tmpfs");
    try_mount("none", "/run",  "tmpfs");

    /* 2. Banner straight to the serial device — /dev/ttyS0 exists as
     *    soon as devtmpfs is up.                                          */
    int b = open("/dev/ttyS0", O_WRONLY);
    if (b >= 0) {
        dprintf(b,
            "\n"
            "═══════════════════════════════════════════════\n"
            " alpine microvm — hand-rolled PID 1 (myinit.c)\n"
            "═══════════════════════════════════════════════\n"
            " static C binary, ~150 LOC, no busybox involvement\n"
            " poweroff: `poweroff -f`   (direct reboot syscall)\n"
            " or     :  `poweroff`      (sends SIGUSR2 to PID 1)\n"
            " exit the shell: it'll respawn — try it!\n"
            "\n");
        close(b);
    }

    /* 3. Install shutdown handlers.  BusyBox poweroff sends SIGUSR2,
     *    reboot sends SIGTERM; we catch both + SIGUSR1 for safety.       */
    struct sigaction sa = { 0 };
    sa.sa_handler = on_poweroff;
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_rebootreq;
    sigaction(SIGINT,  &sa, NULL);   /* Ctrl-Alt-Del from kernel */

    /* 4. Spawn the first shell. */
    pid_t shell = spawn_shell();

    /* 5. Supervise.  Wake on: child exit (waitpid), or signal (EINTR). */
    for (;;) {
        if (want_poweroff) {
            dprintf(2, "[myinit] shutting down\n");
            sync();
            reboot(RB_POWER_OFF);
            _exit(0);                /* unreachable once reboot() takes */
        }
        if (want_reboot) {
            dprintf(2, "[myinit] rebooting\n");
            sync();
            reboot(RB_AUTOBOOT);
            _exit(0);
        }

        int status;
        pid_t who = waitpid(-1, &status, 0);
        if (who < 0) {
            if (errno == EINTR)   continue;  /* signal woke us; recheck */
            if (errno == ECHILD)  { shell = spawn_shell(); continue; }
            perror("[myinit] waitpid");
            continue;
        }
        if (who == shell) {
            /* The interactive shell exited — respawn so the user can
             * keep going without the kernel panicking on "init died". */
            shell = spawn_shell();
        }
        /* Any other reaped child was just a shell descendant: nothing
         * more to do — the waitpid() call above already reaped it.     */
    }
}
MYINIT_C

log "compiling static myinit → $work/sbin/init"
mkdir -p "$work/sbin"
cc -static -Os -Wall -Wextra -o "$work/sbin/init" "$work/myinit.c"
strip "$work/sbin/init" 2>/dev/null || true
rm    "$work/myinit.c"
ls -lh "$work/sbin/init" >&2

# 5. Pack as cpio.gz.
log "packing cpio → $OUT_INITRAMFS"
(cd "$work" && find . -print0 \
    | cpio --null -o -H newc --quiet \
    | gzip -9) > "$CACHE_ROOT/$OUT_INITRAMFS"

log "done:"
ls -lh "$CACHE_ROOT/$KERNEL" "$CACHE_ROOT/$OUT_INITRAMFS" >&2
