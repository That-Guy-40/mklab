#!/usr/bin/env bash
# Verdict: inside a Calico we are allowed to break, `fabric.sh`'s two safety rules are
# MEASUREMENTS rather than derivations — and the control is what makes rule 1 mean anything.
#
# WHY THIS TEST IS THE POINT OF THE LAB. `examples/micro-cloud/fabric.sh` names its bridge
# `br-mc0` and keeps its taps addressless because of two beliefs:
#
#   rule 1  first-found EXCLUDES `^br-.*`      — read out of a v3.28.1 binary, never tested
#   rule 2  an ADDRESSED interface is a candidate — observed ONCE, as an outage (plan F.6)
#
# On the host that runs this repo, testing either means breaking the Kubernetes the machine
# is using. Here it costs nothing.
#
# THE CONTROL IS NOT OPTIONAL, and §4 is where this test earns its keep. "Calico took
# mc-decoy" is explained equally well by *the exclusion is real* and by *the highest index
# won* — both decoys are addressed and up. Deleting the winner distinguishes them: if Calico
# falls back to `br-decoy` (higher index, still addressed) then ordering explains everything
# and rule 1 is UNPROVEN; if it skips `br-decoy` for the lower-index incumbent, the only
# remaining difference is the NAME.
#
# NEEDS A RUNNING SANDBOX, and SKIPs otherwise — a ~15-minute VM build is not a precondition
# CI can meet, and an unmet precondition is an UNKNOWN, never a pass. Bring one up with:
#     examples/nested-calico-sandbox/sandbox.sh up
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need python3
load_findings
[[ -x "$SANDBOX" ]] || skip "sandbox.sh is not executable at $SANDBOX"
sandbox_running \
    || skip "the sandbox VM is not running — this test measures a live Calico and will not invent one. Bring it up with 'examples/nested-calico-sandbox/sandbox.sh up' (~15 min, unprivileged), then re-run"

# ── 1. THE HOST'S CLUSTER IS THE THING WE MUST NOT DISTURB ─────────────────
# Recorded first and compared last. The host's binding has moved three times in six days on
# its own, so this comparison is not a formality — and if it DOES move during a run, we need
# to be able to say whether this lab caused it.
host_binding() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || true; }
HOST_BEFORE="$(host_binding)"
note "host binding before: ${HOST_BEFORE:-<absent>}  (must be identical at the end)"

# ── 2. run the experiment inside the guest ─────────────────────────────────
# `mktemp` (no -d) returns a FILE. An earlier line here registered its DIRNAME in TMPDIRS,
# which made the exit trap attempt `rm -rf /tmp/.` — coreutils refused ("refusing to remove
# '.' or '..' directory"), which is the only reason it was harmless. The file is removed by
# name and nothing registers a directory this test did not create.
OUT="$(mktemp)"
on_exit 'rm -f -- "$OUT"'
note "running the experiment in the guest (waits out Calico's poll — allow ~5 min)"
if ! bash "$SANDBOX" experiment >"$OUT" 2>&1; then
    cat "$OUT" >&2
    fail "the guest experiment did not complete — see the output above. A partial run must never be read as a result"
fi
grep -q '^NCS-END' "$OUT" \
    || { cat "$OUT" >&2; fail "the experiment did not reach NCS-END, so whatever is above is a partial run and not a measurement"; }

val() { sed -n "s/^NCS-$1=//p" "$OUT" | head -1; }

# ── 3. THE VERSION GATE — refuse to compare across a mismatch ──────────────
# A finding is bound to its subject. If this sandbox is running a different Calico, these
# numbers describe something else and agreement between them would be a coincidence
# presented as a confirmation.
OBSERVED_CAL="$(val CALICO-VERSION)"
OBSERVED_METHOD="$(val AUTODETECTION-METHOD)"
[[ -n "$OBSERVED_CAL" ]] || { cat "$OUT" >&2; fail "the experiment reported no Calico version"; }
[[ "$OBSERVED_CAL" == "$F_CALICO" ]] \
    || fail "REFUSING to compare: this sandbox runs Calico '$OBSERVED_CAL', findings.env was measured on '$F_CALICO'.
These are different subjects — the rules below are properties of a named version, not of Calico
in general. Re-run, read the result, and update findings.env in the same commit that changed
what produced it."
[[ "$OBSERVED_METHOD" == "$F_METHOD" ]] \
    || fail "REFUSING to compare: this sandbox uses IP_AUTODETECTION_METHOD='$OBSERVED_METHOD', findings.env recorded '$F_METHOD'. Rules 1 and 2 are properties of that algorithm; under another it is a different question wearing the same words"
note "subject matches the record: Calico $OBSERVED_CAL, method $OBSERVED_METHOD  ✓"

# The guest must have enumerated ITS OWN candidates (constraint 1) — if it somehow reported
# the host's interfaces, every conclusion below would be about the wrong machine.
CANDS="$(val CANDIDATE-SET)"
[[ "$CANDS" != *lxdbr0* && "$CANDS" != *incusbr0* ]] \
    || fail "the guest's candidate set contains the HOST's bridges ($CANDS) — the experiment is not looking at the guest, so nothing below is about the sandbox"
note "guest enumerated its own candidate set: $CANDS  ✓"

# ── 4. RULE 2 — an addressed interface becomes a candidate, on the poll ────
BEFORE_IF="$(val BINDING-BEFORE | awk '{print $1}')"
AFTER_IF="$(val BINDING-AFTER-DECOYS | awk '{print $1}')"
AFTER_SECS="$(sed -n 's/.*after=\([0-9]*\)s.*/\1/p' <<<"$(grep '^NCS-BINDING-AFTER-DECOYS' "$OUT")")"
[[ -n "$BEFORE_IF" && "$BEFORE_IF" != "<absent>" ]] \
    || fail "the guest had no vxlan.calico to begin with — there was nothing to watch move"
[[ "$AFTER_IF" == mc-decoy ]] \
    || fail "REGRESSION: with two addressed decoys present, Calico's tunnel went to '${AFTER_IF:-nothing}', not mc-decoy.
  before: $BEFORE_IF
findings.env records rule 2 as confirmed at $F_CALICO — an addressed interface becoming a
first-found candidate. If that no longer holds, fabric.sh's addressless-tap rule rests on
something this sandbox can no longer reproduce, and BOTH must be re-examined."
note "rule 2 MEASURED: $BEFORE_IF -> $AFTER_IF after ${AFTER_SECS}s, on the poll, nothing restarted  ✓"

# Reported, never asserted against a bound. Convergence has been measured at 15s and at
# ~180s on identical inputs; a test that required either would be asserting a coincidence.
[[ -n "$AFTER_SECS" ]] \
    && note "  (converged in ${AFTER_SECS}s; findings.env records ${F_SECS_MIN}-${F_SECS_MAX}s across runs — variable, so this is reported and not asserted)"

# ── 5. THE CONTROL — delete the winner, and see what it does NOT take ──────
CTRL_IF="$(val BINDING-AFTER-CONTROL | awk '{print $1}')"
grep -q '^NCS-CONTROL-SKIPPED' "$OUT" \
    && fail "the control did not run: $(grep '^NCS-CONTROL-SKIPPED' "$OUT"). Without it, §4 is equally explained by 'the highest index won' and rule 1 is unproven"
STILL_THERE="$(val EXCLUDED-DECOY-STILL-PRESENT)"
[[ -n "$STILL_THERE" ]] \
    || fail "br-decoy was gone by the time the control ran, so 'Calico did not pick it' says nothing — it could not have"
[[ "$CTRL_IF" != br-decoy ]] \
    || fail "REGRESSION: with mc-decoy deleted, Calico took **br-decoy** — an interface matching ^br-.*.
The exclusion does NOT hold at $OBSERVED_CAL, and fabric.sh's bridge-naming rule (the reason
its bridge is called br-mc0) rests on a belief this sandbox has just falsified. That is a
finding, not a flake: re-read F.7.1 and update findings.env and fabric.sh together."
[[ "$CTRL_IF" == "$BEFORE_IF" ]] \
    || note "(fell back to '$CTRL_IF' rather than the original '$BEFORE_IF' — still not br-decoy, so rule 1 holds, but the ordering is worth a look)"
note "rule 1 MEASURED: with mc-decoy gone Calico took '$CTRL_IF', SKIPPING br-decoy which was still up and addressed ($STILL_THERE)  ✓"
note "  → index ordering cannot explain that: br-decoy outranks the fallback on every axis but its NAME"

# ── 6. and the host's cluster is where we left it ──────────────────────────
HOST_AFTER="$(host_binding)"
[[ "$HOST_AFTER" == "$HOST_BEFORE" ]] \
    || fail "REGRESSION: the HOST's Calico binding moved during this run: '${HOST_BEFORE:-<absent>}' -> '${HOST_AFTER:-<absent>}'.
This lab exists precisely so that provoking a CNI costs nothing; if it can move the host's
tunnel then it is not a sandbox and the guarantee in its README is false."
note "host binding unchanged across the whole run: ${HOST_AFTER:-<absent>}  ✓"

pass "inside a Calico we may destroy, both of fabric.sh's safety rules are measurements at $OBSERVED_CAL: an ADDRESSED interface became a first-found candidate and the tunnel migrated to it on its own poll (rule 2, F.6's mechanism reproduced on purpose rather than suffered once) — and deleting that winner made Calico fall back PAST an addressed, higher-index br-decoy, which index ordering cannot explain and which is therefore the ^br-.* exclusion, measured (rule 1). The host's own cluster never moved"
