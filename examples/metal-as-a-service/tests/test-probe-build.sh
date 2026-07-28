#!/usr/bin/env bash
# Verdict: build-probe-initramfs.sh packages probe-init.sh into a bootable busybox
# initramfs — /init is the probe, busybox + its applets are present. The BUILD is
# host-safe (rootless cpio); only the boot is author-run. SKIPs without a static
# busybox.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need cpio gzip
trap 'cleanup_sandboxes' EXIT
maas_env

# find a static busybox the same way the builder does
BB=""
for c in "${MAAS_BUSYBOX:-}" /usr/bin/busybox "$LAB_DIR/../../micro-linux/out/x86_64/_install/bin/busybox"; do
    [[ -n "$c" && -x "$c" ]] && file "$c" 2>/dev/null | grep -q 'statically linked' && { BB="$c"; break; }
done
[[ -n "$BB" ]] || skip "no static busybox available to build the probe initramfs"

out="$SANDBOX/probe-initramfs.cpio.gz"
( MAAS_ARTIFACTS="$SANDBOX/art" "$LAB_DIR/build-probe-initramfs.sh" --out "$out" --busybox "$BB" ) \
    >/dev/null 2>&1 || fail "build-probe-initramfs.sh failed"
[[ -s "$out" ]] || fail "no initramfs produced at $out"
note "initramfs built ($(du -h "$out" | cut -f1)) ✓"

# unpack and assert /init is the probe + busybox is present
un="$SANDBOX/unpacked"; mkdir -p "$un"
( cd "$un" && zcat "$out" | cpio -idm --quiet ) || fail "could not unpack the initramfs"
[[ -f "$un/init" ]] || fail "REGRESSION: no /init in the initramfs (kernel would panic)"
head -1 "$un/init" | grep -q '^#!/bin/sh' || fail "/init is not a shell script"
grep -q 'MAAS inspection probe' "$un/init" || fail "/init is not the MAAS probe"
# NOT `[[ -f ]]`, which was the bug. The applet loop used to link EVERY name in
# `busybox --list` — including `busybox` itself — so /bin/busybox became a symlink to
# /bin/busybox: a self-reference that clobbered the binary. In the booted initramfs
# that is ELOOP; the kernel panics with "No working init found (error -40)". This test
# passed anyway, twice over: `-f` FOLLOWS the link, and the link is ABSOLUTE, so it
# escaped the unpack dir and resolved against the HOST's real /bin/busybox. The test
# was validating a file that was never in the archive.
[[ -e "$un/bin/busybox" ]] || fail "no /bin/busybox in the initramfs"
[[ ! -L "$un/bin/busybox" ]] \
    || fail "REGRESSION: /bin/busybox is a SYMLINK, not the binary. Inside the initramfs it points at itself, every applet resolves to nothing, and the kernel panics with 'No working init found (error -40)' on every boot"
"$un/bin/busybox" true 2>/dev/null \
    || fail "REGRESSION: the packaged /bin/busybox does not execute — this initramfs cannot boot, whatever the archive listing says"
[[ -L "$un/bin/sh" && -L "$un/bin/wget" ]] || fail "busybox applet symlinks (sh, wget) missing — /init tools won't resolve"
# The size is a tell the old check never read: a real static busybox is ~1 MB, and the
# broken build produced an 8 KB archive because the binary had been replaced by a link.
sz=$(stat -c %s "$un/bin/busybox" 2>/dev/null || echo 0)
[[ "$sz" -gt 200000 ]] \
    || fail "REGRESSION: /bin/busybox is only ${sz} bytes — that is not a static busybox, so nothing in the initramfs will run"
note "/init is the probe; /bin/busybox is a real ${sz}-byte binary that RUNS; sh/wget applets present ✓"

# the packaged /init still gathers facts (same logic the unit test proves) —
# smoke it in --emit mode against fixture /proc so the SHIPPED copy is exercised
fix="$SANDBOX/procfix"; mkdir -p "$fix/class/net/eth0"
printf 'processor\t: 0\nprocessor\t: 1\n' > "$fix/cpuinfo"
printf 'MemTotal:        2048000 kB\n' > "$fix/meminfo"
printf 'aa:bb:cc:dd:ee:ff\n' > "$fix/class/net/eth0/address"
j="$(PROC_ROOT="$fix" SYS_ROOT="$fix" sh "$un/init" --emit)" || fail "packaged /init --emit failed"
grep -q '"cpus":2' <<<"$j" || fail "packaged /init emitted wrong facts: $j"
note "the SHIPPED /init gathers facts (cpus=2) ✓"

pass "probe initramfs builds: /init is the probe, busybox present, shipped /init gathers facts"
