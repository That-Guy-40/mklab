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
# ── ONE FAULT CAN HIT TWO SUBJECTS, AND THEY GET TWO ROWS ───────────────────────────────
#
# Exhausting the address allocator is a single injection whose answer differs depending on
# who is asking: pods that already hold an address should not notice at all, while a pod
# admitted at that instant has nothing to be given. Those are different questions with
# different right answers, so they are graded as `ipam-exhausted-incumbent` and
# `ipam-exhausted` rather than averaged into one rung. The incumbent row is also the new-pod
# row's control: without it, "new pods were refused" cannot be told from "the CNI fell over".
#
# ── A SINGLE NODE CANNOT OBSERVE EVERYTHING, AND THAT IS STATED, NOT HIDDEN ─────────────
#
# The VXLAN tunnel carries no traffic here: there are no peers. A fault whose only real
# consequence is cross-node therefore CANNOT move the dataplane observable, and grading it
# ABSORBED would mean "the fault never mattered" rather than "the CNI absorbed it". The
# vxlan row is graded on whether Calico REBUILDS the device and says so by name; §5 asserts
# that the matrix does not quietly hand it a rung it did not earn.
#
# NEEDS A RUNNING SANDBOX and takes ~20 minutes. SKIPs otherwise, because an unmet
# precondition is an UNKNOWN and never a pass.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

load_findings
host_binding() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || true; }

# ── GRADING A RECORD YOU ALREADY HAVE ───────────────────────────────────────────────────
#
# `CNI_CHAOS_RECORD=<file>` grades that file instead of injecting anything. Two uses, both
# real:
#
#   - re-read the record a failed run kept (see the `on_exit` below) without spending another
#     20 minutes of live cluster to see the same bytes again;
#   - RUN THE NEGATIVE CONTROL. Every branch below is a claim about what the grader would do
#     if the CNI misbehaved, and a claim nobody has watched fire is not known to work. A
#     hand-written record with one defect injected makes the matching branch bite in seconds,
#     with no cluster at all.
#
# It announces itself loudly and it SKIPS the host-binding check, because a supplied record
# is a CACHED FACT: it says what some cluster did once, not what this one is doing now, and
# quietly grading it as though a run had just happened is the shape this repo keeps meeting.
RECORD="${CNI_CHAOS_RECORD:-}"
if [[ -n "$RECORD" ]]; then
    [[ -r "$RECORD" ]] || fail "CNI_CHAOS_RECORD=$RECORD is not readable"
    note "⚠ GRADING A SUPPLIED RECORD ($RECORD) — nothing was injected in this run. These rungs describe whatever cluster wrote this file, whenever that was"
    OUT="$RECORD"
    grep -q '^CNI-END' "$OUT" || fail "the supplied record does not reach CNI-END, so it is partial"
else
    [[ -x "$SANDBOX" ]] || skip "sandbox.sh is not executable at $SANDBOX"
    [[ -r "$LAB_DIR/cni-chaos.sh" ]] || skip "cni-chaos.sh is missing"
    sandbox_running \
        || skip "the sandbox VM is not running — this test breaks a live CNI and will not invent one. Bring it up with 'examples/nested-calico-sandbox/sandbox.sh up' (~15 min, unprivileged), then re-run"

    HOST_BEFORE="$(host_binding)"
    note "host binding before: ${HOST_BEFORE:-<absent>}  (this lab breaks a CNI; it must not be that one)"

    OUT="$(mktemp)"
    # KEEP THE RECORD WHEN THE RUN FAILED. This test costs ~20 minutes of live cluster;
    # deleting its evidence on the way out means the next step is to spend another 20
    # reproducing it. `_EXIT_RC` is published by lib.sh's net before teardown runs, precisely
    # so cleanup can ask whether it is tidying after a success or destroying an exhibit.
    on_exit 'if [[ "${_EXIT_RC:-1}" -eq 0 ]]; then rm -f -- "$OUT"; else printf "  - the chaos record was kept: re-grade it without re-running with CNI_CHAOS_RECORD=%s\n" "$OUT" >&2; fi'
    note "injecting at each CNI layer in the guest (~20 min — each row waits out its recovery)"
    if ! bash "$SANDBOX" cni-chaos >"$OUT" 2>&1; then
        cat "$OUT" >&2
        fail "the chaos run did not complete — a partial run must never be read as a matrix"
    fi
    grep -q '^CNI-END' "$OUT" \
        || { cat "$OUT" >&2; fail "the run did not reach CNI-END, so what is above is partial"; }
fi

# ── 1. the workload the matrix is graded against must have existed ─────────
# Every row's headline observable is pod-a -> pod-b. If that never worked, every row would
# grade the same way and the matrix would be reporting on its own harness.
grep -q '^CNI-WORKLOAD-READY' "$OUT" \
    || { cat "$OUT" >&2; fail "the two-pod workload never came up, so there was no dataplane to break and no row below means anything"; }
note "workload: $(sed -n 's/^CNI-WORKLOAD-READY //p' "$OUT")  ✓"

# THE ROW'S GRADED LINE IS THE ONE CARRYING `AFTER[`, not the last line mentioning the row.
# A row that emits several records — the IPAM row prints FILL, DENIAL, LEAK and RESTORED
# around its verdict — would otherwise be graded on whichever happened to come last, and
# `field ... AFTER` would return empty from a line that has no AFTER at all. Empty observables
# read as "not OK", so the row would grade STRANDED on a formatting accident.
rowline() { grep "^CNI-ROW=$1 " "$OUT" | grep 'AFTER\[' | tail -1; }
rowinfo() { grep "^CNI-ROW=$1 $2" "$OUT" | tail -1; }
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
        # AN INJECTOR THAT DID NOT LAND IS NOT A MISSING ROW, and saying so matters: the two
        # have opposite fixes. A missing row means nobody wrote the scenario; a failed
        # injector means the scenario ran and broke nothing, which is the shape that grades
        # ABSORBED while testing nothing.
        if grep -q "^CNI-ROW=$name INJECTOR-FAILED" "$OUT"; then
            fail "the '$name' injector did not land, so there is no fault to grade: $(grep "^CNI-ROW=$name INJECTOR-FAILED" "$OUT" | sed "s/^CNI-ROW=$name INJECTOR-FAILED //")
An injector that silently does nothing is the worst outcome available here — the row would
otherwise report ABSORBED, which reads as resilience and means 'nothing was broken'."
        fi
        fail "the '$name' row is missing from the record entirely — a layer with no scenario is a layer nobody has watched fall over, and a silently absent row is worse than a named gap"
    fi
    before="$(field "$line" BEFORE)"; after="$(field "$line" AFTER)"
    rec="$(kv "$line" RECOVERED)"
    local pods_mid pods_after got
    pods_mid="$(kv "$(field "$line" MID)" pods)"; pods_after="$(kv "$after" pods)"

    if [[ "$name" == ipam-exhausted ]]; then
        # Subject: a NEW pod admitted at the instant the allocator has nothing left. Not the
        # incumbent dataplane — that is this row's sibling, and grading both on `pods` would
        # make the pair say the same thing twice.
        #
        #   LIED      a refused pod that reports Running: the record says serving, the pod
        #             has no address to serve on. The critical rung, and the reason the
        #             injector checks phases and not just addresses.
        #   HALTED    refused, and freeing one address let exactly one waiter through.
        #   STRANDED  still refused after capacity came back — a pod nothing recovers.
        if   [[ "$(kv "$line" LIED)" == yes ]]; then got=LIED
        elif [[ "$rec" == yes ]];               then got=HALTED
        else                                         got=STRANDED
        fi
    elif [[ "$name" == vxlan-deleted ]]; then
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
grade ipam-exhausted-incumbent ABSORBED
grade ipam-exhausted           HALTED

# ── 3b. THE ALLOCATOR ROW'S OWN QUESTIONS ──────────────────────────────────
# Its rung above answers "was the new pod refused, and did freeing capacity let it through".
# Three things that rung cannot say are asked here, because each is a different defect.
if [[ -n "$(rowline ipam-exhausted)" ]]; then
    ip_line="$(rowline ipam-exhausted)"

    # (a) WAS IT REFUSED FOR A REASON A HUMAN CAN ACT ON? The ladder's HALTED rung is not
    # merely "it stopped" — it is "it stopped honestly: a named error state, a recorded
    # reason". A pod sitting in Pending with nothing recorded against it has halted, but not
    # honestly, and an operator has to go and guess.
    #
    # "Named" is tested against the CIDR THIS HARNESS CHOSE, not against a phrase Calico
    # might use — see the long note in cni-chaos.sh, where three invented strings all missed
    # a refusal that was in fact exemplary.
    reason="$(kv "$ip_line" REASON)"
    note "what the CNI actually said: $(rowinfo ipam-exhausted DENIAL-TEXT | sed 's/^CNI-ROW=ipam-exhausted DENIAL-TEXT //')"
    case "$reason" in
        named-the-exhausted-pool)
            note "the refusal named the exhausted pool by CIDR — an operator can act on it without reading Calico's source  ✓" ;;
        named-an-address-failure-but-not-which-pool)
            fail "the refusal said an address could not be assigned but did NOT name which pool ran out. On a cluster with several pools that is a message an operator cannot act on: it says something is full and not what. HALTED requires a named error state, and this names only half of one" ;;
        *)
            fail "the CNI refused the pod but did NOT say why (reason=$reason). HALTED requires a named error state; a silent refusal is a pod stuck in Pending with nothing for an operator to act on, and this row would be reporting graceful failure it did not demonstrate" ;;
    esac

    # (b) DOES THE ALLOCATOR GIVE ADDRESSES BACK? Bug class #1 asked of the allocator: an
    # address whose pod is gone but whose IPAM record is not is capacity that exists on paper
    # and not in fact.
    #
    # ── WHAT IS ASKED HERE IS NOT "DID IT LEAK", AND THE DIFFERENCE WAS EXPENSIVE ────────
    #
    # "It leaked" means "it is NEVER reclaimed", and no test establishes never. Three runs
    # tried, with three deadlines — sample-once, 180 s, 600 s — and all three called a healthy
    # cluster leaky, because reclamation here has two speeds: most addresses come back at
    # delete time, and one lingers for a tail that has outrun every number picked for it.
    #
    # So the firm assertion is the PROMPT path, which has a real failure mode: if NOT ONE
    # address came back when the pods went away, the allocator is not returning them at all.
    # The tail is reported and never failed on — an unbounded thing cannot be a gate.
    leak_line="$(rowinfo ipam-exhausted LEAK)"
    leak="$(kv "$leak_line" allocations_left)"
    lk_first="$(kv "$leak_line" first)"; lk_of="$(kv "$leak_line" of_filled)"
    if [[ -z "$leak" || -z "$lk_first" ]]; then
        note "UNKNOWN: the leak check produced no reading, so whether addresses were returned is unmeasured — that is not a pass"
    elif (( lk_first >= lk_of )); then
        fail "REGRESSION: NONE of the $lk_of addresses were returned when their pods were deleted ($lk_first still allocated the moment the last one left). The prompt release path is dead: every pod that ever ran would permanently consume an address, and the pool's free count becomes a record that stopped describing its subject — invisible until the pool runs dry for real, presenting as an exhaustion nobody caused"
    elif [[ "$leak" == 0 ]]; then
        note "the allocator gave everything back: $((lk_of - lk_first))/$lk_of at delete time, the remaining $lk_first within $(kv "$leak_line" released_after)  ✓"
    else
        note "$((lk_of - lk_first))/$lk_of addresses came back at delete time  ✓ — and $leak was still held after $(kv "$leak_line" released_after). UNKNOWN, not a failure: the tail is reclaimed by a slower path that has outrun every deadline this lab has picked for it (10 s, 180 s, 600 s — free on the next look each time). Watching longer would not make it a verdict"
    fi

    # (c) DID THE HARNESS PUT THE CLUSTER BACK? This row is the only one that edits a
    # cluster-wide API object. A run that left the pools disabled would poison every later
    # row with a fault nobody injected — and it would look like Calico had broken itself.
    rst="$(rowinfo ipam-exhausted RESTORED)"
    [[ "$(kv "$rst" disabled_pools_remaining)" == 0 && "$(kv "$rst" tiny_pool_present)" == no ]] \
        || fail "the IPAM row did not put the cluster back: $rst. Leaving a pool disabled means the next run measures this harness's litter instead of Calico"
    note "cluster IP pools restored, the tiny pool is gone  ✓"
fi

# ── 4. the layers NOT covered, named rather than left implicit ─────────────
note "NOT covered, deliberately:"
note "  · anything whose consequence is CROSS-NODE — this is one node, so the tunnel carries no traffic. The vxlan row is graded on rebuild alone for exactly that reason"
note "  · the datastore (k8s-dqlite) beneath Calico — a layer below this one, and breaking it breaks the API this harness talks to"

# ── 5. THE MATRIX MUST BE OCCUPIED ─────────────────────────────────────────
# Zero criticals proves none of this. A harness that breaks nothing is all-ABSORBED; one
# that breaks everything is all-STRANDED; both survive a criticals-only check.
(( ROWS >= 5 )) || fail "only $ROWS rows graded — too few to call this a matrix"
(( ABSORBED > 0 )) \
    || fail "no row ABSORBED its fault. Either every injector is too blunt or the CNI has no resilience left, and a matrix where nothing is absorbed cannot tell those apart"
(( NOTABSORBED > 0 )) \
    || fail "EVERY row absorbed its fault, including the ones recorded as not absorbing. That is what a matrix looks like when the faults are not landing — and on a single node the most likely cause is a row whose consequence this cluster cannot observe being graded as though it could"
note "ladder occupied: $ABSORBED absorbed, $NOTABSORBED not, $CRITICAL critical — so the injectors are landing and the resilience is real  ✓"

# ── 6. and the host's own cluster never moved ──────────────────────────────
# Skipped when grading a supplied record: nothing was injected, so comparing the host's
# binding to itself would be a check that cannot fail — an assertion that always passes is
# worse than no assertion, because it reads as coverage.
if [[ -n "$RECORD" ]]; then
    pass "the supplied record grades clean: $ROWS rows, $ABSORBED absorbed, $NOTABSORBED not, $CRITICAL critical. NOTHING WAS INJECTED IN THIS RUN — this says the grader reads that file correctly, and says nothing whatever about any cluster's health today"
fi
HOST_AFTER="$(host_binding)"
[[ "$HOST_AFTER" == "$HOST_BEFORE" ]] \
    || fail "REGRESSION: the HOST's Calico binding moved during this run: '${HOST_BEFORE:-<absent>}' -> '${HOST_AFTER:-<absent>}'. This lab exists so that breaking a CNI costs nothing; if it can reach the host's, it is not a sandbox"
note "host binding unchanged across the whole break pass: ${HOST_AFTER:-<absent>}  ✓"

pass "the CNI's break pass — $ROWS rows over six layers injected inside a Calico we may destroy, every one at the rung it was recorded at, graded against a real pod-to-pod dataplane rather than a readiness field. $ABSORBED absorbed, $NOTABSORBED not, $CRITICAL critical. The layer CLAUDE.md's ladder has been asking about since it was written now has an injection point, and the rows a single node cannot observe are named as such instead of collecting rungs they did not earn"
