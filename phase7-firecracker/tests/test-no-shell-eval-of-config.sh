#!/usr/bin/env bash
# REGRESSION (REVIEW-phase7.md P7-1): a config value reached `$(( ))`, and bash arithmetic
# evaluates ARRAY SUBSCRIPTS with full expansion — so `memory = "BASH_VERSINFO[$(cmd)]G"`
# RAN cmd.
#
#     mem_to_mib() { case "$m" in *G|*g) printf '%s' $(( ${m%[Gg]} * 1024 )) ;; ... }
#
# Measured on the real driver, end to end through `preflight --config`: the command ran and
# the gate printed `ok  memory 5120 MiB`. `preflight` is the verb whose entire promise is
# that it answers every question BEFORE anything happens — so the gate that exists to run
# before anything happens was itself the thing that happened. `create --dry-run` runs the
# same function, so "nothing was written" was true and beside the point.
#
# `set -u` was NOT the guard it looked like. It stops `a[$(cmd)]` (unset name) but not
# `EUID[$(cmd)]` or `BASH_VERSINFO[$(cmd)]`, which name variables that exist — both
# measured executing. Section 2 below carries that as its own case, because a fix that only
# defeated the unset-name form would pass a test written with only the unset-name form.
#
# THE PAYLOAD IS INERT ON PURPOSE. It writes a marker file. The repo rule exists because a
# `$(reboot)` inside a double-quoted printf in an inner `bash -c` once actually rebooted the
# machine: test data that a shell may re-evaluate must never name a destructive verb.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
export LAB_STATE_DIR="$tmp/state"
marker="$tmp/EXECUTED"

spec() {  # spec <memory-value>
    {   printf '[[microvm]]\nname = "t1"\n'
        printf 'kernel = "/nonexistent/vmlinux"\nrootfs = "/nonexistent/rootfs.ext4"\n'
        printf 'memory = "%s"\n' "$1"
    } > "$tmp/s.toml"
}

# ── 1. the three shapes, through the real CLI ─────────────────────────────────────────
# Two that execute under `set -u` and one that does not, so the test cannot be passing
# because only the easy one was ever tried.
i=0
for var in BASH_VERSINFO EUID a; do
    i=$((i+1)); rm -f "$marker"
    spec "${var}[\$(echo INJECTED > $marker)]G"
    run_fc "$tmp/out$i" preflight --config "$tmp/s.toml" || true
    [[ -e "$marker" ]] \
        && fail "REGRESSION: a [[microvm]] memory value shaped '${var}[\$(...)]G' EXECUTED the command substitution — a config file is arbitrary code again (P7-1)"
    grep -qE '^  (ok|FAIL) +memory ' "$tmp/out$i" \
        || fail "the memory gate did not report on '${var}[...]G' at all; the value vanished instead of being refused. Output: $(cat "$tmp/out$i")"
    grep -qE '^  ok +memory ' "$tmp/out$i" \
        && fail "REGRESSION: the memory gate PASSED a value that is not a number ('${var}[...]G') — it is being converted by something that accepts expressions"
done
note "3 arithmetic-injection shapes refused by the memory gate, none executed"

# ── 2. and via the CLI flag, which builds its own record ──────────────────────────────
rm -f "$marker"
run_fc "$tmp/cli.out" preflight --name t1 --kernel /nonexistent/vmlinux \
    --rootfs /nonexistent/rootfs.ext4 --memory "EUID[\$(echo INJECTED > $marker)]G" || true
[[ -e "$marker" ]] \
    && fail "REGRESSION: --memory executes command substitution — the guard was applied to the config path only (P7-1)"
note "the --memory flag is the same: refused, not evaluated"

# ── 3. NEGATIVE CONTROL: re-inject the original expression and watch it bite ──────────
# Without this the assertions above are indistinguishable from a run in which nothing
# reached any arithmetic at all — the exact "a scan that matches nothing and a scan that is
# broken print the same green ✓" failure this repo has now made twice.
rm -f "$marker"
old_result="$(
    bash -c '
        set -euo pipefail
        old_mem_to_mib() {                       # the pre-fix implementation, verbatim
            local m="$1"
            case "$m" in
                *G|*g) printf "%s" $(( ${m%[Gg]} * 1024 )) ;;
                *M|*m) printf "%s" "${m%[Mm]}" ;;
                *)     printf "%s" "$m" ;;
            esac
        }
        old_mem_to_mib "$1"
    ' _ "BASH_VERSINFO[\$(echo INJECTED > $marker)]G" 2>&1 || true
)"
[[ -e "$marker" ]] \
    || fail "control: the PRE-FIX mem_to_mib did NOT execute the payload, so these assertions have not been shown to be capable of failing. This bash may evaluate subscripts differently — investigate before trusting the section above. (old_mem_to_mib printed: $old_result)"
note "negative control: the pre-fix mem_to_mib executed it (it printed '$old_result'), so the assertions above can bite"
rm -f "$marker"

# ── 4. CONTROL: the legal spellings still convert ─────────────────────────────────────
# A "fix" that refused everything would pass every assertion above. mem_to_mib is Phase 2's
# spelling and has to keep working.
for pair in '128M|128' '1G|1024' '2g|2048' '512|512' '08G|8192'; do
    val="${pair%|*}"; want="${pair#*|}"
    spec "$val"
    run_fc "$tmp/ok.out" preflight --config "$tmp/s.toml" || true
    grep -qE "^  ok +memory ${want} MiB\$" "$tmp/ok.out" \
        || fail "control: memory '$val' should convert to ${want} MiB; the gate said: $(grep -E '^  (ok|FAIL) +memory' "$tmp/ok.out")"
done
note "control: 128M 1G 2g 512 and 08G all still convert correctly (08G would have been an octal error before)"

pass "no config value reaches bash arithmetic — three injection shapes refused, the pre-fix version watched executing, and every legal spelling still converts (P7-1)"
