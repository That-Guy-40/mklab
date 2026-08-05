#!/usr/bin/env bash
# disk_format_of / assert_disk_format — the gate that binds a declared disk format to the
# bytes it describes. Sources lab-vm.sh; creates its own qcow2 + raw fixtures with
# qemu-img. No boot, no root, no network.
#
# WHY IT EXISTS. MICRO_CLOUD_LAB_PLAN.md slice 5a boots the SAME raw ext4 image Firecracker
# boots so the only variable between the two engines is the VMM. `-drive format=` is
# DECLARED rather than probed (QEMU probing a raw image whose contents resemble another
# format is a known hardening hole), and a declaration that disagrees with the file is a
# record that misdescribes its subject — QEMU catches it, but only at boot, long after
# `create` reported success and wrote a manifest.
#
# THE BUG THIS GUARDS is the one the first implementation shipped: `qemu-img info
# --output=json` nests a per-child block carrying its OWN "format", so grabbing the first
# match on a raw file returns "file" (the protocol driver), not "raw". The gate then
# refused a correctly-declared raw image, naming a format QEMU has no such concept of. It
# was invisible against a fixture and instant against the real slice-3 ext4.
# shellcheck disable=SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd qemu-img qemu-system-x86_64

_VERDICT=0
skip()  { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }

tmp="$(mktemp -d)"
_on_exit() {
    local rc=$?
    rm -rf -- "$tmp"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

# shellcheck disable=SC1090
source "$LAB_VM"

# ── fixtures: one of each format, built the way a user's would be ───────────
qemu-img create -f raw   "$tmp/plain.raw"  8M >/dev/null 2>&1 || fail "could not create the raw fixture"
qemu-img create -f qcow2 "$tmp/over.qcow2" 8M >/dev/null 2>&1 || fail "could not create the qcow2 fixture"

# ── derivation ──────────────────────────────────────────────────────────────
got="$(disk_format_of "$tmp/plain.raw")"
[[ "$got" == raw ]] \
    || fail "REGRESSION: a raw image derived as '$got', not 'raw' — the nested \"format\": \"file\" is being read instead of the top-level one"
got="$(disk_format_of "$tmp/over.qcow2")"
[[ "$got" == qcow2 ]] || fail "a qcow2 image derived as '$got', not 'qcow2'"
note "derives raw and qcow2 correctly from the top-level format, not the child's"

# UNKNOWN is not a failure and not a guess: an unreadable path yields empty, and the gate
# must then decline to refuse rather than invent a mismatch.
[[ -z "$(disk_format_of "$tmp/does-not-exist")" ]] \
    || fail "an unreadable path produced a format instead of an empty (UNKNOWN) answer"
( assert_disk_format "$tmp/does-not-exist" qcow2 ) \
    || fail "the gate refused a file it could not read — 'I could not look' is not 'it is wrong'"
note "unreadable file → UNKNOWN, and the gate declines to refuse on it"

# ── the gate, both directions ───────────────────────────────────────────────
( assert_disk_format "$tmp/plain.raw" raw )     || fail "a correct raw declaration was refused"
( assert_disk_format "$tmp/over.qcow2" qcow2 )  || fail "a correct qcow2 declaration was refused"
note "correct declarations pass"

# NEGATIVE CONTROL: the gate must bite, and name both formats. `die` is an exit, so it is
# wrapped in a subshell — otherwise it would kill this test before its own assertion runs.
out="$( ( assert_disk_format "$tmp/plain.raw" qcow2 ) 2>&1 )" && \
    fail "REGRESSION: declaring qcow2 on a raw file was ACCEPTED — QEMU would refuse it at boot, after create reported success"
[[ "$out" == *raw* && "$out" == *qcow2* ]] \
    || fail "the mismatch refusal named neither the declared nor the actual format: $out"
out="$( ( assert_disk_format "$tmp/over.qcow2" raw ) 2>&1 )" && \
    fail "REGRESSION: declaring raw on a qcow2 file was ACCEPTED"
note "negative control bit: each mismatch refused, naming declared AND actual"

pass "disk_format is bound to the bytes it describes — mismatches refuse before boot, and UNKNOWN never renders as a pass"
