#!/usr/bin/env bash
# Verdict: the REAL `install` driver drives entirely through the BMC seam.
#
# Every other deploy test drives `tests/mock.sh`, which proves maas-lab.sh's gate and
# rollback logic but never executes `drivers/install.sh` at all. That left the only
# shipped driver untested — and hiding in it was a seam leak: it asked
# `virsh domstate` whether the installer had finished. Two things were wrong with that:
#
#   1. FAITHFULNESS. There is no `virsh` for a machine in a rack. Reaching around the
#      BMC into the hypervisor is a capability a real control plane does not have, so
#      the driver was quietly depending on its "nodes" being VMs on the same host.
#   2. TESTABILITY. It was the one call in the lab that no seam could intercept, which
#      is exactly why nothing tested it. The two failures are the same failure.
#
# The fix: the installer finishing is observed the way real metal reports it — the node
# powers ITSELF off at the end of the kickstart/preseed, and `chassis power status`
# says so. This test drives the real driver through the mock BMC and asserts both the
# sequence and, with a refusing `virsh` stub on PATH, that the leak has not come back.
#
# SAFETY: no libvirt, no root, no boot. The `virsh` stub cannot do anything but log
# its argv and exit — a test guarding "we never call virsh" must not be able to call it.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
trap 'cleanup_sandboxes' EXIT
maas_env
maas_env_drivers
export MAAS_DRIVER_DIR="$LAB_DIR/drivers"     # the REAL install.sh, not tests/mock.sh
export MAAS_NETBOOT_DIR="$SANDBOX/netboot"    # deploy writes the per-node boot script here

# An INSTALLER-shaped image: kernel + initrd + ks.cfg, all signed — the shape
# `install.sh stage` writes, and the driver's ownership fingerprint (a `cmdline`
# file would make it the ramdisk driver's).
mk_install_image() {  # <name> [tamper]
    local d="$MAAS_IMAGES_DIR/$1" f; mkdir -p "$d"
    printf 'KERNEL-%s\n' "$1" > "$d/kernel"
    printf 'INITRD-%s\n' "$1" > "$d/initrd"
    printf '# lab kickstart\npoweroff\n' > "$d/ks.cfg"
    for f in kernel initrd ks.cfg; do
        "$LAB_DIR/drivers/verify-lib.sh" sign "$d/$f" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
            || fail "signing $1/$f failed"
    done
    [[ "${2:-}" == tamper ]] && printf 'X' | dd of="$d/kernel" bs=1 seek=1 conv=notrunc >/dev/null 2>&1
    return 0
}
mk_install_image v1

# ── the seam guard: a virsh that refuses to be a hypervisor ──────────────────
STUBS="$SANDBOX/stubs"; mkdir -p "$STUBS"
VIRSH_LOG="$SANDBOX/virsh-calls.log"; : > "$VIRSH_LOG"
cat >"$STUBS/virsh" <<STUB
#!/usr/bin/env bash
printf 'virsh %s\n' "\$*" >> "$VIRSH_LOG"
exit 111
STUB
chmod +x "$STUBS/virsh"
export PATH="$STUBS:$PATH"

# Timing knobs: the same loops, with the clock turned down. A real install waits
# minutes; here every poll is immediate and the caps are single digits.
export MAAS_POLL_INTERVAL=0 MAAS_POWERON_TIMEOUT=5 MAAS_INSTALL_TIMEOUT=8 MAAS_HEALTH_TIMEOUT=3
export MOCK_BMC_POWER_DIR="$SANDBOX/power"

prep() {  # enrol + manage + provide a node to `available`
    ( "$MAAS" enroll "$1" --bmc-port "$2" ) >/dev/null 2>&1 || fail "enroll $1"
    ( "$MAAS" manage "$1" )  >/dev/null 2>&1 || fail "manage $1"
    ( "$MAAS" provide "$1" ) >/dev/null 2>&1 || fail "provide $1"
}
# the console line the health gate greps for — the SAME terminal milestone `watch`
# renders (§5c: one declaration, two consumers)
seed_login() { printf 'Starting Login Service...\nlocalhost login: \n' > "$MAAS_STATE/$1/console.log"; }
bmc_seq() { grep -c "^$1 $2 ${3:-}" "$MOCK_BMC_LOG"; }

# ── 1. happy path: the real driver takes a node to active ────────────────────
prep node1 6230
seed_login node1
: > "$MOCK_BMC_LOG"
( export MOCK_BMC_OFF_AFTER=2; "$MAAS" deploy node1 --driver install --image v1 ) >/dev/null 2>&1 \
    || fail "the real install driver could not take node1 to active (signed image, node powers off, console shows login:)"
assert_state node1 active
note "the real drivers/install.sh reaches active: verify -> PXE -> wait -> disk -> login  ✓"

# ── 1b. the deploy answered the netboot CHAIN: a per-node script, verified boot ──
# The fleet network resolves maas/<node>.ipxe per node; a driver that writes none
# leaves its node at the dead-end script and the install never starts (that is how
# the first two live runs of the RAMDISK path failed, and this driver had the same
# hole until the chain landed).
S="$MAAS_NETBOOT_DIR/maas/node1.ipxe"
[[ -f "$S" ]] || fail "REGRESSION: deploy wrote no per-node boot script at $S — on the chain network this node falls through to the dead end and the installer never boots"
grep -q '^kernel .*inst\.ks=' "$S" \
    || fail "the boot script's kernel line carries no inst.ks= — Anaconda would boot with no kickstart and sit interactive forever (got: $(cat "$S" | tr '\n' '|'))"
grep -q '^imgverify kernel' "$S" && grep -q '^imgverify initrd' "$S" \
    || fail "REGRESSION: the payload is signed but the boot script carries no imgverify lines — the on-node half of F2 is silently dropped for the install path"
[[ -f "$MAAS_NETBOOT_DIR/maas/v1/kernel" && -f "$MAAS_NETBOOT_DIR/maas/v1/ks.cfg" ]] \
    || fail "deploy did not serve the installer payload (kernel/ks.cfg) into the docroot"
note "deploy writes the per-node chain script: inst.ks + imgverify, payload served  ✓"

# ── 2. THE SEAM GUARD ────────────────────────────────────────────────────────
if [[ -s "$VIRSH_LOG" ]]; then
    while read -r l; do note "LEAKED: $l"; done <"$VIRSH_LOG"
    fail "REGRESSION: the install driver called virsh (above). Every out-of-band effect must go through the MAAS_BMC seam — a driver that talks to the hypervisor cannot run against real metal, and cannot be tested at all"
fi
note "the driver never touched virsh: every effect went through the BMC seam  ✓"

# ── 3. the boot sequence, in the order that makes an install work ────────────
# Getting this order wrong does not error — it silently installs nothing (booting the
# disk before the installer ran) or reinstalls forever (never switching off PXE).
pxe=$(grep -n "^node1 bootdev pxe"  "$MOCK_BMC_LOG" | head -1 | cut -d: -f1)
dsk=$(grep -n "^node1 bootdev disk" "$MOCK_BMC_LOG" | head -1 | cut -d: -f1)
[[ -n "$pxe" ]] || fail "REGRESSION: the installer was never netbooted (no 'bootdev pxe')"
[[ -n "$dsk" ]] || fail "REGRESSION: the node was never switched to 'bootdev disk' — it would netboot the installer again forever"
[[ $pxe -lt $dsk ]] || fail "REGRESSION: 'bootdev disk' was set BEFORE 'bootdev pxe' — the node would boot an empty disk instead of the installer"
polls=$(bmc_seq node1 power status)
[[ $polls -ge 2 ]] \
    || fail "REGRESSION: the driver polled chassis power only $polls time(s) — it is not waiting for the installer, it is assuming it finished"
last_poll=$(grep -n "^node1 power status" "$MOCK_BMC_LOG" | tail -1 | cut -d: -f1)
[[ $last_poll -lt $dsk ]] \
    || fail "REGRESSION: the driver was still polling power AFTER switching to boot-from-disk — the wait and the switch are out of order"
note "sequence: bootdev pxe -> power on -> $polls power polls -> bootdev disk -> power on  ✓"

# ── 4. the wait is load-bearing: a node that never finishes must not proceed ──
# Without MOCK_BMC_OFF_AFTER the node stays powered on forever — the installer hung.
# The driver must time out and NEVER switch the node to boot from its unwritten disk.
prep node2 6231
seed_login node2                       # health WOULD pass — so only the wait can fail this
: > "$MOCK_BMC_LOG"
if ( "$MAAS" deploy node2 --driver install --image v1 ) >/dev/null 2>&1; then
    fail "REGRESSION: deploy 'succeeded' for a node whose installer never finished (chassis power stayed on)"
fi
grep -q "^node2 bootdev disk" "$MOCK_BMC_LOG" \
    && fail "REGRESSION: the driver switched a still-installing node to boot-from-disk — it would boot a half-written disk"
assert_state node2 error
note "installer never finishes -> timeout, no boot-from-disk, node -> error  ✓"

# ── 4b. a power BLIP is not a completion (the operator-race incident) ─────────
# A live run saw exactly this: an out-of-band power cycle passed through "off" for
# a few seconds mid-install, the driver read it as the installer finishing, and
# switched an EMPTY disk to be the boot device. The confirm poll must catch a node
# that is back on and refuse — no bootdev disk, node -> error.
prep node2b 6236
seed_login node2b
: > "$MOCK_BMC_LOG"
if ( export MOCK_BMC_OFF_AFTER=2 MOCK_BMC_BLIP=1; "$MAAS" deploy node2b --driver install --image v1 ) >/dev/null 2>&1; then
    fail "REGRESSION: a one-poll power blip was accepted as 'installer finished' — the driver would boot a half-written disk"
fi
grep -q "^node2b bootdev disk" "$MOCK_BMC_LOG" \
    && fail "REGRESSION: the driver set bootdev disk after a power BLIP — the confirm poll is not confirming"
assert_state node2b error
note "a one-poll power blip is refused: no bootdev disk, node -> error  ✓"

# ── 5. …and the health gate is still the thing that decides `active` ─────────
# node3 powers off correctly (the install "completed") but never reaches a login
# prompt. A control plane that called that success would hand out a broken machine.
prep node3 6232
rm -f "$MAAS_STATE/node3/console.log"   # no login: ever appears
: > "$MOCK_BMC_LOG"
if ( export MOCK_BMC_OFF_AFTER=1; "$MAAS" deploy node3 --driver install --image v1 ) >/dev/null 2>&1; then
    fail "REGRESSION: a node that installed but never reached a login prompt was marked active"
fi
assert_state node3 error
note "install completes but no login: -> health gate FAILS -> error (not active)  ✓"

# ── 6. the real driver's F2 verify, not the mock's ───────────────────────────
mk_install_image bad tamper
prep node4 6233
seed_login node4
: > "$MOCK_BMC_LOG"
if ( export MOCK_BMC_OFF_AFTER=1; "$MAAS" deploy node4 --driver install --image bad ) >/dev/null 2>&1; then
    fail "REGRESSION: drivers/install.sh deployed a TAMPERED image — its verify verb is not gating"
fi
[[ -s "$MOCK_BMC_LOG" ]] \
    && fail "REGRESSION: the node was powered/netbooted before the signature check failed — verify must gate BEFORE any hardware is touched"
assert_state node4 error
note "tampered image: install.sh's own verify refuses it before the BMC is touched at all  ✓"

# ── 7. ownership: describe answers positively, and refuses both wrong shapes ──
DRV="$LAB_DIR/drivers/install.sh"
( "$DRV" describe v1 ) >/dev/null 2>&1 \
    || fail "describe refused v1, an image staged in this driver's own shape (kernel+initrd+ks.cfg)"
mkdir -p "$MAAS_IMAGES_DIR/ram-shaped"
printf 'k\n' > "$MAAS_IMAGES_DIR/ram-shaped/kernel"; printf 'i\n' > "$MAAS_IMAGES_DIR/ram-shaped/initrd"
printf 'console=ttyS0\n' > "$MAAS_IMAGES_DIR/ram-shaped/cmdline"
out="$( ( "$DRV" describe ram-shaped ) 2>&1 )" \
    && fail "REGRESSION: describe accepted a RAM payload (kernel+initrd+cmdline) — the rollback incident's exact shape"
grep -q 'ramdisk' <<<"$out" || fail "describe refused the RAM shape but did not name the driver that owns it"
mkdir -p "$MAAS_IMAGES_DIR/unclaimed"; printf 'blob\n' > "$MAAS_IMAGES_DIR/unclaimed/payload.img"
( "$DRV" describe unclaimed ) >/dev/null 2>&1 \
    && fail "REGRESSION: describe accepted an image NO driver has staged or cataloged — an unclaimed image must not be deployable by anyone"
note "describe: accepts its own shape, refuses the ramdisk shape AND an unclaimed image  ✓"

# ── 8. the stage verb: catalog-driven, signs all three, writes NO cmdline file ──
CAT="$SANDBOX/install-catalog.toml"; SRC="$SANDBOX/src"; mkdir -p "$SRC"
printf 'VMLINUZ\n' > "$SRC/vmlinuz"; printf 'INITRDIMG\n' > "$SRC/initrd.img"
printf 'text\npoweroff\n' > "$SRC/lab.ks"
cat > "$CAT" <<TOML
[meta]
version = 1
[[image]]
name = "tcat"
summary = "test installer"
lab = "tests"
build = "echo build-it-yourself"
kernel = "$SRC/vmlinuz"
initrd = "$SRC/initrd.img"
ks = "$SRC/lab.ks"
cmdline = "inst.stage2=http://\${next-server}:8181/ inst.text"
health = "console"
marker = "login:"
TOML
( export MAAS_INSTALL_CATALOG="$CAT"; "$DRV" stage tcat ) >/dev/null 2>&1 \
    || fail "install.sh stage failed for a cataloged image with all artifacts present"
D="$MAAS_IMAGES_DIR/tcat"
[[ -f "$D/kernel" && -f "$D/initrd" && -f "$D/ks.cfg" ]] || fail "stage did not write kernel+initrd+ks.cfg"
[[ -f "$D/kernel.sig" && -f "$D/initrd.sig" && -f "$D/ks.cfg.sig" ]] \
    || fail "REGRESSION: stage left artifacts unsigned — the kickstart drives what gets INSTALLED, and an unsigned one is a supply-chain hole the host-side gate cannot see"
[[ -f "$D/cmdline" ]] \
    && fail "REGRESSION: install.sh stage wrote a 'cmdline' file — that triple is the RAMDISK driver's ownership fingerprint, and this image is now claimable by the wrong driver"
( "$DRV" verify tcat ) >/dev/null 2>&1 || fail "the staged image does not pass the driver's own F2 verify"
rm -f "$SRC/initrd.img"
out="$( ( export MAAS_INSTALL_CATALOG="$CAT"; "$DRV" stage tcat ) 2>&1 )" \
    && fail "REGRESSION: stage succeeded with the installer initrd missing"
grep -q 'build-it-yourself' <<<"$out" \
    || fail "stage refused a missing artifact but did not print the catalog's build command (got: ${out//$'\n'/ })"
note "stage: signs kernel+initrd+ks.cfg, no cmdline file, names the build when artifacts are missing  ✓"

pass "drivers/install.sh drives real metal through the BMC seam only: no virsh, correct boot order, the power-off wait and the health gate both load-bearing; deploy answers the netboot chain with a signed per-node script, and describe/stage enforce the driver's ownership shape"
