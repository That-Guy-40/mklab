#!/usr/bin/env python3
"""vsock-probe.py — ask a microVM's agent the same question over two different host APIs.

THIS FILE IS THE MEASUREMENT. Slice 5c's hypothesis (DEFERRED.md) is that vsock is a
*sharper* seam row than `stop`: there the intent matched and the channel differed, here
the GUEST-side contract is byte-identical while the HOST-side API differs in kind. The
guest half of that claim is settled by construction — one statically linked
`mc-vsock-agent`, the same bytes in both images, no engine-specific branch anywhere in it.
The host half is this file, and it is written as two clearly separate implementations
rather than one clever abstraction, because collapsing them would hide exactly the
difference the slice exists to measure.

    firecracker   a UNIX socket, plus a text handshake:
                  connect(uds_path) -> send "CONNECT <port>\\n" -> expect "OK <n>\\n"
                  There is no AF_VSOCK on the host side at all. The host never names a CID.

    qemu          a real AF_VSOCK socket:
                  connect((guest_cid, port))
                  No handshake, no path, no file. The host names the guest by CID.

If that holds, "the same channel" costs two different host implementations and one guest
implementation — which is the shape §8.3 (b) predicts, arrived at from a channel that has
nothing to do with the fabric.

Exit codes:  0 answered · 1 refused/failed (reason on stderr) · 2 usage
"""
import argparse
import socket
import sys
import time


def probe_firecracker(uds_path, port, request, timeout):
    """Firecracker's host end is a unix socket with a text handshake in front of it.

    The handshake is the whole asymmetry. Firecracker is a userspace vsock device: it never
    creates an AF_VSOCK socket on the host, so it cannot be addressed by CID from here.
    "Which guest?" is answered by WHICH UNIX SOCKET PATH you opened, not by a number.
    """
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(uds_path)
    s.sendall(f"CONNECT {port}\n".encode())

    # The handshake reply is line-oriented and must be read a byte at a time: read(1024)
    # would happily swallow the agent's answer along with the "OK <n>" line and then the
    # caller would be parsing two records glued together.
    line = b""
    while not line.endswith(b"\n"):
        b = s.recv(1)
        if not b:
            raise ConnectionError(
                f"firecracker closed the connection during the handshake "
                f"(got {line!r}) — nothing in the guest is listening on port {port}")
        line += b
    if not line.startswith(b"OK"):
        raise ConnectionError(
            f"firecracker refused the CONNECT handshake: {line!r}. "
            f"That is the HOST refusing, not the guest: it means no guest-side listener "
            f"on port {port} when the connection was made")
    s.sendall(request.encode())
    return s, line.strip().decode()


def probe_qemu(cid, port, request, timeout):
    """QEMU's host end is a real AF_VSOCK socket, addressed by CID.

    No path, no handshake, no file on disk — the kernel's vhost_vsock driver is the
    endpoint. `guest-cid=` on the device is a namespace shared by every vhost-vsock guest
    on the host, which is why a collision here is a real hazard and not a hypothetical.
    """
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((cid, port))
    s.sendall(request.encode())
    return s, None


def read_reply(s, timeout, to_eof=False):
    """Read one line (PING) or everything up to EOF (EXEC).

    EXEC's payload is a command's stdout and may be many lines, so stopping at the first
    newline would silently return a PREFIX -- the same shape of bug as the unanchored
    extractor in test-clone-entropy.sh, which matched a truncated record and returned its
    first field as the answer. A short read here would be indistinguishable from a short
    command, so it is the caller who says which it expects.
    """
    s.settimeout(timeout)
    buf = b""
    deadline = time.monotonic() + timeout
    while (to_eof or b"\n" not in buf) and time.monotonic() < deadline:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
    return buf.decode(errors="replace") if to_eof else buf.decode(errors="replace").strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--engine", required=True, choices=("firecracker", "qemu"))
    ap.add_argument("--uds", help="firecracker: the vsock uds_path from its config")
    ap.add_argument("--cid", type=int, help="qemu: the guest-cid= given to vhost-vsock-device")
    ap.add_argument("--port", type=int, default=1234)
    ap.add_argument("--request", default="PING\n")
    ap.add_argument("--exec", dest="exec_cmd",
                    help="run a shell command in the guest and print ONLY its stdout "
                         "(no handshake banner, no framing) -- the form the isolation "
                         "matrix's runners need, since every other row is measured by "
                         "running exactly this command through a different boundary")
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--retries", type=int, default=1,
                    help="attempts while the guest is still booting its agent")
    args = ap.parse_args()
    if args.exec_cmd:
        args.request = "EXEC " + args.exec_cmd + "\n"

    if args.engine == "firecracker" and not args.uds:
        ap.error("--engine firecracker needs --uds (its host end is a unix socket path)")
    if args.engine == "qemu" and args.cid is None:
        ap.error("--engine qemu needs --cid (its host end is an AF_VSOCK address)")

    last = None
    for attempt in range(1, args.retries + 1):
        try:
            if args.engine == "firecracker":
                s, hs = probe_firecracker(args.uds, args.port, args.request, args.timeout)
            else:
                s, hs = probe_qemu(args.cid, args.port, args.request, args.timeout)
            reply = read_reply(s, args.timeout, to_eof=bool(args.exec_cmd))
            s.close()
            if not reply:
                last = "connected, but the guest sent no reply before the timeout"
                raise ConnectionError(last)
            if args.exec_cmd:
                # AN AGENT THAT PREDATES EXEC ANSWERS WITH ITS PING RECORD. It does not
                # error -- unknown requests fall through to the default reply -- so the
                # caller would receive a banner and use it as the command's output. Caught
                # for real on 2026-08-20 against a rootfs built minutes before EXEC existed:
                # every probe came back as `MC-VSOCK-AGENT name=... echo=EXEC <the command>`,
                # which a matrix row would have recorded as a process count.
                #
                # It is refused rather than returned, because a wrong answer that looks like
                # an answer is worse than no answer -- and the echo= field means the reply
                # even CONTAINS the request, which is exactly how a stale record passes a
                # cursory read.
                if reply.startswith("MC-VSOCK-AGENT "):
                    print(f"VSOCK-PROBE-FAILED the guest answered EXEC with the agent's own "
                          f"PING record, so its agent predates EXEC and never ran the "
                          f"command. Rebuild the image with make-vsock-rootfs.sh. Got: "
                          f"{reply.strip()[:160]}", file=sys.stderr)
                    return 2
                # Verbatim: no HANDSHAKE line, no strip. The caller is standing in for
                # `sh -c`, and anything added here would have to be removed there.
                sys.stdout.write(reply)
                return 0
            if hs:
                print(f"HANDSHAKE {hs}")
            print(reply)
            return 0
        except (OSError, ConnectionError) as e:
            last = f"{type(e).__name__}: {e}"
            if attempt < args.retries:
                time.sleep(0.5)

    print(f"VSOCK-PROBE-FAILED engine={args.engine} after {args.retries} attempt(s): {last}",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
