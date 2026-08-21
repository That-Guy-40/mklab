#!/usr/bin/env bash
# Verdict: `inspect --facts` accepts the source the README's own quickstart hands it — a
# STREAM — and still refuses a directory and an unreadable path by name.
#
# THE DEFECT (found 2026-08-21 auditing the docs, REVIEW-docs-micro-cloud-maas.md D1).
# The README's headless quickstart injects facts like this:
#
#     ./maas-lab.sh inspect node1 --facts /dev/stdin <<<'{"cpus":4,...}'
#
# and it printed:
#
#     maas: inspect: --facts file not found: /dev/stdin
#
# The gate was `[[ -f "$facts" ]]`. Under bash 5.2 a here-string is a PIPE, so /dev/stdin
# resolves through /proc/self/fd/0 to a pipe: `-f` is FALSE while `-r` is true and `cp`
# reads it without complaint. The gate asked whether the source was a REGULAR FILE when
# the only thing `cp` needs is that it is READABLE.
#
# Two things make this worth a test of its own rather than a one-character commit:
#
#   1. It had never worked. The gate arrived in the tool's first commit (49ee863,
#      increment 1) and the README line in the next one (23520df, increment 2). There is
#      no commit at which the documented command ran.
#   2. THE SUITE WAS BLIND TO IT, and not by accident. Every other --facts caller here
#      (test-state-machine.sh) passes a real file, so 38 green tests exercised the verb
#      through a seam no reader uses. That is this repo's bug class #2 — asserting the
#      mechanism instead of the interface someone actually drives — so this test drives
#      the README's LITERAL form, here-string and all, and would go on failing if the
#      gate were ever "fixed" back to a file-only check.
#
# The control is not an argument: the pre-fix `-f` gate is re-injected into a COPY of
# maas-lab.sh and the same stream call must fail there. An assertion never watched failing
# is not known to work.
#
# SAFETY: a throwaway state dir, the mock BMC, no libvirt, no root, no fleet.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
maas_env

FACTS='{"cpus":4,"mem_kb":8192000,"mac":"52:54:00:aa:bb:01"}'

prep() {  # a node parked in `manageable`, which is the only state inspect accepts
    ( "$LAB_DIR/create-fleet.sh" enroll ) >/dev/null 2>&1 || fail "create-fleet.sh enroll failed"
    m manage node1 >/dev/null 2>&1 || fail "manage node1 failed"
}
prep

# ── 1. the README's own form: a here-string through /dev/stdin ────────────────────────
out="$(m inspect node1 --facts /dev/stdin <<<"$FACTS" 2>&1)"; rc=$?
(( rc == 0 )) || fail "REGRESSION: the README's own quickstart form (--facts /dev/stdin <<<'{…}') was refused (rc=$rc): $out"
note "the README's form is accepted: $(printf '%s' "$out" | tail -1)"

# ...and it must have LANDED, not merely been accepted. A gate that stopped refusing while
# the copy still wrote nothing would pass the assertion above and fail the reader.
sched="$(m show node1 2>/dev/null | awk '$1 == "schedulable" { $1=""; sub(/^ +/,""); print }')"
[[ "$sched" == *"cpus=4"* && "$sched" == *"mem_mb=8000"* && "$sched" == *"52:54:00:aa:bb:01"* ]] \
    || fail "REGRESSION: facts arrived from the stream but no schedulable summary was derived: '${sched:-<empty>}'"
note "and the facts landed: schedulable $sched"

# ── 2. a process substitution — the same shape, a different kernel object ─────────────
maas_env; prep
out="$(m inspect node1 --facts <(printf '%s' "$FACTS") 2>&1)"; rc=$?
(( rc == 0 )) || fail "REGRESSION: --facts <(…) (a process substitution) was refused (rc=$rc): $out"
note "a process substitution works too — the gate is about readability, not about /dev/stdin"

# ── 3. a plain file still works (the case that never broke) ──────────────────────────
maas_env; prep
printf '%s' "$FACTS" > "$SANDBOX/facts.json"
m inspect node1 --facts "$SANDBOX/facts.json" >/dev/null 2>&1 \
    || fail "REGRESSION: --facts with a plain file is refused"
note "a plain file still works"

# ── 4. the refusals that must survive the widening ───────────────────────────────────
maas_env; prep
out="$(m inspect node1 --facts "$SANDBOX" 2>&1)"; rc=$?
(( rc != 0 )) || fail "REGRESSION: --facts accepted a DIRECTORY — cp would have failed after the state change"
grep -qi 'directory' <<<"$out" || fail "a directory is refused, but not BY NAME: $out"
note "a directory is refused by name: $(printf '%s' "$out" | tail -1)"

out="$(m inspect node1 --facts "$SANDBOX/nope.json" 2>&1)"; rc=$?
(( rc != 0 )) || fail "REGRESSION: --facts accepted a path that does not exist"
grep -qi 'not readable' <<<"$out" || fail "a missing path is refused, but not by name: $out"
note "a missing path is refused by name: $(printf '%s' "$out" | tail -1)"

# ── 5. THE CONTROL — re-inject the original `-f` gate and watch section 1 bite ────────
# Without this the whole file is indistinguishable from a test that checks nothing: every
# assertion above would also pass against a tool that had never had the bug.
maas_env; prep
broken="$SANDBOX/maas-lab-with-the-old-gate.sh"
sed 's|^\( *\)\[\[ -r "\$facts" \]\] .*|\1[[ -f "$facts" ]] \|\| die "inspect: --facts file not found: $facts"|' \
    "$MAAS" > "$broken"
chmod +x "$broken"
grep -q '\[\[ -f "\$facts" \]\]' "$broken" \
    || fail "the control could not be staged: the -f gate was not re-injected into the copy"
out="$( ( MAAS_SELF="$broken" "$broken" inspect node1 --facts /dev/stdin <<<"$FACTS" ) 2>&1 )"; rc=$?
(( rc != 0 )) \
    || fail "THE CONTROL DID NOT FIRE: the pre-fix -f gate accepted a stream, so sections 1-2 prove nothing"
note "control: with the original -f gate re-injected, the README's form fails again (rc=$rc) — $(printf '%s' "$out" | tail -1)"

pass "inspect --facts accepts a stream (the README's own '/dev/stdin <<<' form and a process substitution) and the facts land as a schedulable summary, while a directory and an unreadable path are still refused BY NAME — proved against a copy carrying the original -f gate, which refuses the stream"
