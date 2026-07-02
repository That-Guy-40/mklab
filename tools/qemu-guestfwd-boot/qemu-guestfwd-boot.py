#!/usr/bin/env python3
# qemu-guestfwd-boot.py — drive a QEMU VM, sudo-free, and serve it files with
# NO host ports and NO server process.
#
# This is a pure-Python operationalization of the reusable essence of System
# Transparency's stboot QEMU test harness (integration/qemu-boot-from-net.sh).
# The distinctive trick is QEMU's user-net `guestfwd`:
#
#     -nic user,model=e1000,guestfwd=tcp:10.0.2.50:80-cmd:<responder>
#
# slirp intercepts the guest's TCP connections to 10.0.2.50:80 and, per
# connection, runs <responder> with the guest's byte stream wired to its
# stdin/stdout. So the "web server" is a short-lived subprocess that speaks one
# HTTP request/response over stdio and exits — no listening socket on the host,
# no bound port, no root, nothing to clean up. This tool IS that responder (its
# `serve-http` subcommand, a faithful port of the harness's serve-http.go) and
# also the launcher + serial success-gate (a port of look-for.go): it boots the
# VM headless, tees the serial console to a log, and exits 0 the moment a serial
# line matches --expect (else times out and kills QEMU by PID).
#
# Provenance: derived from stboot v0.7.0 (git.glasklar.is/system-transparency/
# core, BSD-2-Clause). The byte-exact Go originals are vendored under vendor/
# with attribution + sha256 — see vendor/README.md.
#
# No sudo, stdlib only. Kills QEMU by recorded PID (never by pattern).
#
# Usage (two roles):
#   Launch + gate:
#     qemu-guestfwd-boot.py run --disk DISK.img --www DIR \
#         --expect "some-host login: " [--timeout 300] [options...]
#   Per-connection HTTP responder (normally invoked by QEMU, not by hand):
#     qemu-guestfwd-boot.py serve-http -d DIR   < request  > response

import argparse
import mimetypes
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# serve-http  — port of integration/serve-http/serve-http.go
#
# Reads ONE HTTP request from stdin, serves the named static file from a
# directory, writes the response to stdout, exits. QEMU's guestfwd `cmd:` runs
# one of these per guest TCP connection, so one-request-per-process is exactly
# right (matching the Go original, which also handles a single request).
# ---------------------------------------------------------------------------
def serve_http(argv):
    ap = argparse.ArgumentParser(prog="qemu-guestfwd-boot.py serve-http")
    ap.add_argument("-d", "--dir", default=".",
                    help="directory with static files to serve")
    args = ap.parse_args(argv)

    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    # Read the request line + headers (up to the blank CRLF line).
    header_bytes = b""
    while b"\r\n\r\n" not in header_bytes:
        chunk = stdin.read(1)
        if not chunk:
            break
        header_bytes += chunk
        if len(header_bytes) > 65536:  # runaway guard
            break

    try:
        request_line = header_bytes.split(b"\r\n", 1)[0].decode("latin-1")
        method, raw_path, _proto = request_line.split(" ", 2)
    except ValueError:
        _send_simple(stdout, 400, "Bad Request")
        return 0

    if method not in ("GET", "HEAD"):
        _send_simple(stdout, 405, "Method Not Allowed")
        return 0

    # Strip any query string, then eliminate evil ".." like the Go original
    # (path.Clean): normpath anchored at "/" collapses any "../" so the request
    # path can't escape the served directory. We deliberately do NOT resolve the
    # final file's symlink target for containment — matching http.ServeFile,
    # served files may themselves be symlinks pointing outside the dir (the
    # stboot harness serves its OS package .zip as exactly such a symlink).
    url_path = raw_path.split("?", 1)[0]
    clean = os.path.normpath(os.path.join("/", url_path))  # anchors at "/"
    file_path = os.path.join(args.dir, clean.lstrip("/"))

    if not os.path.isfile(file_path):  # follows symlinks, like os.Open
        _send_simple(stdout, 404, "Not Found")
        return 0

    size = os.path.getsize(file_path)
    ctype = mimetypes.guess_type(file_path)[0] or "application/octet-stream"
    headers = (
        f"HTTP/1.1 200 OK\r\n"
        f"Content-Type: {ctype}\r\n"
        f"Content-Length: {size}\r\n"
        f"Accept-Ranges: none\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    ).encode("latin-1")
    stdout.write(headers)
    if method == "HEAD":
        stdout.flush()
        return 0
    with open(file_path, "rb") as f:
        shutil.copyfileobj(f, stdout, length=1 << 20)  # stream in 1 MiB chunks
    stdout.flush()
    return 0


def _send_simple(stdout, code, reason):
    body = f"{code} {reason}\n".encode("latin-1")
    stdout.write(
        f"HTTP/1.1 {code} {reason}\r\n"
        f"Content-Type: text/plain; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n"
        f"\r\n".encode("latin-1")
    )
    stdout.write(body)
    stdout.flush()


# ---------------------------------------------------------------------------
# run  — launch QEMU headless, gate on a serial marker (port of look-for.go)
# ---------------------------------------------------------------------------
_ANSI = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]")  # strip CSI escapes for matching


def run(argv):
    ap = argparse.ArgumentParser(prog="qemu-guestfwd-boot.py run")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--disk", help="raw disk image booted via -drive")
    src.add_argument("--cdrom", help="ISO booted via -cdrom")
    ap.add_argument("--www",
                    help="directory served to the guest over slirp guestfwd "
                         "(omit for a plain user-net VM with no file serving)")
    ap.add_argument("--guest-addr", default="10.0.2.50:80",
                    help="guest-visible IP:PORT the served dir answers on "
                         "(default 10.0.2.50:80)")
    ap.add_argument("--expect", required=True,
                    help="exit 0 when a serial line contains this string")
    ap.add_argument("--timeout", type=int, default=300,
                    help="seconds to wait for --expect before giving up (default 300)")
    ap.add_argument("--mem", default="4G", help="guest RAM (default 4G)")
    ap.add_argument("--bios", default="/usr/share/ovmf/OVMF.fd",
                    help="firmware blob for -bios (default OVMF.fd; "
                         "pass '' for SeaBIOS/default)")
    ap.add_argument("--nic-model", default="e1000",
                    help="slirp NIC model (default e1000 — the model proven to "
                         "carry u-root/stboot DHCP over slirp)")
    ap.add_argument("--no-rng", action="store_true",
                    help="omit the virtio-rng entropy device (added by default)")
    ap.add_argument("--log", help="write the full serial console here "
                                  "(default: <disk|cdrom>.serial.log)")
    ap.add_argument("--qemu", default="qemu-system-x86_64", help="QEMU binary")
    ap.add_argument("extra", nargs="*",
                    help="extra QEMU args after '--' (e.g. -smp 2)")
    args = ap.parse_args(argv)

    boot_file = args.disk or args.cdrom
    if not os.path.isfile(boot_file):
        print(f"error: boot image not found: {boot_file}", file=sys.stderr)
        return 2
    log_path = args.log or (boot_file + ".serial.log")

    self_py = os.path.abspath(__file__)
    python = sys.executable or "python3"

    cmd = [args.qemu, "-accel", "kvm", "-accel", "tcg",
           "-nographic", "-no-reboot", "-m", args.mem]
    if args.bios:
        cmd += ["-bios", args.bios]
    if not args.no_rng:
        cmd += ["-object", "rng-random,filename=/dev/urandom,id=rng0",
                "-device", "virtio-rng-pci,rng=rng0"]

    nic = f"user,model={args.nic_model}"
    if args.www:
        www = os.path.abspath(args.www)
        responder = f"{python} {self_py} serve-http -d {www}"
        # QEMU parses ',' as an option separator; a comma in these paths would
        # corrupt the -nic value. Spaces are fine (not separators).
        if "," in responder:
            print("error: --www path / interpreter path contains a comma, "
                  "which QEMU's -nic parser cannot handle", file=sys.stderr)
            return 2
        nic += f",guestfwd=tcp:{args.guest_addr}-cmd:{responder}"
    cmd += ["-nic", nic]

    if args.disk:
        cmd += ["-drive", f"file={args.disk},format=raw"]
    else:
        cmd += ["-cdrom", args.cdrom]
    if args.extra:
        cmd += args.extra

    print(f"==> serial log: {log_path}", file=sys.stderr)
    print(f"==> waiting for: {args.expect!r}  (timeout {args.timeout}s)",
          file=sys.stderr)
    print("==> qemu: " + " ".join(cmd), file=sys.stderr)

    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    want = args.expect.encode("latin-1", "replace")
    deadline = time.monotonic() + args.timeout
    line = b""              # bytes of the current (possibly unterminated) line
    matched = False
    fd = proc.stdout.fileno()

    with open(log_path, "wb") as logf:
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    print("error: timeout, marker not seen", file=sys.stderr)
                    break
                ready, _, _ = select.select([fd], [], [], min(remaining, 1.0))
                if not ready:
                    continue
                chunk = os.read(fd, 65536)
                if not chunk:  # QEMU exited before the marker
                    print("error: QEMU exited before the marker appeared",
                          file=sys.stderr)
                    break
                logf.write(chunk)
                logf.flush()
                os.write(sys.stdout.fileno(), chunk)  # mirror to our stdout
                # Track the current line (login prompts have NO trailing '\n',
                # so match on the running line buffer, not on completed lines).
                line += chunk
                if b"\n" in line:
                    line = line.rsplit(b"\n", 1)[1]
                if want in _ANSI.sub(b"", line):
                    matched = True
                    print(f"\n==> matched: {args.expect!r}", file=sys.stderr)
                    break
        finally:
            _kill_by_pid(proc)

    return 0 if matched else 1


def _kill_by_pid(proc):
    """Terminate the QEMU child by its recorded PID (never by pattern)."""
    if proc.poll() is not None:
        return
    try:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    except ProcessLookupError:
        pass


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__ or "", file=sys.stderr)
        print("subcommands: run | serve-http", file=sys.stderr)
        return 0 if len(sys.argv) >= 2 else 1
    sub, rest = sys.argv[1], sys.argv[2:]
    if sub == "serve-http":
        return serve_http(rest)
    if sub == "run":
        return run(rest)
    print(f"error: unknown subcommand {sub!r} (want: run | serve-http)",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
