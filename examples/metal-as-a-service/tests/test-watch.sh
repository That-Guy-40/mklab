#!/usr/bin/env bash
# Verdict: `maas-lab.sh watch` wires the fleet into tools/control-pane — MAAS's
# milestones.toml loads in the engine, `watch` streams a node's console to its
# terminal milestone, picks the profile from the deploy driver, and REGISTERS the
# node under the control-pane fleet dir so Phase-6 surfaces it. Headless.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3
trap 'cleanup_sandboxes' EXIT
maas_env

CP="$LAB_DIR/../../tools/control-pane"
[[ -x "$CP" ]] || skip "tools/control-pane not found at $CP"

# ── MAAS's milestones.toml loads in the control-pane engine, all 4 profiles ──
python3 - "$LAB_DIR/milestones.toml" <<'PY' || fail "milestones.toml does not load in the control-pane engine"
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "..", "..", "tools"))
from control_pane.milestones import load
profs = load(sys.argv[1])
for p in ("probe", "install", "ramdisk", "image"):
    assert p in profs, f"missing profile {p}"
    assert any(m.terminal for m in profs[p]), f"profile {p} has no terminal milestone"
PY
note "milestones.toml loads in the engine; probe/install/ramdisk/image all terminal ✓"

( "$MAAS" enroll node1 --bmc-port 6230 ) >/dev/null 2>&1 || fail "enroll node1"

# ── --register-only surfaces the node for Phase-6 without streaming ──────────
( "$MAAS" watch node1 --profile probe --register-only ) >/dev/null 2>&1 || fail "watch --register-only failed"
fleet="$(dirname "$MAAS_STATE")/control-pane"
nt="$fleet/node1/node.toml"
[[ -f "$nt" ]] || fail "watch did not register the control-pane node.toml at $nt"
grep -q 'profile = "probe"' "$nt" || fail "node.toml missing profile"
grep -q "milestones = .*metal-as-a-service/milestones.toml" "$nt" || fail "node.toml not pointed at MAAS's milestones"
note "watch --register-only wrote a control-pane node.toml (Phase-6 surface) ✓"

# the registered node is discoverable by control-pane itself
seen="$("$CP" list --json --fleet "$fleet" 2>/dev/null)" || fail "control-pane list failed on the registered fleet"
grep -q '"name": *"node1"' <<<"$seen" || fail "control-pane did not list the MAAS-registered node1: $seen"
note "control-pane list --json discovers the registered node ✓"

# ── watch streams a probe console to its terminal milestone (exit 0) ─────────
console="$MAAS_STATE/node1/console.log"
printf 'Unpacking initramfs\nMAAS inspection probe: booting\ncollected facts cpus=4\nfacts posted (introspection complete)\n' > "$console"
verdict="$( ( "$MAAS" watch node1 --profile probe --console "$console" ) 2>/dev/null )" \
    || fail "watch did not exit 0 on a console that reaches the terminal milestone"
grep -q "reached 'facts posted'" <<<"$verdict" || fail "watch verdict wrong: $verdict"
note "watch streams the probe console to terminal (facts posted, 100%) ✓"

# ── profile auto-selects from the deploy driver when --profile is omitted ────
( "$MAAS" manage node1 ) >/dev/null 2>&1
( "$MAAS" provide node1 ) >/dev/null 2>&1
( "$MAAS" deploy node1 --driver ramdisk --image busybox-netboot ) >/dev/null 2>&1 || fail "deploy node1"
( "$MAAS" watch node1 --register-only ) >/dev/null 2>&1 || fail "watch (driver-derived profile) failed"
grep -q 'profile = "ramdisk"' "$nt" || fail "REGRESSION: watch did not derive profile 'ramdisk' from the deploy driver"
note "profile auto-derived from the deploy driver (ramdisk) ✓"

pass "watch wires MAAS into tools/control-pane: milestones load, register for Phase-6, stream to terminal, driver-derived profile"
