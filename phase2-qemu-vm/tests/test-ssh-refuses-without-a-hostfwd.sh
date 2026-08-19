#!/usr/bin/env bash
# Verdict: `lab-vm.sh ssh` refuses a VM it could never have reached, and says what to use.
#
# WHY THIS EXISTS
# ---------------
# `ssh` connects to `127.0.0.1:$ssh_port`. That port is a **slirp hostfwd** — it exists only
# in user-mode networking. A VM on a tap or a bridge has no hostfwd at all, so for one of
# those the verb cannot connect at any commit, and the manifest's `ssh_port` is a number
# describing nothing.
#
# It used to fail by HANGING: ssh sat there until it timed out, while `list` went on printing
# `SSHPORT 2222` beside the VM. Measured 2026-08-19 in micro-cloud, whose `edge` is
# `network_mode = "tap"`: a runbook step waited 240 seconds on a command that had never
# worked. That is this repo's own recorded bug class — *the CLI verbs a doc cites all exist,
# while its first command had never worked at any commit* — and the reason a verb existing is
# not the same as a verb being applicable.
#
# So the assertions are about the OUTCOME a reader gets, not about the mechanism:
#   1. tap mode is refused, non-zero, and the message names `network_mode`;
#   2. the refusal points at something that DOES work (the console, or an address);
#   3. user mode is NOT refused — the guard must not have broken the case it does not cover.
#
# (3) is the control. Without it this file would pass just as happily against an `ssh` that
# refuses everything, which would be a worse tool than the one that hung.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

LV="$(dirname -- "${BASH_SOURCE[0]}")/../lab-vm.sh"
[[ -x "$LV" ]] || fail "lab-vm.sh is missing or not executable"

WORK="$(mktemp -d)"; on_exit 'rm -rf -- "$WORK"'
export LAB_STATE_DIR="$WORK/state"

# A VM manifest is all this needs: `ssh` reads network_mode from it, and the refusal has to
# happen BEFORE anything tries to connect. No QEMU, no KVM, no image.
mk_vm() {  # mk_vm <name> <network_mode>
    local n="$1" mode="$2" d="$LAB_STATE_DIR/vms/$1"
    mkdir -p "$d"
    cat > "$d/manifest.toml" <<EOF
name = "$n"
lab = "t"
backend = "disk-image"
arch = "x86_64"
network_mode = "$mode"
ssh_port = 2222
ssh_user = "lab"
EOF
    # `ssh` refuses a VM that is not running before it looks at anything else, so the
    # fixture has to look running. A pidfile naming THIS shell is a pid that exists and is
    # ours — no process is signalled by this test.
    printf '%s\n' "$$" > "$d/qemu.pid"
}

# ── 1. tap mode is refused, by name ─────────────────────────────────────────
mk_vm tapvm tap
rc=0; out="$("$LV" ssh tapvm -- true 2>&1)" || rc=$?
(( rc != 0 )) \
    || fail "REGRESSION: 'ssh' returned 0 for a tap-mode VM. There is no hostfwd to connect through, so a success here means it connected to something that is not this guest"
grep -q 'network_mode' <<<"$out" \
    || fail "the refusal does not name network_mode, so a reader cannot tell why this VM is different from one where ssh works. Got: $(tr '\n' ' ' <<<"$out")"
note "tap mode refused (rc=$rc), and the message names network_mode"

# ── 2. the refusal is actionable ────────────────────────────────────────────
# A refusal that only says no leaves the reader exactly where the hang did.
grep -qE 'console' <<<"$out" \
    || fail "the refusal names no way to reach or observe the guest. It must point at the console (or an address), or it is a dead end with better manners. Got: $(tr '\n' ' ' <<<"$out")"
note "the refusal points at the console as the way to see what the guest is doing"

# ── 3. bridge mode too ──────────────────────────────────────────────────────
mk_vm brvm bridge
rc=0; out2="$("$LV" ssh brvm -- true 2>&1)" || rc=$?
(( rc != 0 )) \
    || fail "'ssh' returned 0 for a bridge-mode VM — a bridge has no hostfwd either"
note "bridge mode refused as well"

# ── 4. THE CONTROL: user mode must NOT be refused ───────────────────────────
# An `ssh` that refuses everything would satisfy every assertion above and be strictly worse
# than the hang this replaced. So the one configuration the verb DOES support must get past
# the guard — it will fail later, at the connection, which is a different and honest failure.
mk_vm uservm user
rc=0; out3="$("$LV" ssh uservm -- true 2>&1)" || rc=$?
if grep -q 'network_mode' <<<"$out3"; then
    fail "CONTROL DID NOT BITE: user-mode networking was ALSO refused by the network_mode guard. The guard is refusing the case it exists to allow, and every assertion above would pass against an ssh that simply never works"
fi
note "control: user mode is not refused by the guard (it fails at the connection instead, which is honest)"

pass "lab-vm.sh ssh refuses tap and bridge VMs by name — there is no hostfwd to reach them through — and points at the console, while leaving user-mode networking alone"
