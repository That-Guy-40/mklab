#!/usr/bin/env bash
# Regression (REVIEW-phase2.md, P2-1): the numeric/enum manifest fields must not be able to
# inject manifest lines or QEMU sub-options.
#
# THE BUG, IN TWO FACETS.
#
#   (a) MANIFEST-LINE INJECTION (the M4 class, reopened).  `write_vm_manifest` wrote these
#       fields raw.  A NEWLINE in one adds lines to the manifest, and `read_manifest_field`'s
#       awk takes the FIRST match and exits — so an injected line beats the legitimate one
#       written below it:
#
#           cpus = 2                      ← cpus = $'2\nnetwork_mode = "tap"\ntap = "evil0"'
#           network_mode = "tap"          ← injected; wins
#           tap = "evil0"
#           …
#           network_mode = "user"         ← the real line, never reached
#
#       A field that looks like a CPU count silently reconfigures the VM's networking on
#       every later `start`/`inspect`.
#
#   (b) QEMU SUB-OPTION INJECTION (the Finding-8 class).  `build_qemu_argv` builds
#       comma-separated strings from these fields — `-smp ${cpus},cores=…,threads=…` and
#       `hostfwd=tcp:127.0.0.1:${ssh_port}-:22` — with no comma guard, unlike the
#       mac/bridge/tap/pxe_dir fields right beside them.
#
# WHY IT SURVIVED.  M4 (2026-07-08) cleaned the free-text fields and left a comment on
# `_mf_clean` asserting "Enum/numeric fields can't carry these, so they're not run through
# this."  That was an assumption about the CALLERS written into the CALLEE, and nothing
# enforced it — no integer check existed anywhere between `spec_get` and the manifest write,
# and a TOML config supplies these as strings.  Measured 2026-08-15: **all 15** un-cleaned
# fields injected, not just the five the audit named.  Quoting does not help — a newline
# ends the line whatever surrounds it.
#
# THE FIX IS TWO LAYERS, and this test asserts both, because either alone would rot:
#   1. `validate_spec` refuses non-integer cpus/cores/threads/ssh_port, non-size memory and
#      non-bool microvm/secure_boot/tpm — BEFORE `create` downloads an image (§1, §2).
#   2. `write_vm_manifest` routes EVERY field through `_mf_clean`/`_mf_uint`/`_mf_bool`, so
#      the writer cannot emit a broken manifest even if something reaches it without
#      validating (§3).  Layer 2 is what removes the assumption rather than re-stating it.
#
# Runs unprivileged, builds no VM: every assertion is at `validate_spec` or the manifest
# writer, which is where the defect lives.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

work="$(mktemp -d)"
on_exit 'rm -rf -- "$work"'
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"
mkdir -p "$work/state/vms/probe"

# All payloads below are INERT config text — `network_mode = "tap"` is data the reader may
# honour, never a command.  Nothing here is executable, in any shell, at any nesting depth.
NL_PAYLOAD='2
network_mode = "tap"
tap = "evil0"'

# ── 1. FACET (a): a newline in a numeric field is refused before anything is written ─────
spec() { jq -nc --argjson e "$1" '{name:"probe",backend:"disk-image",arch:"x86_64",distro:"debian",suite:"trixie"} + $e'; }
try()  { ( source "$LAB_VM"; validate_spec "$(spec "$1")" ) 2>&1 || true; }

out="$(try "$(jq -nc --arg c "$NL_PAYLOAD" '{cpus:$c}')")"
grep -q 'must be a non-negative integer' <<<"$out" \
    || fail "REGRESSION: a newline-bearing cpus was ACCEPTED by validate_spec — it reaches write_vm_manifest and injects manifest lines that read_manifest_field honours first, silently flipping network_mode/tap on every later start (REVIEW-phase2.md P2-1a). Got: $(tr '\n' ' ' <<<"$out")"
note "a newline in cpus is refused by validate_spec  ✓"

# …and refused END-TO-END, before a VM directory exists at all.
if command -v tomlq >/dev/null 2>&1; then
    cat > "$work/evil.toml" <<TOML
[[vm]]
name    = "victim"
backend = "disk-image"
arch    = "x86_64"
distro  = "debian"
suite   = "trixie"
cpus    = """
$NL_PAYLOAD
"""
TOML
    e2e="$(bash "$LAB_VM" create --config "$work/evil.toml" 2>&1 || true)"
    grep -q 'must be a non-negative integer' <<<"$e2e" \
        || fail "REGRESSION: 'create --config' accepted a multi-line TOML cpus. This is the reachable path — a TOML config supplies these fields as strings. Got: $(tr '\n' ' ' <<<"$e2e")"
    [[ ! -d "$work/state/vms/victim" ]] \
        || fail "REGRESSION: 'create' refused but had already created the VM directory — a gate that fires after the work is a post-mortem, not a gate"
    note "end-to-end: 'create --config' refuses it, and no VM directory is written  ✓"
else
    note "no tomlq — the end-to-end config path was NOT exercised (validate_spec asserted directly above)"
fi

# ── 2. FACET (b): a comma cannot reach QEMU's -smp / hostfwd strings ─────────────────────
out="$(try '{"cpus":"2,sockets=9"}')"
grep -q 'must be a non-negative integer' <<<"$out" \
    || fail "REGRESSION: a comma in cpus was accepted — build_qemu_argv splices it into '-smp \${cpus},cores=…', so it adds QEMU sub-options (the Finding-8 class). Got: $(tr '\n' ' ' <<<"$out")"
out="$(try '{"ssh_port":"2222,hostfwd=tcp:0.0.0.0:1-:1"}')"
grep -q 'must be a non-negative integer' <<<"$out" \
    || fail "REGRESSION: a comma in ssh_port was accepted — it is spliced into 'hostfwd=tcp:127.0.0.1:\${ssh_port}-:22', so it adds netdev sub-options and could widen host exposure. Got: $(tr '\n' ' ' <<<"$out")"
out="$(try '{"threads":"1,x"}')"
grep -q 'must be a non-negative integer' <<<"$out" || fail "a comma in threads was accepted"
note "a comma in cpus/ssh_port/threads is refused, so -smp and hostfwd cannot gain sub-options  ✓"

# ── 3. LAYER 2: the WRITER cannot emit a broken manifest, for ANY field ──────────────────
# Asserted by driving write_vm_manifest directly — i.e. bypassing validate_spec entirely,
# which is the whole point: M4 fixed the fields it could see and left a rule for the rest,
# and the rule was not kept. A writer that cannot emit a broken manifest needs no rule.
FIELDS=(BACKEND DISTRO SUITE ARCH MEMORY ACCEL SECURE_BOOT FIRMWARE TPM NETWORK_MODE
        CPUS MICROVM SSH_PORT CORES THREADS)
inject_probe() {  # inject_probe <driver> → prints the names of fields that still inject
    local drv="$1"
    ( source "$drv"
      base() { MF_BACKEND=disk-image MF_DISTRO=debian MF_SUITE=trixie MF_ARCH=x86_64
               MF_MEMORY=2048 MF_ACCEL=tcg MF_SSH_PORT=2222 MF_MICROVM=false MF_CPUS=2
               MF_CORES=0 MF_THREADS=0 MF_SECURE_BOOT=false MF_FIRMWARE=uefi MF_TPM=false
               MF_NETWORK_MODE=user; }
      for f in "${FIELDS[@]}"; do
          for q in '' '"'; do
              base
              printf -v payload '2%s\ninjected_marker = "PWNED"' "$q"
              eval "MF_$f=\$payload"
              rm -f "$(vm_manifest probe)"
              ( write_vm_manifest probe ) >/dev/null 2>&1 || true
              # `if`, not `[[ … ]] && { … }`: the driver this subshell sourced turns on
              # `set -e`, and an AND-list that evaluates false as the LAST command of a
              # loop body takes the whole subshell down — which showed up here as the
              # harness net's "test exited early (rc=1)" and no verdict at all.
              if [[ "$(read_manifest_field probe injected_marker 2>/dev/null || true)" == "PWNED" ]]; then
                  printf '%s ' "$f"; break
              fi
          done
      done ) 2>/dev/null
}
still="$(inject_probe "$LAB_VM")"
[[ -z "$still" ]] \
    || fail "REGRESSION: these manifest fields still inject a line when written: $still. Every field must go through _mf_clean/_mf_uint/_mf_bool — a field left raw reopens the M4 class (REVIEW-phase2.md P2-1a)"
note "all ${#FIELDS[@]} previously-raw manifest fields are un-injectable at the writer  ✓"

# ── 4. CONTROLS: the values real labs use must all still be accepted ─────────────────────
# Without this, everything above would also pass if validation had simply started refusing
# everything — which would break every spec in examples/ rather than securing it.
for m in 128M 1536M 1G 2048M 2G 4096M 2048; do
    ( source "$LAB_VM"; validate_spec "$(spec "$(jq -nc --arg m "$m" '{memory:$m}')")" ) >/dev/null 2>&1 \
        || fail "CONTROL FAILED: memory='$m' is used by specs in examples/ and is now REJECTED — the suffix forms (K/M/G) must keep working"
done
for c in 1 2 4; do
    ( source "$LAB_VM"; validate_spec "$(spec "$(jq -nc --arg c "$c" '{cpus:$c}')")" ) >/dev/null 2>&1 \
        || fail "CONTROL FAILED: cpus='$c' is now rejected"
done
( source "$LAB_VM"; validate_spec "$(spec '{"ssh_port":"0"}')" ) >/dev/null 2>&1 \
    || fail "CONTROL FAILED: ssh_port=0 means 'auto-allocate' and is used by specs in examples/ — it must stay valid"
( source "$LAB_VM"; validate_spec "$(spec '{}')" ) >/dev/null 2>&1 \
    || fail "CONTROL FAILED: a spec omitting every optional numeric field is now rejected"
note "control: every memory/cpus/ssh_port value used in examples/ still validates  ✓"

# …and a legitimate manifest is still written, and still reads back correctly.
( source "$LAB_VM"
  MF_BACKEND=disk-image MF_DISTRO=debian MF_SUITE=trixie MF_ARCH=x86_64 MF_MEMORY=2048M
  MF_ACCEL=kvm MF_SSH_PORT=2222 MF_MICROVM=false MF_CPUS=4 MF_CORES=2 MF_THREADS=1
  MF_SECURE_BOOT=false MF_FIRMWARE=uefi MF_TPM=false MF_NETWORK_MODE=user
  rm -f "$(vm_manifest probe)"; write_vm_manifest probe ) \
    || fail "CONTROL FAILED: a well-formed manifest could not be written at all"
for pair in "cpus 4" "cores 2" "threads 1" "ssh_port 2222" "memory 2048M" "microvm false" "network_mode user" "accel kvm"; do
    k="${pair%% *}"; want="${pair#* }"
    got="$( ( source "$LAB_VM"; read_manifest_field probe "$k" ) 2>/dev/null || true)"
    [[ "$got" == "$want" ]] \
        || fail "CONTROL FAILED: manifest field '$k' reads back as '$got', expected '$want' — the cleaning helpers are corrupting legitimate values"
done
note "control: a legitimate manifest is written and every field reads back unchanged  ✓"

# ── 5. NEGATIVE CONTROLS: re-inject each layer's defect and watch it bite ────────────────
# 5a — the WRITER: restore the PRE-FIX line for one field, verbatim. `cpus` used to be
# assigned straight from MF_CPUS and interpolated raw into the heredoc, so putting that one
# assignment back reproduces the original writer exactly, rather than approximating it.
preA="$work/lab-vm-raw-writer.sh"
sed 's|_cpus="\$(_mf_uint.*|_cpus="${MF_CPUS}"|' "$LAB_VM" > "$preA"
grep -q '_cpus="\${MF_CPUS}"' "$preA" \
    || fail "the negative control could not restore the pre-fix cpus assignment, so it proves nothing (the writer must have changed shape)"
bash -n "$preA" || fail "the re-injected raw-writer driver does not parse"
back="$(inject_probe "$preA")"
[[ -n "$back" ]] \
    || fail "the pre-fix writer did NOT inject for any field, so §3 above is not measuring the defect — this test would pass against the original bug"
note "negative control: with the pre-fix cpus assignment restored the writer injects again (fields: ${back% })  ✓"

# 5b — the VALIDATOR: drop the numeric loop and the hostile spec sails through.
preB="$work/lab-vm-no-validate.sh"
# `#` as the delimiter, not `|`: the line being matched contains `||`, which silently
# turns into a delimiter and makes sed exit with "unknown option to `s'".
sed 's#^        \[\[ -z "\$_v" || "\$_v" =~ \^\[0-9\]+\$ \]\] \\#        true \\#' "$LAB_VM" > "$preB"
grep -q '^        true \\$' "$preB" \
    || fail "the negative control could not disable the numeric check, so §1/§2 are not measuring it (the check must have changed shape)"
bash -n "$preB" || fail "the re-injected no-validate driver does not parse"
outB="$( ( source "$preB"; validate_spec "$(spec "$(jq -nc --arg c "$NL_PAYLOAD" '{cpus:$c}')")" ) 2>&1 || true )"
grep -q 'must be a non-negative integer' <<<"$outB" \
    && fail "the negative control could not disable the numeric check, so §1 above is not measuring it (the check must have changed shape)"
note "negative control: without the numeric check the newline-bearing spec validates cleanly  ✓"

pass "the numeric/enum fields can no longer inject: validate_spec refuses a newline or comma in cpus/cores/threads/ssh_port/memory and a non-bool in microvm/secure_boot/tpm before create writes anything, and write_vm_manifest routes all ${#FIELDS[@]} formerly-raw fields through a cleaning helper so the writer cannot emit a broken manifest at all"
