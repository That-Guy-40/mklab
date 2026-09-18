#!/usr/bin/env python3
# capture-bootparams.py — capture a REAL boot_params from QEMU's -kernel loader.
#
# The foreign oracle for Spike 7a. QEMU's -kernel loader is an independent
# bootloader: it builds boot_params in guest RAM and sets cmd_line_ptr to a buffer
# holding the -append string. We let its `linuxboot` option ROM run (it populates
# the zero page AFTER reset — nothing is there at -S), then QMP `stop` and
# `pmemsave` guest physical memory FROM 0, so cmd_line_ptr is a direct offset into
# the dump. QEMU authored the pointer and the buffer; we only pass the string.
#
# Robust to runner speed: poll `stop`+dump+verify on a widening schedule until the
# capture holds a boot_params whose cmd_line_ptr resolves to our sentinel, or give
# up by name. QEMU is frozen throughout and reaped by PID. Prints the verified
# {bp_off, cmd_line_ptr, cmdline_size, cmdline} JSON on success.
#
# Usage: capture-bootparams.py <bzImage> <append> <out.bin> [<dumpsize-hex>]
import json, os, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
DECODE = os.path.join(HERE, "decode-cmdline.py")

def rpc(s, obj):
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    while True:
        buf += s.recv(65536)
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            m = json.loads(line)
            if "event" in m:          # skip async events (STOP, RESET, ...)
                continue
            return m

def verify(dump, sentinel):
    r = subprocess.run([sys.executable, DECODE, "--json", dump],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    info = json.loads(r.stdout)
    return info if info.get("cmdline") == sentinel else None

def main():
    if len(sys.argv) < 4:
        sys.exit("usage: capture-bootparams.py <bzImage> <append> <out.bin> [dumpsize-hex]")
    bz, append, out = sys.argv[1], sys.argv[2], sys.argv[3]
    dumpsz = int(sys.argv[4], 16) if len(sys.argv) > 4 else 0x40000

    tmp = tempfile.mkdtemp(prefix="cmdptr-")   # short path: AF_UNIX 108-char limit
    qmp = os.path.join(tmp, "q.sock")
    scratch = os.path.join(tmp, "dump.bin")

    cmd = ["qemu-system-x86_64", "-display", "none", "-no-reboot", "-m", "512",
           "-kernel", bz, "-append", append,
           "-qmp", f"unix:{qmp},server,nowait"]
    initrd = os.environ.get("CMDPTR_INITRD", "")
    if initrd and os.path.exists(initrd):
        cmd[cmd.index("-kernel"):cmd.index("-kernel")] = ["-initrd", initrd]

    q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    info = None
    try:
        s = None
        for _ in range(100):
            try:
                s = socket.socket(socket.AF_UNIX); s.connect(qmp); break
            except OSError:
                time.sleep(0.05)
        if not s:
            sys.exit("capture: QMP socket never came up")
        s.settimeout(10)
        h = b""
        while b"\n" not in h:
            h += s.recv(65536)
        rpc(s, {"execute": "qmp_capabilities"})
        for delay in (0.3, 0.4, 0.6, 0.9, 1.4, 2.0, 3.0):
            time.sleep(delay)
            rpc(s, {"execute": "stop"})
            r = rpc(s, {"execute": "pmemsave",
                        "arguments": {"val": 0, "size": dumpsz, "filename": scratch}})
            if "error" not in r:
                info = verify(scratch, append)
                if info:
                    os.replace(scratch, out)
                    break
            rpc(s, {"execute": "cont"})
    finally:
        try: q.send_signal(signal.SIGKILL)
        except Exception: pass
        q.wait()

    if not info:
        sys.exit("capture: no boot_params whose cmd_line_ptr resolves to the "
                 "sentinel appeared within the poll window — the capture failed")
    print(json.dumps(info))

if __name__ == "__main__":
    main()
