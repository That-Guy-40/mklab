#!/usr/bin/env bash
# Verdict: the `image` driver lays a golden whole-disk image down safely.
#
# The three deploy drivers differ in exactly the ways their mechanisms differ, and
# each difference is a way to break a machine silently:
#
#                   install              ramdisk               image
#   completion    node powers itself   (never — a RAM      a console marker from
#   signal        off                   service stays up)   the deployer ramdisk
#   ends with     bootdev disk         NOTHING              bootdev disk
#   persistence   full                 none                 full, and DESTRUCTIVE
#
# So this asserts what is specific to `image`: it must wait for the WRITE to finish
# before pointing the node at its disk (boot a half-written disk and you get an
# unbootable machine with nothing in the log to say why), it must then actually point
# it there (unlike ramdisk), and it must record `persistence=full` — because this
# driver overwrites the whole disk, previous tenant included, and `cleaning` must not
# be able to treat the node as if nothing was written.
#
# SAFETY: no disk is written and no image is fetched. The "golden image" is a few
# bytes of text; the BMC is the mock; a refusing `virsh` stub on PATH guarantees the
# driver cannot reach a hypervisor even if it tried.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
trap 'cleanup_sandboxes' EXIT
maas_env
maas_env_drivers
export MAAS_DRIVER_DIR="$LAB_DIR/drivers"        # the REAL image.sh
export MAAS_POLL_INTERVAL=0 MAAS_POWERON_TIMEOUT=5 MAAS_WRITE_TIMEOUT=5 MAAS_HEALTH_TIMEOUT=3
export MOCK_BMC_POWER_DIR="$SANDBOX/power"
export MAAS_NETBOOT_DIR="$SANDBOX/netboot"
IMAGE="$LAB_DIR/drivers/image.sh"

# the seam guard, same as the install driver's: a hypervisor call is both unfaithful
# and untestable, so make it impossible to make one quietly
STUBS="$SANDBOX/stubs"; mkdir -p "$STUBS"
VIRSH_LOG="$SANDBOX/virsh.log"; : > "$VIRSH_LOG"
cat >"$STUBS/virsh" <<STUB
#!/usr/bin/env bash
printf 'virsh %s\n' "\$*" >> "$VIRSH_LOG"
exit 111
STUB
chmod +x "$STUBS/virsh"; export PATH="$STUBS:$PATH"

RAW="$SANDBOX/golden.raw"; printf 'GOLDEN-WHOLE-DISK-IMAGE\n' > "$RAW"

prep() {
    ( "$MAAS" enroll "$1" --bmc-port "$2" ) >/dev/null 2>&1 || fail "enroll $1"
    ( "$MAAS" manage "$1" )  >/dev/null 2>&1 || fail "manage $1"
    ( "$MAAS" provide "$1" ) >/dev/null 2>&1 || fail "provide $1"
}

# ── 1. stage refuses an image that does not exist, and names who builds them ──
out="$( ( "$IMAGE" stage golden --from "$SANDBOX/nope.raw" ) 2>&1 )" \
    && fail "REGRESSION: stage accepted a --from path that does not exist"
grep -Fq 'nixos-ipxe-deploy' <<<"$out" \
    || fail "staging a missing image did not point at the lab that builds golden images (got: ${out//$'\n'/ })"
note "an absent golden image is refused, naming the lab that produces one  ✓"

( "$IMAGE" stage golden --from "$RAW" ) >/dev/null 2>&1 || fail "staging a real raw failed"
[[ -f "$MAAS_IMAGES_DIR/golden/disk.raw" && -f "$MAAS_IMAGES_DIR/golden/disk.raw.sig" ]] \
    || fail "stage did not produce a signed disk.raw in the image store"
( "$IMAGE" verify golden ) >/dev/null 2>&1 || fail "verify failed on a freshly staged+signed image"
note "stage copies + signs the raw; verify passes (real OpenSSL CMS)  ✓"

# ── 2. the happy path, and the ORDER that makes it bootable ──────────────────
# The console is written BY THE BOOT, not staged before it. The driver now ignores
# console output that predates the deploy (a login banner from a previous deploy used
# to satisfy the gate in one second — see await_console's header), so a pre-written
# fixture would prove only that grep works on a file we handed it. MOCK_BMC_BOOT_SAYS
# makes the mock machine speak when it is actually powered on, which is both faithful
# and the only way this can still pass.
prep node1 6240
: > "$MAAS_STATE/node1/console.log"
export MOCK_BMC_BOOT_SAYS='Deploying image golden\n2147483648 bytes (2.1 GB) copied\nDebian GNU/Linux\nnode1 login: '
: > "$MOCK_BMC_LOG"
( "$MAAS" deploy node1 --driver image --image golden ) >/dev/null 2>&1 \
    || fail "the real image driver could not take node1 to active (signed image, write completed, login reached)"
assert_state node1 active
note "the real drivers/image.sh reaches active: verify -> PXE -> write -> disk -> login  ✓"

[[ -s "$VIRSH_LOG" ]] \
    && fail "REGRESSION: the image driver called virsh — every out-of-band effect must go through the MAAS_BMC seam"
note "the driver never touched virsh: every effect went through the BMC seam  ✓"

pxe=$(grep -n "^node1 bootdev pxe"  "$MOCK_BMC_LOG" | head -1 | cut -d: -f1)
dsk=$(grep -n "^node1 bootdev disk" "$MOCK_BMC_LOG" | head -1 | cut -d: -f1)
[[ -n "$pxe" ]] || fail "REGRESSION: the deployer ramdisk was never netbooted (no 'bootdev pxe')"
[[ -n "$dsk" ]] \
    || fail "REGRESSION: the node was never pointed at its own disk. Unlike a ramdisk node, an imaged node OWNS its disk now — left on PXE it would re-image itself on every boot, forever"
[[ $pxe -lt $dsk ]] || fail "REGRESSION: 'bootdev disk' was set before 'bootdev pxe'"
note "sequence: bootdev pxe -> power on -> write -> bootdev disk -> power on  ✓"

# ── 2b. the driver must not need a capability THIS fleet's BMC lacks ─────────
# vbmcd — the backend the live fleet actually runs — answers `chassis power
# cycle` with "Invalid data field in request": it implements on/off/status and
# not cycle. The mock implemented cycle happily, so the green suite proved a
# capability the real seam does not have, and the driver would have died at its
# LAST step, AFTER overwriting the whole disk. Found before the live run by
# asking the real BMC; locked here so the mock can no longer hide it.
grep -q "^node1 power cycle" "$MOCK_BMC_LOG" \
    && fail "REGRESSION: the image driver issued 'power cycle' — vbmcd (this lab's own BMC backend) refuses that verb, so the deploy would fail after the destructive write. Use off + on, which every backend implements"
prep node1b 6245
: > "$MAAS_STATE/node1b/console.log"
export MOCK_BMC_BOOT_SAYS='Deploying image golden\n2147483648 bytes (2.1 GB) copied\nnode1b login: '
: > "$MOCK_BMC_LOG"
( export MOCK_BMC_NO_CYCLE=1; "$MAAS" deploy node1b --driver image --image golden ) >/dev/null 2>&1 \
    || fail "REGRESSION: the image driver could not deploy against a BMC that does not implement 'power cycle' — which is exactly what this lab's vbmcd does"
assert_state node1b active
note "deploys against a BMC with NO 'power cycle' (vbmcd's real limitation)  ✓"

# ── 2c. the deployer's boot script must carry ip=dhcp ───────────────────────
# The deployer fetches the image ITSELF, so the kernel has to bring eth0 up
# before the ramdisk's udhcpc can do anything. Without it the first live run
# hung on a down interface with NO output at all — indistinguishable from a
# slow write, so the operator waits out the entire write timeout for nothing.
S="$MAAS_NETBOOT_DIR/maas/node1.ipxe"
[[ -f "$S" ]] || fail "the image deploy wrote no per-node boot script at $S"
grep -q '^kernel .* ip=dhcp ' "$S" \
    || fail "REGRESSION: the deployer's kernel line has no ip=dhcp — the kernel leaves eth0 down, the ramdisk cannot fetch the image, and it stalls with no output (got: $(grep '^kernel' "$S" | cut -c1-160))"
grep -q 'imgverify disk ' "$S" \
    && fail "REGRESSION: the script says 'imgverify disk' — iPXE never downloaded an image called 'disk' (the RAMDISK fetches the raw), so the firmware refuses an unknown image and boots nothing"
grep -q 'maas.sha256=' "$S" \
    || fail "REGRESSION: no maas.sha256= on the deployer cmdline — the node would write the image and never check what landed, and the firmware cannot check it either"
# The EXACT size, from the control plane. Without it the ramdisk falls back to
# parsing dd's status line — which busybox dd does not print ("0+3201 records
# out", no byte total), so the read-back check skipped itself on the very first
# live run and reported a warning instead of verifying.
grep -qE 'maas.bytes=[0-9]+' "$S" \
    || fail "REGRESSION: no maas.bytes= on the deployer cmdline. busybox dd prints no byte total, so the ramdisk cannot work out how much to read back, and the sha256 check silently degrades to a warning — the one gate that proves what LANDED"
want_b="$(stat -c%s "$MAAS_IMAGES_DIR/golden/disk.raw")"
grep -q "maas.bytes=$want_b" "$S" \
    || fail "REGRESSION: maas.bytes does not match the staged image's real size ($want_b) — the node would hash the wrong number of bytes and fail a good image (or pass a truncated one)"
note "the deployer cmdline carries ip=dhcp + maas.sha256, and no bogus 'imgverify disk'  ✓"

# ── 3. persistence=full — the third point of the cleaning contrast (§3) ──────
[[ "$(_show node1 persistence)" == full ]] \
    || fail "REGRESSION: an image deploy did not record persistence=full. This driver overwrites the WHOLE disk; if the registry does not say so, nothing downstream can tell this node from a diskless one whose wipe is a no-op"
note "records persistence=full: the whole disk was overwritten, so cleaning is mandatory  ✓"

# ── 4. THE ONE THAT MATTERS: never boot a half-written disk ──────────────────
# If the write never completes, pointing the node at its disk produces an unbootable
# machine and nothing in the log says why. The driver must time out instead.
prep node2 6241
: > "$MAAS_STATE/node2/console.log"
export MOCK_BMC_BOOT_SAYS='Deploying image golden'   # the write never completes
: > "$MOCK_BMC_LOG"
if ( "$MAAS" deploy node2 --driver image --image golden ) >/dev/null 2>&1; then
    fail "REGRESSION: deploy 'succeeded' for a node whose image write never completed"
fi
grep -q "^node2 bootdev disk" "$MOCK_BMC_LOG" \
    && fail "REGRESSION: the driver pointed a node at a HALF-WRITTEN disk. The image write never reported completion; booting that disk gives an unbootable machine with nothing in the log to explain it"
assert_state node2 error
note "write never completes -> timeout, no boot-from-disk, node -> error  ✓"

# ── 5. …and the health gate still decides `active` ───────────────────────────
prep node3 6242
: > "$MAAS_STATE/node3/console.log"
export MOCK_BMC_BOOT_SAYS='Deploying image golden\n2147483648 bytes (2.1 GB) copied'   # no login, ever
: > "$MOCK_BMC_LOG"
if ( "$MAAS" deploy node3 --driver image --image golden ) >/dev/null 2>&1; then
    fail "REGRESSION: a node whose image was written but never booted to a login was marked active"
fi
assert_state node3 error
note "image written but it never boots -> health gate FAILS -> error (not active)  ✓"

# ── 6. verify gates before any hardware is touched ───────────────────────────
printf 'TAMPERED\n' > "$MAAS_IMAGES_DIR/golden/disk.raw"
prep node4 6243
: > "$MAAS_STATE/node4/console.log"
export MOCK_BMC_BOOT_SAYS='node4 login: '   # never emitted: the gate refuses first
: > "$MOCK_BMC_LOG"
if ( "$MAAS" deploy node4 --driver image --image golden ) >/dev/null 2>&1; then
    fail "REGRESSION: drivers/image.sh deployed a TAMPERED whole-disk image"
fi
[[ -s "$MOCK_BMC_LOG" ]] \
    && fail "REGRESSION: the node was powered/netbooted before the signature check failed — an image that overwrites the whole disk must be verified BEFORE any hardware is touched"
assert_state node4 error
note "tampered golden image: refused before the BMC is touched at all  ✓"

# ── 7. THE PUBLISHED DIGEST MUST DESCRIBE THE IMAGE ACTUALLY SERVED ─────────
# Found live 2026-07-29, and it is the STALE rung of this lab's own ladder inside the
# control plane. `deploy` used to read disk.raw.sha256 when present and only compute a
# digest otherwise — a cache with no invalidation. `stage` overwrote disk.raw and
# re-signed it while leaving the PREVIOUS build's sidecar in place, so the control
# plane handed the node `maas.sha256=` for an image it no longer had.
#
# The node then wrote its disk perfectly, read it back, and reported a mismatch it had
# not caused. The deployer's read-back check exists to catch a bad WRITE; what it
# actually caught was the control plane misdescribing what it published. Nothing else
# in the lab could see it: the signature was valid (it was re-signed), the served bytes
# were correct, and every host-side gate passed.
STALE_DIR="$MAAS_IMAGES_DIR/restaged"
printf 'GOLDEN-BUILD-ONE' > "$SANDBOX/one.raw"
printf 'GOLDEN-BUILD-TWO-ENTIRELY-DIFFERENT' > "$SANDBOX/two.raw"
( "$LAB_DIR/drivers/image.sh" stage restaged --from "$SANDBOX/one.raw" ) >/dev/null 2>&1 \
    || fail "staging the first build failed"
first_sha="$(cut -d' ' -f1 < "$STALE_DIR/disk.raw.sha256" 2>/dev/null)"
[[ -n "$first_sha" ]] || fail "stage did not record disk.raw.sha256 at all"

( "$LAB_DIR/drivers/image.sh" stage restaged --from "$SANDBOX/two.raw" ) >/dev/null 2>&1 \
    || fail "re-staging with a different build failed"
actual="$(sha256sum "$STALE_DIR/disk.raw" | cut -d' ' -f1)"
recorded="$(cut -d' ' -f1 < "$STALE_DIR/disk.raw.sha256" 2>/dev/null)"
[[ "$actual" != "$first_sha" ]] || fail "the two builds hash the same — §7 would prove nothing"
[[ "$recorded" == "$actual" ]] \
    || fail "REGRESSION: re-staging left a STALE disk.raw.sha256 (records ${recorded:0:16}…, image is ${actual:0:16}…). The control plane would publish maas.sha256= for an image it no longer has, the node would write the right disk, read it back, and report a mismatch it did not cause — exactly the 2026-07-29 live failure"
note "re-staging an image refreshes its recorded digest  ✓"

# ...and deploy must not trust that file even so. Corrupt it and require the driver to
# publish the digest of the BYTES, because "stage always refreshes it" is a promise
# about one code path and this is the value a node is told to trust.
printf '%s  disk.raw\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    > "$STALE_DIR/disk.raw.sha256"
prep node5 6244
: > "$MAAS_STATE/node5/console.log"
export MOCK_BMC_BOOT_SAYS='Deploying image restaged\n35 bytes (35 B) copied\nnode5 login: '
( "$MAAS" deploy node5 --driver image --image restaged --no-verify ) >/dev/null 2>&1
script="$(cat "$MAAS_NETBOOT_DIR/maas/node5.ipxe" 2>/dev/null)"
grep -q "maas.sha256=$actual" <<<"$script" \
    || fail "REGRESSION: the deploy published a digest from the sidecar rather than from the image's bytes. Expected maas.sha256=${actual:0:16}…; the boot script says: $(grep -o 'maas.sha256=[a-f0-9]*' <<<"$script" | head -1)"
grep -q 'deadbeef' <<<"$script" \
    && fail "REGRESSION: the deploy published the corrupted cached digest verbatim — a node would be told to expect an image that does not exist"
note "deploy computes the digest from the bytes, never from the cached sidecar  ✓"

# ── 8. A SECOND DEPLOY MUST NOT PASS ON THE FIRST ONE'S CONSOLE ─────────────
# Found live 2026-07-29. A libvirt console log is append-only across boots and this
# driver's health gate is a grep for a login banner, so the SECOND deploy on a node
# matched the FIRST deploy's banner instantly:
#
#     image: awaiting /login:/ on .../node3.log (timeout 240s)…
#     image: 'node3' booted 'golden-measured' to a login (active)     <- 1 second
#
# One second against a 240s timeout, on a node that was still powering on. Nothing
# errored: the control plane simply believed a machine was up because a previous
# machine-state had once said so. That is the LIED rung, reachable by any operator who
# deploys the same node twice — not just by this lab's runner.
#
# Here the node's console already carries a login from an earlier deploy, and the new
# deploy's boot never produces one. The gate must TIME OUT rather than match history.
# A FRESH image: §6 tampers `golden` permanently, so deploying it here would fail at
# the signature gate and this section would prove nothing. (It did, on the first
# attempt — the negative control below is what caught it.)
( "$IMAGE" stage golden2 --from "$RAW" ) >/dev/null 2>&1 || fail "staging golden2 failed"
prep node6 6246
printf 'Deploying image golden2\n2147483648 bytes (2.1 GB) copied\nnode6 login: \n' \
    > "$MAAS_STATE/node6/console.log"          # an EARLIER deploy's success, still on disk
export MOCK_BMC_BOOT_SAYS='Deploying image golden2\n2147483648 bytes (2.1 GB) copied'  # writes, never logs in
if ( "$MAAS" deploy node6 --driver image --image golden2 ) >/dev/null 2>&1; then
    fail "REGRESSION: a deploy reported success by matching a login banner left on the console by an EARLIER deploy. The node never reached a login this time; the control plane would record 'active' for a machine that never came up"
fi
assert_state node6 error
note "a stale login from a previous deploy no longer satisfies the health gate  ✓"

pass "the image driver lays a golden disk down safely: verified before any hardware, never points a node at a half-written disk, ends on bootdev disk, records persistence=full, and publishes a read-back digest computed from the bytes it actually serves rather than from a cache that re-staging can leave stale"
