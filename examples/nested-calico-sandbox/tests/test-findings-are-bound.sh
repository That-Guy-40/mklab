#!/usr/bin/env bash
# Verdict: this lab's recorded findings are BOUND to the subject that produced them, and a
# mismatch is refused BY NAME rather than silently generalised.
#
# WHY THIS EXISTS. `findings.env` says the `^br-.*` exclusion is real and that an addressed
# interface becomes a candidate. Both are true *of Calico v3.29.3*. A file stating them
# without saying which Calico is this repo's bug class #1 in its purest form: it stays
# perfectly readable and merely stops being true, and nothing errors — the record is just
# false, and it surfaces far downstream wearing someone else's clothes.
#
# The same discipline as metal-as-a-service's `capture-policy`, which stamps
# `# image-sha256:` into `pcrs.expected` so a policy captured from a different build is
# refused with both digests printed. A version string is a weaker identity than a hash, and
# that is stated in the README rather than pretended away — but it is enormously better than
# nothing, and it is what the CNI actually exposes.
#
# Headless: no VM, no cluster, no root. This is the half of the lab that CI can run.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

load_findings

# ── 1. the stamp exists and is a real version, not a placeholder ───────────
[[ -n "$F_CALICO" ]] \
    || fail "findings.env records no NCS_CALICO_VERSION — the findings would then be claims about Calico in general, which is exactly what the brief's constraint 2 forbids"
[[ "$F_CALICO" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "NCS_CALICO_VERSION is '$F_CALICO', which is not a vN.N.N version. A stamp that does not identify anything is decoration"
[[ -n "$F_MICROK8S" && -n "$F_METHOD" ]] \
    || fail "findings.env is missing the microk8s version or the autodetection method (got '$F_MICROK8S' / '$F_METHOD')"

# The METHOD is not a detail. `first-found` is the algorithm these rules describe; a cluster
# pinned to `can-reach` or `interface=` answers a different question while looking identical
# from the outside, and the findings would be about something else entirely.
[[ "$F_METHOD" == first-found ]] \
    || fail "findings.env records IP_AUTODETECTION_METHOD='$F_METHOD'. Rules 1 and 2 are properties of 'first-found'; under any other method these findings describe a different algorithm and must not be carried over"
note "stamped: Calico $F_CALICO, microk8s $F_MICROK8S, method $F_METHOD  ✓"

# ── 2. every finding it claims is actually recorded ────────────────────────
[[ "$F_RULE1" == confirmed ]] \
    || fail "NCS_RULE1_BR_EXCLUSION is '$F_RULE1', not 'confirmed' — README and the plan both cite this file as the evidence for the ^br-.* exclusion"
[[ "$F_RULE2" == confirmed ]] \
    || fail "NCS_RULE2_ADDRESSED_BECOMES_CANDIDATE is '$F_RULE2', not 'confirmed'"
[[ -n "$F_ORDER" ]] || fail "NCS_ORDERING_OBSERVED is empty — G.3 retracted the ordering explanation, so the observation is the only thing standing in for it"
# THE MIGRATION TIME IS A RANGE, and that is the finding. Two runs of the SAME image and
# the SAME Calico came in at 15 s and ~180 s. A single recorded number would have stopped
# describing its subject on the first re-run — this lab's own bug class, inside the file
# written to prevent it.
[[ "$F_SECS_MIN" =~ ^[0-9]+$ && "$F_SECS_MAX" =~ ^[0-9]+$ ]] \
    || fail "the migration time is recorded as '$F_SECS_MIN'..'$F_SECS_MAX', which is not a pair of numbers"
(( F_SECS_MAX > F_SECS_MIN )) \
    || fail "NCS_MIGRATION_SECONDS_MIN/MAX are $F_SECS_MIN/$F_SECS_MAX — not a range. Convergence was measured an order of magnitude apart on identical inputs, and collapsing that back to one value is how the record starts lying"
(( F_SECS_MAX > 60 )) \
    || fail "the recorded upper bound is ${F_SECS_MAX}s, within a single poll interval. The whole point of keeping it is that one interval was NOT always enough — a smaller bound licenses a test that samples too early and calls a slow migration a failure"
note "findings recorded: rule1=$F_RULE1 rule2=$F_RULE2 ordering=$F_ORDER migration=${F_SECS_MIN}-${F_SECS_MAX}s (variable)  ✓"

# ── 3. THE POINT: a mismatched subject is refused, by name ─────────────────
# The comparison lives in a function so it can be exercised without a cluster. This is the
# gate the live test uses; if it cannot refuse, the live test would happily compare a run of
# Calico v4 against numbers measured on v3.29.3 and report agreement.
version_gate() {  # version_gate <observed> <recorded>  -> 0 same, 1 mismatch (message on stdout)
    local observed="$1" recorded="$2"
    if [[ "$observed" != "$recorded" ]]; then
        printf 'REFUSED: this sandbox is running Calico %s, but findings.env was measured on %s.\n' \
               "$observed" "$recorded"
        printf '  These are different subjects. Re-run the experiment, read the result, and update\n'
        printf '  findings.env in the same commit that changed what produced it.\n'
        return 1
    fi
    return 0
}

out="$(version_gate v4.0.0 "$F_CALICO")" \
    && fail "REGRESSION: the version gate ACCEPTED a run of Calico v4.0.0 against findings measured on $F_CALICO. A gate that cannot refuse cannot protect, and the failure mode is silent: the live test would report agreement between a measurement and a cluster that never produced it"
grep -q "v4.0.0" <<<"$out" && grep -q "$F_CALICO" <<<"$out" \
    || fail "the gate refused, but without printing BOTH versions, so the reader cannot tell which is stale. Got: ${out//$'\n'/ }"
note "a mismatched Calico is refused, naming both versions  ✓"

# THE CONTROL. Without it, a gate that refuses EVERYTHING would satisfy the assertion above
# and the live test could never run at all — broken in the opposite, quieter direction.
version_gate "$F_CALICO" "$F_CALICO" \
    || fail "the version gate refused a run that MATCHES the recorded version. It now refuses everything, so the refusal above proves nothing and the live comparison can never happen"
note "and a matching Calico is accepted — the gate discriminates rather than always refusing  ✓"

pass "the sandbox's findings are bound to their subject: Calico $F_CALICO / microk8s $F_MICROK8S / method $F_METHOD are all stamped, every claimed finding is recorded, the migration time is kept above one poll interval so nothing licenses sampling too early, and a mismatched Calico is refused by name with both versions printed while a matching one is accepted"
