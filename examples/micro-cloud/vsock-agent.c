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
 * Answers a one-line request with a one-line record. Deliberately not a shell: the reply
 * is machine-checkable, and every field is read at request time from the kernel rather
 * than captured at boot (a value cached at startup would keep being served after its
 * subject changed — the record-outlives-its-subject class this repo keeps finding).
 *
 *   > PING\n
 *   < MC-VSOCK-AGENT name=<mc_name> cid=<local cid> peer=<cid:port> uptime=<s> req=<n>\n
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
