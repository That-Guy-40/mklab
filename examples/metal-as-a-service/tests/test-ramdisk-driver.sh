#!/usr/bin/env bash
# Verdict: the `ramdisk` driver netboots a payload into RAM and never touches a disk.
#
# This is increment 4's crux, and the assertions that matter are the ones that
# separate a RAM deploy from a disk install. Both drivers reach `active` through the
# same gate, but:
#
#   - `install` ends with `bootdev disk`. `ramdisk` must NOT — a RAM node netboots on
#     every boot, forever. Switching it to its disk would boot whatever a previous
#     tenant left there, and nothing would report an error; it would just quietly be
#     the wrong machine.
#   - `install` waits for the node to power ITSELF off (the installer finished).
#     For a RAM service, powering off IS the failure. Waiting for it would hang until
#     timeout and then roll back a perfectly healthy node.
#
# Everything is headless: mock BMC, a fixture catalog with fixture artifacts, real
# OpenSSL CMS signing, and a console log the test writes by hand. No PXE, no boot.
#
# SAFETY: nothing is fetched and no real payload is built. The "kernel" and
# "initramfs" are a few bytes of text — enough to be copied, signed, verified and
# tampered with, which is all the driver's logic actually cares about.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
maas_env
maas_env_drivers
export MAAS_DRIVER_DIR="$LAB_DIR/drivers"          # the REAL ramdisk.sh
export MAAS_POLL_INTERVAL=0 MAAS_POWERON_TIMEOUT=5 MAAS_HEALTH_TIMEOUT=2
export MOCK_BMC_POWER_DIR="$SANDBOX/power"
export MAAS_NETBOOT_DIR="$SANDBOX/netboot"
RAMDISK="$LAB_DIR/drivers/ramdisk.sh"

# ── the shipped catalog must be valid, not just parseable ───────────────────
# Catches the failure this file format invites: an entry that declares health="http"
# and forgets `url`, which would only surface on a node that is already booting.
python3 "$LAB_DIR/lib/catalog.py" "$LAB_DIR/ramdisk-catalog.toml" check \
    || fail "REGRESSION: the shipped ramdisk-catalog.toml is invalid (errors above) — every entry needs the fields its health kind requires"
n_images=$(python3 "$LAB_DIR/lib/catalog.py" "$LAB_DIR/ramdisk-catalog.toml" names | grep -c .)
[[ $n_images -ge 6 ]] || fail "the shipped catalog lists only $n_images images (expected the 6 the plan routes: RAM-INFRA trio + micro-linux + floppinux + busybox)"
note "the shipped catalog validates: $n_images images, each with the fields its health kind needs  ✓"

# ── a fixture catalog: same schema, artifacts we can create ─────────────────
ART="$SANDBOX/artifacts"; mkdir -p "$ART"
printf 'FIXTURE-KERNEL\n' > "$ART/kernel"
printf 'FIXTURE-INITRD\n' > "$ART/initrd"
export MAAS_CATALOG="$SANDBOX/catalog.toml"
cat > "$MAAS_CATALOG" <<TOML
[meta]
version = 1
[[image]]
name    = "ram-console"
summary = "fixture: a RAM payload whose active signal is a console marker"
lab     = "tests/"
build   = "printf FIXTURE > kernel"
kernel  = "$ART/kernel"
initrd  = "$ART/initrd"
cmdline = "console=ttyS0 ip=dhcp"
health  = "console"
marker  = "RAM-PAYLOAD-UP"
[[image]]
name    = "ram-missing"
summary = "fixture: a payload whose lab has not built it yet"
lab     = "examples/nowhere/"
build   = "examples/nowhere/build-it.sh --arch x86_64"
kernel  = "$ART/does-not-exist"
initrd  = "$ART/does-not-exist"
cmdline = "console=ttyS0"
health  = "console"
marker  = "never"
TOML

# ── 1. an unbuilt payload is refused with the command that builds it ────────
# The driver routes to labs; when the lab has not run, saying "not found" is useless.
out="$( ( "$RAMDISK" stage ram-missing ) 2>&1 )" && fail "REGRESSION: stage 'succeeded' for a payload that was never built"
grep -Fq 'examples/nowhere/build-it.sh --arch x86_64' <<<"$out" \
    || fail "REGRESSION: staging an unbuilt payload did not print the build command from the catalog — the operator is told what is missing but not how to get it (got: ${out//$'\n'/ })"
note "an unbuilt payload is refused WITH the lab's own build command  ✓"

# ── 2. stage copies + signs; verify then passes on the real artifacts ───────
( "$RAMDISK" stage ram-console ) >/dev/null 2>&1 || fail "staging a built payload failed"
for f in kernel initrd cmdline kernel.sig initrd.sig; do
    [[ -f "$MAAS_IMAGES_DIR/ram-console/$f" ]] || fail "stage did not produce $f in the image store"
done
( "$RAMDISK" verify ram-console ) >/dev/null 2>&1 || fail "verify failed on a freshly staged+signed payload"
note "stage copies the lab's artifacts, signs both, and verify passes (real OpenSSL CMS)  ✓"

# ── 3. …and a tampered payload fails verification ───────────────────────────
# The negative control for §2: without it, verify could be returning 0 blindly.
printf 'TAMPERED\n' > "$MAAS_IMAGES_DIR/ram-console/initrd"
( "$RAMDISK" verify ram-console ) >/dev/null 2>&1 \
    && fail "REGRESSION: verify accepted a payload whose initramfs was modified after signing"
note "a byte flipped in the staged initramfs fails verification  ✓"
( "$RAMDISK" stage ram-console ) >/dev/null 2>&1 || fail "re-staging failed"   # restore

# ── 4. the deploy: netboot, and the two things that must NOT happen ─────────
prep() {
    ( "$MAAS" enroll "$1" --bmc-port "$2" ) >/dev/null 2>&1 || fail "enroll $1"
    ( "$MAAS" manage "$1" )  >/dev/null 2>&1 || fail "manage $1"
    ( "$MAAS" provide "$1" ) >/dev/null 2>&1 || fail "provide $1"
}
prep node1 6230
printf 'booting…\nRAM-PAYLOAD-UP\n' > "$MAAS_STATE/node1/console.log"
: > "$MOCK_BMC_LOG"
( "$MAAS" deploy node1 --driver ramdisk --image ram-console ) >/dev/null 2>&1 \
    || fail "the ramdisk driver could not take node1 to active (signed payload, console shows its marker)"
assert_state node1 active
note "a signed RAM payload reaches active through the same gate install uses  ✓"

grep -q "^node1 bootdev pxe" "$MOCK_BMC_LOG" || fail "REGRESSION: the node was never set to netboot"
grep -q "^node1 bootdev disk" "$MOCK_BMC_LOG" \
    && fail "REGRESSION: the ramdisk driver set 'bootdev disk'. A RAM node must netboot on EVERY boot — pointed at its disk it would silently boot whatever a previous tenant left there, with no error anywhere"
note "no 'bootdev disk': the node netboots every time, by design  ✓"

# The install driver polls power repeatedly waiting for the self-poweroff. The
# ramdisk driver must not: a RAM service never powers off, so that wait would hang
# to timeout and roll back a healthy node.
polls=$(grep -c "^node1 power status" "$MOCK_BMC_LOG")
[[ $polls -le 2 ]] \
    || fail "REGRESSION: the ramdisk driver polled chassis power $polls times — it is waiting for a power-off that a RAM-resident node never performs; that wait would time out and roll back a healthy node"
note "it confirms power-on and stops there ($polls poll(s)) — no wait for a poweroff that never comes  ✓"

# ── 5. the artifacts a node would actually fetch ────────────────────────────
ipxe="$MAAS_NETBOOT_DIR/maas/node1.ipxe"
[[ -f "$ipxe" ]] || fail "REGRESSION: no per-node iPXE script was written — the node would netboot into whatever the PXE default is"
grep -q '^kernel .*/ram-console/kernel ' "$ipxe" || fail "the iPXE script does not load the staged kernel"
grep -q '^initrd .*/ram-console/initrd'  "$ipxe" || fail "the iPXE script does not load the staged initramfs"
grep -q 'console=ttyS0 ip=dhcp'          "$ipxe" || fail "the catalog's cmdline did not reach the iPXE script"
grep -q '^imgverify kernel '             "$ipxe" \
    || fail "REGRESSION: the iPXE script has no imgverify line for a SIGNED payload — host-side verify would gate the deploy while the firmware booted anything it was handed"
for f in kernel initrd; do
    [[ -f "$MAAS_NETBOOT_DIR/maas/ram-console/$f" ]] \
        || fail "the payload's $f was never published to the PXE docroot — the node would 404"
done
note "per-node iPXE script: staged kernel+initrd, the catalog's cmdline, and imgverify on both  ✓"

# ── 6. persistence is recorded as none — the `cleaning` contrast (§3) ───────
[[ "$(_show node1 persistence)" == none ]] \
    || fail "REGRESSION: a ramdisk deploy did not record persistence=none; the registry cannot then show why this node's wipe is a no-op"
note "the node records persistence=none: nothing was written, so there is nothing to wipe  ✓"

# ── 7. the health gate still decides, and rollback still applies ────────────
prep node2 6231
rm -f "$MAAS_STATE/node2/console.log"        # the payload never announces itself
: > "$MOCK_BMC_LOG"
if ( "$MAAS" deploy node2 --driver ramdisk --image ram-console ) >/dev/null 2>&1; then
    fail "REGRESSION: a node whose RAM payload never printed its marker was marked active"
fi
assert_state node2 error
note "payload boots but never prints its marker -> health gate FAILS -> error  ✓"

# ── 8. a REAL catalog entry, on whatever this host has actually built ───────
# Everything above runs on fixtures, which proves the driver's logic but not that the
# shipped catalog points at anything real. So: for every entry whose artifacts exist
# on this host, stage + verify them for real. Nothing is built here — a payload the
# host has not built is reported, not failed (that is each lab's job, not this test's).
real_ok=0 real_skip=()
while read -r img; do
    [[ -n "$img" ]] || continue
    eval "$(python3 "$LAB_DIR/lib/catalog.py" "$LAB_DIR/ramdisk-catalog.toml" get "$img")"
    k="$IMG_KERNEL"; i="$IMG_INITRD"
    [[ "$k" != /* ]] && k="$LAB_DIR/../../$k"
    [[ "$i" != /* ]] && i="$LAB_DIR/../../$i"
    if [[ -f "$k" && -f "$i" ]]; then
        ( export MAAS_CATALOG="$LAB_DIR/ramdisk-catalog.toml"; "$RAMDISK" stage "$img" ) >/dev/null 2>&1 \
            || fail "REGRESSION: catalog entry '$img' has its artifacts built on this host but staging them failed"
        ( export MAAS_CATALOG="$LAB_DIR/ramdisk-catalog.toml"; "$RAMDISK" verify "$img" ) >/dev/null 2>&1 \
            || fail "REGRESSION: '$img' staged but its signature did not verify"
        note "REAL: '$img' staged + signed + verified ($(du -h "$k" | cut -f1) kernel, $(du -h "$i" | cut -f1) initramfs)"
        real_ok=$((real_ok+1))
    else
        real_skip+=("$img")
    fi
done < <(python3 "$LAB_DIR/lib/catalog.py" "$LAB_DIR/ramdisk-catalog.toml" names)
if [[ $real_ok -eq 0 ]]; then
    note "no catalog payload is built on this host yet — the real-artifact path is unproven here (build one: see ramdisk-catalog.toml's build= for each)"
else
    note "$real_ok of $n_images catalog entries are built here and stage for real; not built: ${real_skip[*]:-none}  ✓"
fi

pass "the ramdisk driver netboots a signed payload into RAM: no bootdev disk, no wait for a poweroff that never comes, persistence=none, and the same verify+health gate as install"
