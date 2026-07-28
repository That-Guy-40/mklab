#!/usr/bin/env bash
# Verdict: an A/B rollback restores the DRIVER along with the image, refuses to roll back
# at all when it cannot, and no driver is ever handed an image it does not own.
#
# THE INCIDENT — the first defect the live path found in the control plane itself.
# `apply` converged node1 onto its declared `install/almalinux9-ks` while the node was
# running `ramdisk/micro-linux-x86_64`. The install failed, so §4b rolled back to the
# previous image — through the NEW driver, because `cmd_deploy` had already overwritten
# the node's driver field and reused `$drv` for the rollback:
#
#     $ ps: drivers/install.sh deploy node1 micro-linux-x86_64 previous
#
# A RAM payload, handed to the installer. `install.sh` netbooted the live node and
# entered `await_power off` — waiting for an installer that did not exist to power off a
# machine sitting happily at a micro-linux login prompt. Timeout: 120 x 15 = 1800s. The
# operator saw a run with no output for half an hour and reasonably called it a hang.
#
# And the registry recorded the pair as fact:
#
#     driver      install
#     image       micro-linux-x86_64 (previous: -)
#
# A combination that cannot exist, written down as though it did — the LIED rung of this
# lab's own chaos ladder, in the control plane rather than in the harness.
#
# Why no test caught it: every rollback test deployed BOTH images with the SAME driver,
# and the shared `make_image` fixture produces one generic payload with no notion of
# which driver owns it. The mock could not express the mismatch, so the mismatch could
# not fail. (Untestable and unfaithful are usually the same code.)
#
# The three properties, each asserted below:
#
#   1. the rollback runs the PREVIOUS driver, and the registry follows the machine back
#   2. with no recoverable previous driver it REFUSES to roll back -> error, honestly,
#      rather than rolling back through the wrong one
#   3. `gate` asks the driver `describe <image>` first — a driver that cannot describe an
#      image must not be handed it
#
# SAFETY: two mock drivers in the sandbox, a mock BMC, no libvirt, no netboot, no power.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl
trap 'cleanup_sandboxes' EXIT
maas_env
maas_env_drivers

# ── two drivers that each own their OWN images ─────────────────────────────
# The fixture the old tests lacked. `drvA` owns a*, `drvB` owns b* — declared by
# `describe`, exactly as the real ramdisk driver declares ownership through its catalog.
export MAAS_DRIVER_DIR="$SANDBOX/drivers"
mkdir -p "$MAAS_DRIVER_DIR"
make_driver() {  # make_driver <name> <owned-prefix>
    cat > "$MAAS_DRIVER_DIR/$1.sh" <<EOS
#!/usr/bin/env bash
# fixture driver '$1' — owns images matching '$2*'
verb="\${1:-}"; shift || true
log() { printf '%s %s\n' "$1" "\$*" >> "\$DRV_LOG"; }
case "\$verb" in
  describe) log "describe \$1"
            [[ -z "\${1:-}" || "\${1#$2}" != "\$1" ]] || { echo "$1: not my image '\$1'" >&2; exit 1; }
            echo "$1: owns $2*" ;;
  verify)   log "verify \$1" ;;
  deploy)   log "deploy \$1 \$2 \$3"
            [[ "\${DEPLOY_FAIL:-}" == "\$2" ]] && exit 1; exit 0 ;;
  health)   log "health \$1 \$2"
            [[ "\${HEALTH_FAIL:-}" == "\$2" ]] && exit 1; exit 0 ;;
  *) exit 2 ;;
esac
EOS
    chmod +x "$MAAS_DRIVER_DIR/$1.sh"
}
make_driver drvA a
make_driver drvB b
export DRV_LOG="$SANDBOX/drv.log"; : > "$DRV_LOG"
make_image a1
make_image b1

prep() { ( "$MAAS" enroll "$1" --bmc-port "$2" ) >/dev/null 2>&1 || fail "enroll $1"
         ( "$MAAS" manage  "$1" ) >/dev/null 2>&1 || fail "manage $1"
         ( "$MAAS" provide "$1" ) >/dev/null 2>&1 || fail "provide $1"; }

# ── 1. seed a node on drvA/a1 ──────────────────────────────────────────────
prep node1 6230
( "$MAAS" deploy node1 --driver drvA --image a1 ) >/dev/null 2>&1 \
    || fail "could not seed node1 on drvA/a1"
assert_state node1 active
note "node1 seeded active on drvA/a1  ✓"

# ── 2. a DIFFERENT driver's deploy fails -> rollback via the ORIGINAL driver ─
# The live shape exactly: drvB/b1 is declared, fails, and a1 must come back through
# drvA — never through drvB.
: > "$DRV_LOG"
HEALTH_FAIL=b1 "$MAAS" deploy node1 --driver drvB --image b1 >/dev/null 2>&1

# The driver-log assertions come FIRST, deliberately. A rollback through the wrong driver
# also leaves the node in `error`, and a bare "expected active, got error" tells the
# reader nothing about which of the two went wrong.
grep -q '^drvA deploy node1 a1 previous$' "$DRV_LOG" \
    || fail "REGRESSION: the rollback did not re-deploy 'a1' through 'drvA'. §4b rolled the image back but not the driver — which is how the INSTALL driver was handed a RAM payload and blocked 30 minutes waiting for an installer that was never there"
grep -q '^drvB deploy node1 a1 previous$' "$DRV_LOG" \
    && fail "REGRESSION: the rollback ran the NEW driver ('drvB') against the PREVIOUS image ('a1'). That is not a rollback — it is the failure this test exists for, and on a real node it netboots a live machine into the wrong payload"
assert_state node1 active
note "the rollback re-deploys the previous image through the driver that owns it  ✓"

# The registry must follow the machine back. A node whose recorded driver did not deploy
# its recorded image is a machine nobody can reason about — and every later verb
# (redeploy, rollback, apply) starts from that record.
d="$(_show node1 driver)"; i="$(_show node1 image)"
[[ "$d" == drvA && "$i" == a1 ]] \
    || fail "REGRESSION: after the rollback the registry says driver='$d' image='$i' (want drvA/a1). The live run recorded 'driver=install image=micro-linux-x86_64' — a pair that cannot exist, written down as fact"
note "the registry records the pair that is actually running (drvA/a1)  ✓"

# ── 3. the positive control: a same-driver rollback still works ─────────────
# Without this, §2 would also pass on a cmd_deploy that never rolls back at all.
make_image a2
: > "$DRV_LOG"
HEALTH_FAIL=a2 "$MAAS" deploy node1 --driver drvA --image a2 >/dev/null 2>&1
assert_state node1 active
[[ "$(_show node1 image)" == a1 ]] \
    || fail "a same-driver A/B rollback no longer restores the previous image — the ordinary §4b path is broken"
grep -q '^drvA deploy node1 a1 previous$' "$DRV_LOG" \
    || fail "the same-driver rollback did not re-deploy the previous image"
note "control: an ordinary same-driver rollback still restores the previous image  ✓"

# ── 4. no recoverable previous driver -> REFUSE, do not guess ──────────────
# Rolling back through the wrong driver is worse than not rolling back: a node left on a
# failed image is honestly broken and says so.
prep node2 6231
( "$MAAS" deploy node2 --driver drvA --image a1 ) >/dev/null 2>&1 || fail "seed node2"
printf 'ghost\n' > "$MAAS_STATE/node2/driver"     # a driver that no longer exists
: > "$DRV_LOG"
out="$(HEALTH_FAIL=b1 "$MAAS" deploy node2 --driver drvB --image b1 2>&1)"
assert_state node2 error
grep -qE '^drv[AB] deploy node2 a1 previous$' "$DRV_LOG" \
    && fail "REGRESSION: the node was rolled back through a driver that did not deploy its previous image, after the recorded one turned out to be missing. Guessing a driver is the bug, not the fix"
grep -qi 'ghost' <<<"$out" \
    || fail "the refusal does not name the missing driver ('ghost'), so the operator cannot tell what is wrong or how to fix it"
note "an unresolvable previous driver refuses the rollback and errors honestly, naming it  ✓"

# ── 5. gate asks 'describe' — a driver never sees an image it does not own ──
# The backstop for everything above: even if the control plane picked wrong, the driver
# gets the chance to say "not mine" BEFORE any hardware is touched.
prep node3 6232
: > "$DRV_LOG"
if ( "$MAAS" deploy node3 --driver drvB --image a1 ) >/dev/null 2>&1; then
    fail "REGRESSION: 'drvB' deployed image 'a1', which it does not own. On the live fleet this is the installer driver PXE-booting a RAM payload onto a real node"
fi
grep -q '^drvB describe a1$' "$DRV_LOG" \
    || fail "REGRESSION: 'gate' never asked the driver to describe the image. Ownership is the driver's question to answer and nothing was asking it — F2 cannot catch this, because the image was correctly signed, it was simply the wrong driver's image"
grep -q '^drvB deploy ' "$DRV_LOG" \
    && fail "REGRESSION: the driver was asked to DEPLOY an image it had just refused to describe. The refusal must gate the deploy, not merely precede it"
note "gate asks 'describe <image>' first, and a refusal stops the deploy before any hardware is touched  ✓"

# ── 6. the real install driver refuses a real RAM payload ──────────────────
# The fixtures above prove the control plane; this proves the actual driver that got
# handed the actual image. A ramdisk-staged payload is kernel+initrd+cmdline.
RAM="$MAAS_IMAGES_DIR/ramish"; mkdir -p "$RAM"
printf 'k\n' > "$RAM/kernel"; printf 'i\n' > "$RAM/initrd"; printf 'console=ttyS0\n' > "$RAM/cmdline"
if MAAS_IMAGES_DIR="$MAAS_IMAGES_DIR" MAAS_STATE="$MAAS_STATE" \
     "$LAB_DIR/drivers/install.sh" describe ramish >/dev/null 2>&1; then
    fail "REGRESSION: the real install driver still claims a RAM payload (kernel+initrd+cmdline) as its own. That claim is what let a rollback hand it micro-linux-x86_64 and block for 30 minutes"
fi
note "the real install driver refuses a ramdisk-staged payload  ✓"

# …and still accepts one that is not. Without this, §6 would pass on a driver that
# refuses everything, which would break every real install. "One that is not" now
# means the install driver's OWN staged shape (kernel+initrd+ks.cfg — what its
# `stage` verb writes): since install-catalog.toml landed, describe answers the
# ownership question positively, and an image staged in NOBODY's shape is refused
# too — that refusal has its own control in test-install-driver.sh §7.
INST="$MAAS_IMAGES_DIR/instish"; mkdir -p "$INST"
printf 'k\n' > "$INST/kernel"; printf 'i\n' > "$INST/initrd"; printf 'poweroff\n' > "$INST/ks.cfg"
MAAS_IMAGES_DIR="$MAAS_IMAGES_DIR" MAAS_STATE="$MAAS_STATE" \
    "$LAB_DIR/drivers/install.sh" describe instish >/dev/null 2>&1 \
    || fail "control: the install driver now refuses an image that is NOT a RAM payload — it would refuse every real install"
note "control: it still accepts a non-RAM image, so the refusal is specific  ✓"

pass "an A/B rollback restores the driver with the image and records the pair that is actually running; an unresolvable previous driver refuses the rollback instead of guessing; and every deploy asks the driver whether the image is its own before touching hardware"
