#!/usr/bin/env bash
# test-fleet-preflight.sh — create-fleet.sh refuses a doomed `up` BEFORE it rewrites
# any node disk, and the decisions it prints come from the code that applies them.
#
# WHAT THIS GUARDS. `up`'s step 4 is create-node.sh's unconditional
#     sudo qemu-img convert -f qcow2 -O qcow2 "$base" "$disk"
# — every node's disk is replaced. Until 2026-07-29 the two gates that can kill the run
# (swtpm absent; a required verifying ROM absent) did not fire until step 9, so a host
# missing either rewrote every disk, built and started vbmcd, registered three BMCs and
# enrolled the whole fleet before dying. Both answers were available at step 0.
#
# HOW IT ASSERTS THE OUTCOME, NOT THE MECHANISM. §5 does not grep create-fleet.sh for a
# call to do_preflight — that would pass for a broken preflight and fail for a better
# one. It runs `up` against a stub sibling lab whose create-node.sh is a TRIPWIRE, and
# asserts the tripwire was never touched. The state the system must end in: no disk
# rewritten.
#
# THE NEGATIVE CONTROL (§6) is what makes §5 mean anything. "The tripwire file is absent"
# is also what you get from a harness that never reached create-node.sh at all. §6 runs
# the identical harness with the ONE refusal condition removed (a swtpm stub appears on
# PATH) and requires the tripwire to FIRE. Same rig, one variable, opposite verdict.
#
# No libvirt, no vbmcd, no root, no registry writes.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need python3 mktemp
CF="$LAB_DIR/create-fleet.sh"
[[ -x "$CF" ]] || fail "create-fleet.sh not executable at $CF"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# NOTE: this replaces lib.sh's EXIT trap, so re-arm the early-exit net by hand.
# shellcheck disable=SC2154  # _rc is assigned inside the trap body below
trap '_rc=$?; rm -rf "$WORK"; if [[ $_rc -ne 0 && $_rc -ne 77 ]]; then printf "FAIL: test exited early (rc=%s)\n" "$_rc" >&2; fi' EXIT

# ── a two-node fleet spec of our own, so the real one is never touched ────────
FT="$WORK/fleet.toml"
cat > "$FT" <<'TOML'
[defaults]
memory_mb = 1024
disk_size = "2G"
firmware  = "bios"
network   = "test-net"
uri       = "qemu:///system"
[[node]]
name     = "n1"
bmc_port = 16230
[[node]]
name     = "n2"
bmc_port = 16231
TOML
export FLEET_TOML="$FT"

# ── stubs: a sibling lab, a virsh, and a PATH we control ──────────────────────
# The tripwire IS the stub create-node.sh. It records that it ran and then fails, so
# `up` stops right there and never reaches vbmcd, enroll, or the registry.
VB="$WORK/vbmc-lab"; mkdir -p "$VB"
TRIPWIRE="$WORK/DISK-WAS-REWRITTEN"
cat > "$VB/create-node.sh" <<EOF
#!/usr/bin/env bash
# stands in for the real create-node.sh, whose first act is \`qemu-img convert\` over
# the node disk. Touching this file means a real run would have destroyed a disk.
printf '%s\n' "\${NODE:-?}" >> "$TRIPWIRE"
exit 1
EOF
cat > "$VB/vbmc-lab.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$VB/create-node.sh" "$VB/vbmc-lab.sh"
export VBMC_LAB="$VB"

BIN="$WORK/bin"; mkdir -p "$BIN"
cat > "$BIN/virsh" <<'EOF'
#!/usr/bin/env bash
# Enough virsh for preflight + up-to-create-node. `shut off` so do_up does not try to
# destroy anything; a real destroy is not part of what this test proves.
for a in "$@"; do
    case "$a" in
        version)  echo "stub 0.0"; exit 0 ;;
        domstate) echo "shut off"; exit 0 ;;
    esac
done
exit 0
EOF
chmod +x "$BIN/virsh"

# A PATH with exactly what create-fleet.sh needs and NOTHING ELSE — the only way to make
# `command -v swtpm` fail on a host that has swtpm installed (this one does). An
# env-var escape hatch in the script would be a test-only branch, and a gate you can
# switch off in tests is not the gate that ships.
for c in bash env dirname basename python3 awk sed grep tr cat wc head tail \
         mkdir chmod ln rm mktemp install ss sudo; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$BIN/$c"
done
have swtpm || skip "this host has no swtpm, so §6 could not restore the passing case"
SWTPM_REAL="$(command -v swtpm)"

# run_cf <mode> [env...] — create-fleet.sh under the controlled PATH. Invoked as
# `bash <script>` rather than `./create-fleet.sh` so the shebang's /usr/bin/env does not
# have to find bash; `env` and `bash` are themselves symlinked into the stub dir above,
# because the `env VAR=val` prefix needs both.
run_cf() {
    local mode="$1"; shift
    ( export PATH="$BIN"; env "$@" bash "$CF" "$mode" ) 2>&1
}

# ── §1 rom_plan: one implementation of the ROM answer, asked without acting ───
ROMDIR="$WORK/roms"; mkdir -p "$ROMDIR"

# _rom-plan takes <node> [model] as positional args after the mode.
rp() { ( export PATH="$BIN"; env "$@" bash "$CF" _rom-plan n1 "${MODEL:-e1000}" ) 2>&1; }

out="$(rp MAAS_ROM_DIR="$ROMDIR" FLEET_NIC_ROM=0)"
[[ "$out" == "none:opted-out" ]] || fail "rom_plan: FLEET_NIC_ROM=0 should be none:opted-out, got '$out'"

out="$(rp MAAS_ROM_DIR="$ROMDIR")"
[[ "$out" == "none:not-installed" ]] \
    || fail "rom_plan: unset FLEET_NIC_ROM with no installed ROM should stay a plain fleet (none:not-installed), got '$out'"

out="$(rp MAAS_ROM_DIR="$ROMDIR" FLEET_NIC_ROM=1)"
[[ "$out" == "missing:$ROMDIR/ipxe-8086100e.rom" ]] \
    || fail "rom_plan: FLEET_NIC_ROM=1 with no ROM on disk must be FATAL (missing:<path>), got '$out'"

: > "$ROMDIR/ipxe-8086100e.rom"
out="$(rp MAAS_ROM_DIR="$ROMDIR")"
[[ "$out" == "attach:$ROMDIR/ipxe-8086100e.rom" ]] \
    || fail "rom_plan: an installed ROM must default ON (attach:<path>), got '$out'"

out="$(MODEL=weirdnic rp MAAS_ROM_DIR="$ROMDIR" FLEET_NIC_ROM=1)"
[[ "$out" == "missing:no-default-for-model" ]] \
    || fail "rom_plan: FLEET_NIC_ROM=1 with an unknown NIC model must be FATAL, not a silent shrug — got '$out'"

out="$(rp MAAS_ROM_DIR="$ROMDIR" FLEET_TPM=n1)"
[[ "$out" == "none:uefi-node" ]] \
    || fail "REGRESSION: a UEFI node must take NO legacy option ROM (it displaces the UEFI NIC driver OVMF needs), got '$out'"
note "§1 rom_plan: 6 verdicts, resolved with no libvirt and nothing attached"

# ── §2 preflight REFUSES a TPM fleet with no swtpm, and says why ──────────────
out="$(run_cf preflight FLEET_TPM=n2 MAAS_ROM_DIR="$ROMDIR")"; rc=$?
(( rc != 0 )) || fail "REGRESSION: preflight passed with FLEET_TPM=n2 and no swtpm on PATH — the run would die at step 9, after every disk was rewritten"
grep -qi 'swtpm is not installed' <<<"$out" \
    || fail "preflight refused but did not name swtpm as the reason (a refusal you cannot act on is barely better than the late one): $out"
grep -q 'n2' <<<"$out" || fail "preflight's swtpm refusal did not name which node needs it: $out"
note "§2 no swtpm + FLEET_TPM=n2 -> refused by name, rc=$rc"

# ── §3 preflight REFUSES a required-but-absent ROM, and prints the fix ────────
out="$(run_cf preflight FLEET_NIC_ROM="$WORK/nope.rom")"; rc=$?
(( rc != 0 )) || fail "REGRESSION: preflight passed with FLEET_NIC_ROM pointing at a file that does not exist"
grep -q 'nope.rom' <<<"$out" || fail "preflight's ROM refusal did not name the missing path: $out"
grep -q 'build-verifying-rom.sh' <<<"$out" \
    || fail "preflight refused on a missing ROM without printing the command that builds it: $out"
note "§3 FLEET_NIC_ROM=<absent> -> refused, names the path and the fix"

# ── §4 preflight PASSES a satisfiable fleet and prints the decision table ─────
out="$(run_cf preflight MAAS_ROM_DIR="$ROMDIR")"; rc=$?
(( rc == 0 )) || fail "preflight refused a satisfiable BIOS fleet (rc=$rc) — the positive case must pass, or §2/§3 prove only that the harness is broken: $out"
grep -q 'NODE .*FIRM .*TPM' <<<"$out" || fail "preflight passed but printed no decision table: $out"
grep -qE '^\s+n1\s+bios\s+no\b'  <<<"$out" || fail "preflight's table does not show n1 as bios/no-TPM: $out"
grep -q 'ipxe-8086100e.rom' <<<"$out" || fail "preflight's table does not show the ROM it will attach: $out"
note "§4 satisfiable fleet -> rc=0 and a table naming firmware, TPM and ROM per node"

# The table must track the DECISION, not a fixed string: with FLEET_TPM=n2, n2 flips to
# uefi/yes and loses its ROM. Same helper as apply, so this cannot drift from `up`.
ln -sf "$SWTPM_REAL" "$BIN/swtpm"          # swtpm now visible: the TPM fleet is satisfiable
out="$(run_cf preflight FLEET_TPM=n2 MAAS_ROM_DIR="$ROMDIR")"; rc=$?
(( rc == 0 )) || fail "preflight refused a TPM fleet even with swtpm present (rc=$rc): $out"
grep -qE '^\s+n2\s+uefi\s+yes\b' <<<"$out" \
    || fail "REGRESSION: FLEET_TPM=n2 must show n2 as uefi/yes — TPM implies UEFI (a BIOS domain measures no payload): $out"
grep -qE '^\s+n1\s+bios\s+no\b' <<<"$out" \
    || fail "REGRESSION: FLEET_TPM=n2 must leave n1 on BIOS — a fleet-wide TPM is what broke two nodes: $out"
note "§4b the table follows FLEET_TPM: n2 uefi/yes, n1 bios/no"
rm -f "$BIN/swtpm"

# ── §5 THE POINT: `up` refuses before create-node.sh can rewrite a disk ───────
[[ ! -e "$TRIPWIRE" ]] || fail "harness bug: the tripwire already exists before §5 ran"
out="$(run_cf up FLEET_TPM=n2 MAAS_ROM_DIR="$ROMDIR")"; rc=$?
(( rc != 0 )) || fail "REGRESSION: \`up\` did not refuse a TPM fleet with no swtpm"
# The tripwire is checked FIRST, because it is the defect. Verified by reverting the fix
# (do_up calling validate_tpm_selection instead of do_preflight): `up` printed "creating
# libvirt domain 'n1'" and died inside create-node, never having looked for swtpm.
[[ ! -e "$TRIPWIRE" ]] \
    || fail "REGRESSION: \`up\` reached create-node.sh ($(wc -l <"$TRIPWIRE") node(s)) before refusing — the swtpm gate fired AFTER the node disks were rewritten. A gate that fires after the convert is a post-mortem, not a gate. Output: $out"
grep -qi 'swtpm is not installed' <<<"$out" \
    || fail "\`up\` refused before create-node.sh but for some OTHER reason than the swtpm gate, so this proves nothing about ordering: $out"
note "§5 \`up\` with no swtpm -> refused, and create-node.sh was NEVER reached"

# ── §6 NEGATIVE CONTROL: remove the refusal, and the tripwire must FIRE ───────
# Without this, §5 is indistinguishable from a harness that never got near create-node.sh.
# The ONLY change is that swtpm becomes visible on the stub PATH.
ln -sf "$SWTPM_REAL" "$BIN/swtpm"
out="$(run_cf up FLEET_TPM=n2 MAAS_ROM_DIR="$ROMDIR")"; rc=$?
if [[ ! -e "$TRIPWIRE" ]]; then
    fail "NEGATIVE CONTROL FAILED: with swtpm present, \`up\` still never reached create-node.sh — so §5's 'tripwire absent' proves nothing about the gate's ordering. Harness output: $out"
fi
grep -q 'n1' "$TRIPWIRE" \
    || fail "NEGATIVE CONTROL: the tripwire fired but not for n1 — the harness is not exercising the path §5 claims to guard"
(( rc != 0 )) || fail "harness bug: the stub create-node.sh exits 1, so \`up\` must report failure (rc=$rc)"
note "§6 negative control: swtpm present -> preflight passes, create-node.sh IS reached (tripwire fired for $(wc -l <"$TRIPWIRE") node)"

pass "create-fleet.sh preflight refuses a doomed run before any disk is rewritten (§5), the assertion bites when the refusal is removed (§6), and its decision table is resolved by the same helpers \`up\` applies"
