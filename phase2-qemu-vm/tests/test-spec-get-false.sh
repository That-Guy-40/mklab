#!/usr/bin/env bash
# Regression: `spec_get` must tell a JSON `false` apart from an absent key.
#
# THE TRAP.  `spec_get` was `jq -r --arg k "$2" '.[$k] // ""'`, and jq's `//` yields its
# right-hand side when the left is null OR FALSE.  So a boolean `false` came back as "" —
# the same answer as "the key isn't there".  (`0` is unaffected: `//` treats only null and
# false as empty, which is why this went unnoticed for the numeric fields.)
#
#     $ jq -nc '{a:false} | .a // "EMPTY"'   →  "EMPTY"
#     $ jq -nc '{a:0}     | .a // "EMPTY"'   →  0
#
# HOW IT SURFACED.  Both Phase 2 spec builders emit `microvm` as a JSON boolean, so every
# non-microvm VM wrote a bare `microvm = ` into its manifest — invalid TOML — and nobody
# noticed, because the reader returns "" for the broken line and the consumer reads "" as
# "not microvm".  The malformed value and the intended value happened to mean the same
# thing.  (That symptom was fixed separately, at the manifest writer.)
#
# WHAT THIS TEST IS AND IS NOT.  Every boolean consumer in lab-vm.sh today tests
# `== "true"`, where "" and "false" are equally not-true — so this change alters no current
# behaviour, and this test is NOT claiming it fixed a live bug.  It guards a latent trap:
# the next consumer to write `[[ -z "$x" ]]` on a boolean field would get a silently wrong
# answer, and "false" and "absent" genuinely are different facts.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

# ── 1. the semantics table — only `false` may differ from the old behaviour ──────────────
# Written out per-input rather than as "false works", because the risk in changing an
# accessor every field flows through is what it does to the OTHER inputs.
sg() { ( source "$LAB_VM"; spec_get "$1" "$2" ); }

want() {  # want <json-spec> <key> <expected> <why>
    local got; got="$(sg "$1" "$2")"
    [[ "$got" == "$3" ]] \
        || fail "spec_get on $4: expected [$3], got [$got] (spec: $1)"
}
want '{"a":false}'  a 'false' 'a JSON false — the whole point; "" here means false is indistinguishable from absent'
want '{"a":true}'   a 'true'  'a JSON true'
want '{"a":null}'   a ''      'an explicit null — still absent'
want '{"b":1}'      a ''      'a key that is not present'
want '{"a":0}'      a '0'     'zero — must NOT become "", or every numeric default flips'
want '{"a":""}'     a ''      'an empty string'
want '{"a":"x"}'    a 'x'     'an ordinary string'
want '{"a":"false"}' a 'false' 'the STRING "false" — same text as the boolean, by design'
note "spec_get distinguishes false from absent, and leaves true/0/null/\"\"/strings unchanged  ✓"

# Arrays and objects are read by spec_get_arr/spec_get_obj, but spec_get must not corrupt
# them if it is called on one — that would be a silent change to an unrelated reader.
for pair in '{"a":[]} []' '{"a":{}} {}'; do
    j="${pair%% *}"; exp="${pair#* }"
    got="$(sg "$j" a)"
    [[ "$got" == "$exp" ]] \
        || fail "spec_get corrupted a container value: expected [$exp], got [$got] — the fix was meant to touch only booleans"
done
note "arrays and objects pass through unchanged  ✓"

# ── 2. NEGATIVE CONTROL: the old implementation fails the false case, and only that ──────
# Without this, §1 would pass against any implementation that happens to be correct today —
# including the old one, if the trap were misremembered.
old_sg() { jq -r --arg k "$2" '.[$k] // ""' <<<"$1"; }
[[ "$(old_sg '{"a":false}' a)" == "" ]] \
    || fail "the pre-fix implementation did NOT return \"\" for false, so this test is not measuring the trap it describes"
for pair in '{"a":true} true' '{"a":0} 0' '{"a":"x"} x' '{"b":1} '; do
    j="${pair%% *}"; exp="${pair#* }"; [[ "$exp" == "$j" ]] && exp=''
    [[ "$(old_sg "$j" a)" == "$exp" ]] \
        || fail "the pre-fix implementation differs from the new one on a NON-false input ($j) — the change is wider than 'only false', which is not what was intended"
done
note "negative control: the old form returns \"\" for false, and agrees with the new one on every other input  ✓"

# ── 3. the outcome that motivated it: a valid manifest line for a false boolean ──────────
work="$(mktemp -d)"; on_exit 'rm -rf -- "$work"'
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"
( source "$LAB_VM"
  MF_BACKEND=disk-image MF_DISTRO=debian MF_SUITE=trixie MF_ARCH=x86_64 MF_MEMORY=2G
  MF_ACCEL=tcg MF_SSH_PORT=0 MF_CPUS=2 MF_MICROVM="$(spec_get '{"microvm":false}' microvm)"
  mkdir -p "$(vm_dir probe)"; write_vm_manifest probe ) \
    || fail "could not write a manifest with microvm sourced through spec_get"
line="$(grep -E '^microvm' "$work/state/vms/probe/manifest.toml" || true)"
[[ "$line" == "microvm     = false" ]] \
    || fail "REGRESSION: the manifest line for a false boolean is '$line', expected 'microvm     = false'. A bare 'microvm = ' is invalid TOML — the defect this change exists to remove"
note "a false boolean reaches the manifest as valid TOML (microvm = false)  ✓"

# ── 4. DRIFT GUARD: all five phase drivers must carry the same accessor ──────────────────
# The trap was identical in five files. Fixing one and leaving four is exactly the shape
# that produced P2-1 — M4 fixed the fields it could see and left a rule for the rest.
drivers=(phase1-chroot/lab-chroot.sh phase2-qemu-vm/lab-vm.sh phase3-docker/lab-docker.sh
         phase4-podman/lab-podman.sh phase5-lxd/lab-lxd.sh)
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
missing=()
for d in "${drivers[@]}"; do
    [[ -f "$root/$d" ]] || continue
    grep -q "if .\[\$k\] == false then \"false\" else" "$root/$d" || missing+=("$d")
done
(( ${#missing[@]} == 0 )) \
    || fail "these drivers still carry the \`.[\$k] // \"\"\` form, where a JSON false is indistinguishable from an absent key: ${missing[*]}"
note "all ${#drivers[@]} phase drivers carry the false-aware accessor  ✓"

pass "spec_get tells a JSON false from an absent key — false now reads as \"false\" while true/0/null/empty/strings/arrays/objects are byte-identical to before, the manifest gets valid TOML for a false boolean, and all five phase drivers carry the same accessor"
