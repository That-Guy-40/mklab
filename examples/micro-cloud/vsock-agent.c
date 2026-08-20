/* vsock-agent.c — a microVM's answer to "are you there?", over AF_VSOCK.
 *
 * WHY THIS EXISTS. Every channel this lab has measured so far is network-attached: a tap
 * on br-mc0, a DHCP lease, a name in dnsmasq. vsock is the first one that is NOT the
 * fabric — no bridge, no lease, no name, no DNS — and slice 5c exists to find out whether
 * the seam story (plan §8.3 shape (b)) survives a channel where the GUEST contract is
 * byte-identical and the HOST API differs in kind.
 *
 * It has to be written because the gap was never plumbing. Measured before scoping, and
 * again on 2026-08-07: the host has /dev/vhost-vsock (root:kvm 0660, and uid 1000 is in
 * kvm — usable unprivileged, like /dev/kvm); vhost_vsock/vsock/vmw_vsock_* are loaded;
 * QEMU has vhost-vsock-device on the *virtio-bus*, so it works on -M microvm and not only
 * q35; and the lab's kernel carries __initcall__kmod_vsock__ and
 * __initcall__kmod_vmw_vsock_virtio_transport__ — an initcall symbol exists only for
 * BUILT-IN code, which matters because Firecracker boots with no initramfs and a modular
 * driver would be one that never loads. All of that was fine. What the guest rootfs had
 * was `strings api1.ext4 | grep -ci vsock` = 0: busybox+musl, and busybox `nc` has no
 * AF_VSOCK. The kernel could, and nothing in the image could ask it to.
 *
 * THE POINT OF THE BINARY IS THAT IT IS ONE BINARY. The same statically-linked bytes run
 * under Firecracker and under QEMU -M microvm. If the guest-side contract really is
 * identical, no #ifdef here can be engine-specific — so there are none, and the hypothesis
 * is falsifiable: any divergence has to show up on the HOST side or not at all.
 *
 * Answers a one-line request with a one-line record. Every field is read at request time
 * from the kernel rather than captured at boot (a value cached at startup would keep being
 * served after its subject changed — the record-outlives-its-subject class this repo keeps
 * finding).
 *
 * IT ALSO RUNS COMMANDS NOW, AND THAT REVERSES A DECISION THIS COMMENT USED TO STATE.
 * The original said "deliberately not a shell", and the reason was sound: a structured
 * reply is machine-checkable. What changed is §9.3's isolation matrix. Its integrity comes
 * from ONE implementation of the probes run in every context — the runner changes, the
 * question does not — so that when two rows differ, the difference is attributable to the
 * BOUNDARY. Answering the matrix's seven questions in C here would have made the microVM
 * row the only one computed by different code, and a divergence would then be
 * indistinguishable from a bug in this file. That is precisely the failure the matrix
 * exists to avoid, so the guest runs the same shell commands every other row runs.
 *
 * What it costs, stated plainly: this image carries a remote shell reachable over vsock.
 * It is not a privilege escalation — vsock is host-to-guest only, it is not routed, and
 * the host already owns this guest's memory, disk and CPU. It is still a surface, so it
 * lives in the image that exists to BE probed and is named in that image's README. PING
 * keeps its structured reply, unchanged, so slice 5c's own tests are untouched.
 *
 *   > PING\n
 *   < MC-VSOCK-AGENT name=<mc_name> cid=<local cid> peer=<cid:port> uptime=<s> req=<n>\n
 *
 *   > EXEC <shell command>\n
 *   < <the command's stdout, verbatim, then the connection closes>
 *
 * EXEC's reply is the command's stdout and NOTHING ELSE — no banner, no trailing status —
 * because its caller is a `runner` in the isolation matrix, which expects exactly what
 * `sh -c` would have printed. Adding a frame here would mean the microVM row needed
 * un-framing that no other row needs, and the rows would stop being the same measurement.
 * stderr is left to the guest console on purpose: the probes carry their own `2>/dev/null`
 * where they want it, and silently merging streams would let a diagnostic land in a field.
 *
 * Build:  musl-gcc -static -Os -idirafter /usr/include -o mc-vsock-agent vsock-agent.c
 * Run:    mc-vsock-agent [port]        (default 1234, VMADDR_CID_ANY)
 *
 * `-idirafter` rather than `-I`: musl ships no <linux/vm_sockets.h> (it is a kernel uapi
 * header, from linux-libc-dev), but a plain -I/usr/include would put glibc's headers AHEAD
 * of musl's and the link would come apart in ways that look like unrelated bugs. -idirafter
 * appends the directory, so musl's own headers still win and only the uapi ones are picked
 * up from the system. make-vsock-rootfs.sh falls back to the definitions below if the
 * header is absent, so the agent still builds on a host without linux-libc-dev.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#if defined(MC_VSOCK_NO_UAPI)
/* Stable UAPI, restated so the agent builds with no kernel headers at all. If these ever
 * disagree with <linux/vm_sockets.h> the build below is the one that is wrong — which is
 * why the header is preferred and this is the fallback, not the default. */
#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY 0xFFFFFFFFU
#endif
struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int   svm_port;
    unsigned int   svm_cid;
    unsigned char  svm_zero[sizeof(struct sockaddr) - sizeof(unsigned short)
                            - sizeof(unsigned short) - sizeof(unsigned int)
                            - sizeof(unsigned int)];
};
#else
#include <linux/vm_sockets.h>
#endif

#define DEFAULT_PORT 1234
/* A probe reply that is silently cut in half is a wrong answer wearing a right answer's
 * clothes. 256 KiB is far above any matrix probe (the largest prints a few hundred bytes)
 * and far below anything that would stall a guest with 256M of RAM. */
#define EXEC_MAX_BYTES (256u * 1024u)
#define IOCTL_VM_SOCKETS_GET_LOCAL_CID _IO(7, 0xb9)

/* Read a whitespace-delimited value out of /proc/cmdline. The guest is told its name on
 * the kernel command line by whichever engine booted it, and both engines pass it the same
 * way — so this is one more thing that cannot quietly differ between them. */
static void cmdline_val(const char *key, char *out, size_t outsz) {
    char buf[4096];
    ssize_t n;
    int fd;
    out[0] = '\0';
    if ((fd = open("/proc/cmdline", O_RDONLY)) < 0) return;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = '\0';
    for (char *p = strstr(buf, key); p; p = strstr(p + 1, key)) {
        if (p != buf && p[-1] != ' ' && p[-1] != '\n') continue;   /* not a whole token */
        p += strlen(key);
        size_t i = 0;
        while (p[i] && p[i] != ' ' && p[i] != '\n' && i + 1 < outsz) { out[i] = p[i]; i++; }
        out[i] = '\0';
        return;
    }
}

static void uptime_str(char *out, size_t outsz) {
    char buf[128];
    ssize_t n;
    int fd;
    snprintf(out, outsz, "?");
    if ((fd = open("/proc/uptime", O_RDONLY)) < 0) return;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = '\0';
    for (ssize_t i = 0; i < n; i++) if (buf[i] == ' ') { buf[i] = '\0'; break; }
    snprintf(out, outsz, "%.*s", (int)outsz - 1, buf);
}

/* The CID the guest believes it has, asked of the kernel through /dev/vsock. This is the
 * field worth having: it is the one piece of identity vsock carries, it is assigned by the
 * HOST (guest_cid in Firecracker's config, guest-cid= on QEMU's device), and reading it
 * back from inside is how a "the seam answered for the wrong instance" mix-up would show
 * up — the class that has already bitten this repo once, via a vbmc port collision. */
static long local_cid(void) {
    unsigned int cid = 0;
    int fd = open("/dev/vsock", O_RDONLY);
    if (fd < 0) return -1;
    if (ioctl(fd, IOCTL_VM_SOCKETS_GET_LOCAL_CID, &cid) < 0) { close(fd); return -1; }
    close(fd);
    return (long)cid;
}

int main(int argc, char **argv) {
    unsigned int port = DEFAULT_PORT;
    if (argc > 1) port = (unsigned int)atoi(argv[1]);

    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) {
        /* Naming the errno matters: ENODEV here means the transport is absent, which is a
         * completely different fault from "nothing answered on the port" and would
         * otherwise be diagnosed as a host-side problem. */
        printf("MC-VSOCK-AGENT FATAL socket(AF_VSOCK) failed errno=%d (%s)\n",
               errno, strerror(errno));
        fflush(stdout);
        return 1;
    }
    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = port;
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        printf("MC-VSOCK-AGENT FATAL bind(port=%u) failed errno=%d (%s)\n",
               port, errno, strerror(errno));
        fflush(stdout);
        return 1;
    }
    if (listen(s, 8) < 0) {
        printf("MC-VSOCK-AGENT FATAL listen failed errno=%d (%s)\n", errno, strerror(errno));
        fflush(stdout);
        return 1;
    }

    char name[64];
    cmdline_val("mc_name=", name, sizeof(name));
    if (!name[0]) snprintf(name, sizeof(name), "unnamed");

    /* On the console, so a run that never gets a connection can still be told apart from
     * one where the agent never started. A silence has to mean one thing only. */
    printf("MC-VSOCK-AGENT LISTENING name=%s cid=%ld port=%u\n", name, local_cid(), port);
    fflush(stdout);

    unsigned long reqs = 0;
    for (;;) {
        struct sockaddr_vm peer;
        socklen_t plen = sizeof(peer);
        int c = accept(s, (struct sockaddr *)&peer, &plen);
        if (c < 0) { if (errno == EINTR) continue; break; }
        reqs++;

        char req[256];
        ssize_t n = read(c, req, sizeof(req) - 1);
        if (n < 0) n = 0;
        req[n] = '\0';
        for (ssize_t i = 0; i < n; i++) if (req[i] == '\n' || req[i] == '\r') { req[i] = '\0'; break; }

        /* EXEC: run it and return its stdout verbatim. See the protocol note at the top
         * for why there is no frame around the output. The cap is a guard against a probe
         * that accidentally cats something huge -- a truncated reply is a wrong answer, so
         * it is announced on the guest console rather than silently delivered. */
        if (strncmp(req, "EXEC ", 5) == 0) {
            FILE *fp = popen(req + 5, "r");
            if (!fp) {
                char e[128];
                int el = snprintf(e, sizeof(e), "MC-VSOCK-AGENT EXEC-FAILED errno=%d (%s)\n",
                                  errno, strerror(errno));
                if (el > 0) { ssize_t o = 0; while (o < el) { ssize_t w = write(c, e + o, (size_t)(el - o)); if (w <= 0) break; o += w; } }
            } else {
                char obuf[4096];
                size_t total = 0, got;
                while ((got = fread(obuf, 1, sizeof(obuf), fp)) > 0) {
                    if (total >= EXEC_MAX_BYTES) break;
                    if (total + got > EXEC_MAX_BYTES) got = EXEC_MAX_BYTES - total;
                    ssize_t o = 0;
                    while (o < (ssize_t)got) {
                        ssize_t w = write(c, obuf + o, got - (size_t)o);
                        if (w <= 0) break;
                        o += w;
                    }
                    total += got;
                }
                pclose(fp);
                if (total >= EXEC_MAX_BYTES) {
                    printf("MC-VSOCK-AGENT EXEC-TRUNCATED at %u bytes req=%s\n",
                           (unsigned)EXEC_MAX_BYTES, req + 5);
                    fflush(stdout);
                }
            }
            close(c);
            continue;
        }

        char up[32];
        uptime_str(up, sizeof(up));
        char reply[512];
        int rl = snprintf(reply, sizeof(reply),
                          "MC-VSOCK-AGENT name=%s cid=%ld peer=%u:%u uptime=%s req=%lu echo=%s\n",
                          name, local_cid(), peer.svm_cid, peer.svm_port, up, reqs, req);
        if (rl > 0) {
            ssize_t off = 0;
            while (off < rl) {
                ssize_t w = write(c, reply + off, (size_t)(rl - off));
                if (w <= 0) break;
                off += w;
            }
        }
        close(c);
    }
    close(s);
    return 0;
}
