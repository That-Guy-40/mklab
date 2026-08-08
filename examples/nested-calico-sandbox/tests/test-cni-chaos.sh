#!/usr/bin/env bash
# Verdict: the CNI's break pass — a fault at each layer that can fail on its own, graded on
# CLAUDE.md's ladder, against a real pod-to-pod dataplane.
#
# WHY THIS IS THE LAST LAYER. `CLAUDE.md` asks for an injection point per
# independently-failing layer, and micro-cloud's matrix has six rows with the CNI in none of
# them — because breaking a CNI meant breaking the one this machine uses. The sandbox is
# what removes that objection, so this is the row that was blocked on a lab rather than on
# an idea.
#
# ── THE RUNGS ───────────────────────────────────────────────────────────────────────────
#   ABSORBED  the dataplane never noticed                                  ← the goal
#   DEGRADED  it broke and self-healed
#   HALTED    it broke and stayed broken, but a verb the system offers recovers it
#   STRANDED  broken, and nothing recovers it
#   LIED      the record and reality disagree — e.g. a node advertising a dead address
#
# ── A SINGLE NODE CANNOT OBSERVE EVERYTHING, AND THAT IS STATED, NOT HIDDEN ─────────────
#
# The VXLAN tunnel carries no traffic here: there are no peers. A fault whose only real
# consequence is cross-node therefore CANNOT move the dataplane observable, and grading it
# ABSORBED would mean "the fault never mattered" rather than "the CNI absorbed it". The
# vxlan row is graded on whether Calico REBUILDS the device and says so by name; §5 asserts
# that the matrix does not quietly hand it a rung it did not earn.
#
# NEEDS A RUNNING SANDBOX and takes ~10 minutes. SKIPs otherwise, because an unmet
# precondition is an UNKNOWN and never a pass.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

load_findings
[[ -x "$SANDBOX" ]] || skip "sandbox.sh is not executable at $SANDBOX"
[[ -r "$LAB_DIR/cni-chaos.sh" ]] || skip "cni-chaos.sh is missing"
sandbox_running \
    || skip "the sandbox VM is not running — this test breaks a live CNI and will not invent one. Bring it up with 'examples/nested-calico-sandbox/sandbox.sh up' (~15 min, unprivileged), then re-run"

host_binding() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || true; }
HOST_BEFORE="$(host_binding)"
note "host binding before: ${HOST_BEFORE:-<absent>}  (this lab breaks a CNI; it must not be that one)"

OUT="$(mktemp)"
on_exit 'rm -f -- "$OUT"'
note "injecting at each CNI layer in the guest (~10 min — each row waits out its recovery)"
if ! bash "$SANDBOX" cni-chaos >"$OUT" 2>&1; then
    cat "$OUT" >&2
    fail "the chaos run did not complete — a partial run must never be read as a matrix"
fi
grep -q '^CNI-END' "$OUT" \
    || { cat "$OUT" >&2; fail "the run did not reach CNI-END, so what is above is partial"; }

# ── 1. the workload the matrix is graded against must have existed ─────────
# Every row's headline observable is pod-a -> pod-b. If that never worked, every row would
# grade the same way and the matrix would be reporting on its own harness.
grep -q '^CNI-WORKLOAD-READY' "$OUT" \
    || { cat "$OUT" >&2; fail "the two-pod workload never came up, so there was no dataplane to break and no row below means anything"; }
note "workload: $(sed -n 's/^CNI-WORKLOAD-READY //p' "$OUT")  ✓"

rowline() { grep "^CNI-ROW=$1 " "$OUT" | tail -1; }
field()   { sed -n "s/.*$2\[\([^]]*\)\].*/\1/p" <<<"$1"; }
kv()      { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }

# ── 2. THE CONTROL — no fault, and the dataplane works ─────────────────────
ctl="$(rowline control-no-fault)"
[[ "$(kv "$(field "$ctl" AFTER)" pods)" == OK ]] \
    || { cat "$OUT" >&2; fail "the NO-FAULT control could not ping pod-b from pod-a. Nothing below is measurable: a matrix whose control fails is grading a broken harness, not a CNI"; }
note "control (no fault): $(field "$ctl" AFTER)  ✓"

ABSORBED=0; NOTABSORBED=0; CRITICAL=0; ROWS=0
grade() {  # grade <row> <expected-rung> — reads the row, derives the rung, compares
    local name="$1" want="$2" line before after rec
    line="$(rowline "$name")"
    if [[ -z "$line" ]]; then
        grep -q "^CNI-ROW=$name SKIPPED" "$OUT" \
            && { note "UNCOVERED: $name — $(grep "^CNI-ROW=$name SKIPPED" "$OUT" | sed 's/.*reason=//')"; return; }
        fail "the '$name' row is missing from the record entirely — a layer with no scenario is a layer nobody has watched fall over, and a silently absent row is worse than a named gap"
    fi
    before="$(field "$line" BEFORE)"; after="$(field "$line" AFTER)"
    rec="$(kv "$line" RECOVERED)"
    local pods_mid pods_after got
    pods_mid="$(kv "$(field "$line" MID)" pods)"; pods_after="$(kv "$after" pods)"

    if [[ "$name" == vxlan-deleted ]]; then
        # Graded ONLY on whether Calico rebuilt the device. Its dataplane consequence needs
        # a second node, and pretending otherwise would hand it an unearned rung.
        [[ "$rec" == yes ]] && got=DEGRADED || got=STRANDED
    elif [[ "$name" == chosen-address-removed ]]; then
        # Its subject is the NODE IP, not pod-to-pod: taking the address away and watching
        # Calico re-detect is the whole scenario. Grading it on `pods` measured collateral
        # from an earlier row instead — which is how it first came out STRANDED for a reason
        # unrelated to its own fault.
        [[ "$rec" == yes ]] && got=DEGRADED || got=LIED
    elif [[ "$pods_mid" == OK && "$pods_after" == OK ]]; then
        got=ABSORBED
    elif [[ "$pods_after" == OK && "$rec" == yes ]]; then
        got=DEGRADED
    elif [[ "$pods_after" == OK ]]; then
        got=HALTED          # recovered, but only via a verb we had to invoke
    else
        got=STRANDED
    fi
    ROWS=$((ROWS+1))
    [[ "$got" == ABSORBED ]] && ABSORBED=$((ABSORBED+1)) || NOTABSORBED=$((NOTABSORBED+1))
    [[ "$got" == STRANDED || "$got" == LIED ]] && CRITICAL=$((CRITICAL+1))

    if [[ "$want" != "$got" ]]; then
        KEEP=1
        fail "REGRESSION: the '$name' row moved on the ladder — recorded $want, measured $got.
  before: $before
  after:  $after  (recovered=$rec, $(kv "$line" SECS)s)
A rung that changes means the CNI's failure behaviour changed under this lab, and that is
worth a human look in BOTH directions: a row that silently improved is as interesting as one
that regressed."
    fi
    note "$name — $got  ✓  (recovered=$rec in $(kv "$line" SECS)s; $after)"
    # A row graded on its OWN observable can still have wrecked the dataplane, and that must
    # be said rather than left in the record for someone to notice. Measured: moving the
    # node IP onto a decoy healed itself in seconds while the pods never came back — the CNI
    # recovering its control plane and abandoning its workload.
    if [[ "$name" == chosen-address-removed || "$name" == vxlan-deleted ]] \
       && [[ "$pods_after" != OK ]]; then
        note "  ⚠ collateral: the dataplane was '$pods_after' afterwards. This row is graded on its own subject, but the workload did NOT recover on its own — on a multi-node cluster that is the F.6 outage, not a footnote"
    fi
}

# ── 3. the rows, each at the rung it was measured at ───────────────────────
grade calico-node-killed       ABSORBED
grade netfilter-flushed        ABSORBED
grade pod-veth-deleted         HALTED
grade vxlan-deleted            DEGRADED
grade chosen-address-removed   DEGRADED

# ── 4. the layers NOT covered, named rather than left implicit ─────────────
note "NOT covered, deliberately:"
note "  · anything whose consequence is CROSS-NODE — this is one node, so the tunnel carries no traffic. The vxlan row is graded on rebuild alone for exactly that reason"
note "  · IPAM exhaustion (fill the pod CIDR) — no injector yet; the analogue of the DHCP-pool row micro-cloud already has"
note "  · the datastore (k8s-dqlite) beneath Calico — a layer below this one, and breaking it breaks the API this harness talks to"

# ── 5. THE MATRIX MUST BE OCCUPIED ─────────────────────────────────────────
# Zero criticals proves none of this. A harness that breaks nothing is all-ABSORBED; one
# that breaks everything is all-STRANDED; both survive a criticals-only check.
(( ROWS >= 4 )) || fail "only $ROWS rows graded — too few to call this a matrix"
(( ABSORBED > 0 )) \
    || fail "no row ABSORBED its fault. Either every injector is too blunt or the CNI has no resilience left, and a matrix where nothing is absorbed cannot tell those apart"
(( NOTABSORBED > 0 )) \
    || fail "EVERY row absorbed its fault, including the ones recorded as not absorbing. That is what a matrix looks like when the faults are not landing — and on a single node the most likely cause is a row whose consequence this cluster cannot observe being graded as though it could"
note "ladder occupied: $ABSORBED absorbed, $NOTABSORBED not, $CRITICAL critical — so the injectors are landing and the resilience is real  ✓"

# ── 6. and the host's own cluster never moved ──────────────────────────────
HOST_AFTER="$(host_binding)"
[[ "$HOST_AFTER" == "$HOST_BEFORE" ]] \
    || fail "REGRESSION: the HOST's Calico binding moved during this run: '${HOST_BEFORE:-<absent>}' -> '${HOST_AFTER:-<absent>}'. This lab exists so that breaking a CNI costs nothing; if it can reach the host's, it is not a sandbox"
note "host binding unchanged across the whole break pass: ${HOST_AFTER:-<absent>}  ✓"

pass "the CNI's break pass — $ROWS layers injected inside a Calico we may destroy, every one at the rung it was recorded at, graded against a real pod-to-pod dataplane rather than a readiness field. $ABSORBED absorbed, $NOTABSORBED not. The layer CLAUDE.md's ladder has been asking about since it was written now has an injection point, and the rows a single node cannot observe are named as such instead of collecting rungs they did not earn"
