#!/usr/bin/env bash
# Verdict: the live driver re-runs against a node the registry already knows, and still
# aborts on a node it does not know at all.
#
# THE INCIDENT. A second run of run-e2e.sh died in phase 4:
#
#     $ ... maas-lab.sh manage node1
#     maas: cannot 'manage' node 'node1' from state 'manageable' — needs one of: enrolled error
#     FAIL: the step above failed (rc=1)
#
# Nothing was broken. THE REGISTRY OUTLIVES THE FLEET: create-fleet.sh rebuilds the
# domains but skips enrolling a node it already knows ("node1 already enrolled
# (state=manageable) — skipping"), so on the second run the node arrived at phase 4
# already past `enrolled`, and `manage` — a transition FROM enrolled/error, not a
# re-verification you can spam — correctly refused. The state machine was right and the
# harness was wrong about it, which is a different (and better) class of defect than the
# five before it: those were all in plumbing the headless suite substitutes for.
#
# The fix is one line of judgement, and it has three cases that must stay distinct:
#
#   enrolled / error   drive it: run `manage`
#   any other state    already past it: skip, say why, carry on
#   NO state at all    ABORT. This is not a third flavour of "nothing to do" — a node
#                      with no registry entry was never enrolled, which means phase 3
#                      did not finish, and every phase after this one would fail with
#                      its own confusing error. Collapsing this into the skip branch is
#                      the tempting wrong fix, so it gets its own assertion.
#
# What is under test is the SHIPPED ensure_manageable(), sed'd out of run-e2e.sh and
# sourced — not a re-implementation of its logic. $MAAS is pointed at a stub that prints
# whatever state the case under test needs.
#
# SAFETY: pure text and a stub shell script. No fleet, no libvirt, no BMC, no registry.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
maas_env
E2E="$LAB_DIR/run-e2e.sh"
[[ -f "$E2E" ]] || fail "run-e2e.sh is missing"

# ── the stub control plane ─────────────────────────────────────────────────
# `state <node>` prints $STUB_STATE (empty => exit 1, as maas-lab.sh does for an unknown
# node); `manage <node>` records that it was called. Nothing else is needed: phase 4's
# decision is a function of exactly one observation.
cat > "$SANDBOX/maas-stub.sh" <<'EOS'
#!/usr/bin/env bash
case "$1" in
    state)  [[ -n "${STUB_STATE:-}" ]] || exit 1; printf '%s\n' "$STUB_STATE" ;;
    manage) printf 'manage %s\n' "$2" >> "$STUB_CALLS" ;;
    abort)  printf 'abort %s\n' "$2" >> "$STUB_CALLS" ;;
    release) printf 'release %s\n' "$2" >> "$STUB_CALLS" ;;
    *)      printf 'stub: unexpected verb %s\n' "$1" >&2; exit 2 ;;
esac
EOS
chmod +x "$SANDBOX/maas-stub.sh"

# harness <state> -> echoes rc; output in $SANDBOX/out, `manage` calls in $SANDBOX/calls
harness() {
    : > "$SANDBOX/calls"
    { printf 'MAAS="%s/maas-stub.sh"\nNODE=node1\nSTUB_CALLS="%s/calls"\nexport STUB_CALLS\n' \
             "$SANDBOX" "$SANDBOX"
      printf 'STUB_STATE=%q\nexport STUB_STATE\n' "$1"
      printf 'die()  { printf "FAIL: %%s\\n" "$*" >&2; exit 1; }\n'
      printf 'info() { printf "   %%s\\n" "$*" >&2; }\n'
      printf 'run()  { "$@" || die "run failed"; }\n'
      # The transient list lives just above the function; extract it too, from the same
      # file, so the harness drives the shipped pair rather than a copy of one of them.
      sed -nE '/^E2E_TRANSIENT=/p' "$E2E"
      sed -n '/^ensure_manageable() {/,/^}/p' "$E2E"
      printf 'ensure_manageable\n'
      printf 'printf "REACHED-PHASE-5\\n" >&2\n'
    } > "$SANDBOX/h.sh"
    ( bash "$SANDBOX/h.sh" ) >"$SANDBOX/out" 2>&1
    printf '%s' $?
}

sed -n '/^ensure_manageable() {/,/^}/p' "$E2E" > "$SANDBOX/fn.sh"
[[ -s "$SANDBOX/fn.sh" ]] \
    || fail "could not extract ensure_manageable() from run-e2e.sh — has phase 4's decision been inlined again? Inlined, it cannot be exercised without a live fleet, which is how the bug shipped"

# ── 1. the incident itself: a node already past `enrolled` ─────────────────
rc="$(harness manageable)"
[[ "$rc" == 0 ]] \
    || fail "REGRESSION: the driver aborted on a node in state 'manageable' (rc=$rc). The registry outlives the fleet, so this is what EVERY re-run looks like — the second live run of run-e2e.sh died here with 'cannot manage from state manageable' and nothing was actually wrong"
grep -q 'REACHED-PHASE-5' "$SANDBOX/out" \
    || fail "REGRESSION: the run did not continue past phase 4 for an already-manageable node"
[[ ! -s "$SANDBOX/calls" ]] \
    || fail "REGRESSION: the driver called 'manage' on a node in state 'manageable'. That is not a harmless retry — it is an illegal transition, the control plane refuses it, and the refusal aborts the run"
note "a node already in 'manageable' is left alone, and the run continues  ✓"

# `active` is NOT "already past it, carry on" — that was the third and last outing of the
# permissive default. Phase 6 needs `manageable`, and `active` has to be walked back:
# release (-> available) then manage. Phase 3 has already rebuilt the domain and disk by
# this point, so the `active` record is stale and nothing serving is being torn down.
for st in active rescue; do
    rc="$(harness "$st")"
    [[ "$rc" == 0 ]] || fail "the driver failed on a node in '$st' (rc=$rc) instead of walking it back to manageable"
    grep -q "^release node1$" "$SANDBOX/calls" \
        || fail "REGRESSION: a node in '$st' was waved through instead of released. Nothing leads from '$st' to 'manageable', so phase 6's 'inspect' fails two phases later with a message about inspect — the third time this exact permissive branch caused that"
    grep -q '^manage node1$' "$SANDBOX/calls" \
        || fail "REGRESSION: '$st' was released but never managed. release lands the node in 'available'; without the follow-up 'manage' it is one edge short of the state inspect needs"
    # Capture, then test: a verdict must not hang off a pipe into `grep -q` (it exits on the
    # first match, the producer can take SIGPIPE, and with pipefail the pipeline is non-zero,
    # so a match that WAS found reads as absent). Invisible to tools/tests/test-no-pipe-gates.sh
    # until 2026-08-22, because that scanner read PHYSICAL lines and this gate spans a
    # backslash continuation. `|| true` keeps the capture from tripping errexit where it is set.
    _rel_line="$(grep -n 'release node1' "$SANDBOX/calls" || true)"
    grep -q '^1:' <<<"$_rel_line" \
        || fail "'manage' was issued before 'release' for a node in '$st' — manage cannot accept '$st', so the order is the fix"
done
note "a node in 'active'/'rescue' is released back to the pool and re-managed, in that order  ✓"

# `available` reaches manageable in ONE step — Ironic's unprovide edge, which the state
# machine was missing until a live run walked into it.
rc="$(harness available)"
[[ "$rc" == 0 ]] || fail "the driver failed on a node in 'available' (rc=$rc)"
grep -q '^manage node1$' "$SANDBOX/calls" \
    || fail "REGRESSION: a node in 'available' was not managed. 'available' was a one-way door — nothing led back to 'manageable' — until 'manage' gained it as an accepted state (as Ironic has it)"
grep -q '^release node1$' "$SANDBOX/calls" \
    && fail "a node already in 'available' was released again — it is already in the pool; releasing it is a pointless extra wipe"
note "a node in 'available' goes straight to 'manage' — no needless release  ✓"

# The control plane must actually ACCEPT that edge, or the driver above is issuing a verb
# that refuses. Two files, one claim.
grep -qE 'require_state "\$node" manage enrolled error available' "$LAB_DIR/maas-lab.sh" \
    || fail "REGRESSION: 'manage' no longer accepts 'available'. run-e2e.sh drives available -> manage; without that edge 'available' is a one-way door and a node that has ever been provisioned can never be inspected again"
note "the control plane accepts manage from 'available' (Ironic's unprovide edge)  ✓"

# ── the permissive default is GONE ─────────────────────────────────────────
# It was wrong three times: for a transient state, for `available`, and for `active`.
# A state this function cannot drive to `manageable` must STOP here, not two phases later.
rc="$(harness some-unknown-state)"
[[ "$rc" != 0 ]] \
    || fail "REGRESSION: the permissive default is back — an unrecognised state was waved through as 'already advanced'. Phase 6 needs 'manageable'; anything that cannot get there has to fail HERE, naming the state, instead of surfacing later as a confusing error about some other verb"
grep -q 'some-unknown-state' "$SANDBOX/out" \
    || fail "the refusal does not name the state it could not handle"
note "an unhandled state stops the run here, naming itself — no permissive default  ✓"

# ── 2. the positive control: a fresh node IS driven ────────────────────────
# Without this, §1 would also pass on a function that never calls `manage` at all —
# and phase 4 would silently stop doing the one thing it exists to do.
for st in enrolled error; do
    rc="$(harness "$st")"
    [[ "$rc" == 0 ]] || fail "the driver failed on a node in state '$st' (rc=$rc), which is exactly the state 'manage' is FOR"
    grep -q '^manage node1$' "$SANDBOX/calls" \
        || fail "REGRESSION: the driver did NOT call 'manage' on a node in state '$st'. Skipping it always would make phase 4 a no-op: the node never leaves 'enrolled', and the deploy several phases later fails for a reason that looks nothing like this"
    note "a node in '$st' is driven through 'manage'  ✓"
done

# ── 3. no state at all still ABORTS ────────────────────────────────────────
# The tempting wrong fix: fold "unknown node" into the skip branch and the whole thing
# becomes "never call manage, never complain". A node with no registry entry means
# phase 3 did not finish; carrying on would report a misleading failure much later.
rc="$(harness "")"
[[ "$rc" != 0 ]] \
    || fail "REGRESSION: the driver continued past a node with NO registry entry. That node was never enrolled — phase 3 did not finish — and every phase after this would fail with its own confusing error, exactly the march-past-the-defect behaviour run() was fixed to stop"
grep -q 'REACHED-PHASE-5' "$SANDBOX/out" \
    && fail "REGRESSION: execution continued past an un-enrolled node"
grep -q 'FAIL:' "$SANDBOX/out" \
    || fail "the driver aborted on an un-enrolled node but printed no verdict — a silent abort is indistinguishable from a broken harness"
grep -qi 'not enrolled\|phase 3' "$SANDBOX/out" \
    || fail "the abort message does not name the cause (an un-enrolled node / an unfinished phase 3), so the operator is left to guess"
note "a node with no registry entry aborts the run, naming phase 3  ✓"

# ── 4. the seam is still exercised in BOTH cases ───────────────────────────
# `power status` is what actually proves the BMC answers; skipping `manage` must not
# skip that. It sits outside the conditional in phase 4, and has to stay there.
sed -n '/\[4\/10\]/,/\[5\/10\]/p' "$E2E" > "$SANDBOX/phase4"
grep -qE '^run "\$MAAS" power "\$NODE" status' "$SANDBOX/phase4" \
    || fail "REGRESSION: 'power status' is no longer run unconditionally in phase 4. It is the assertion that the BMC seam answers at all; behind the state check, a re-run would never test the seam"
note "'power status' runs unconditionally — the seam is tested on a re-run too  ✓"

# ── 5. a node STRANDED mid-transition is aborted, then managed ─────────────
# The fourth case, and the one the `*)` branch above originally swallowed. A run killed
# mid-deploy leaves its node in `deploying`; no verb accepts it there, so waving it
# through as "already advanced" makes the run fail two phases later at `inspect`, with a
# message about inspect and nothing about the strand. (That is exactly how it failed.)
for st in verifying deploying cleaning rescuing deleting; do
    rc="$(harness "$st")"
    [[ "$rc" == 0 ]] \
        || fail "the driver aborted on a node stranded in '$st' (rc=$rc) instead of recovering it. The control plane has a verb for this and the run should use it"
    grep -q "^abort node1$" "$SANDBOX/calls" \
        || fail "REGRESSION: a node stranded in transient state '$st' was not aborted. Nothing accepts a node mid-transition, so it was waved through as 'already advanced' and the run died later somewhere unrelated — the strand is the cause and the message named something else"
    grep -q '^manage node1$' "$SANDBOX/calls" \
        || fail "REGRESSION: '$st' was aborted but never managed. abort lands the node in 'error'; without the follow-up 'manage' it is recoverable and not recovered, which fails the same way one phase later"
    _abort_line="$(grep -n 'abort node1' "$SANDBOX/calls" || true)"
    grep -q '^1:' <<<"$_abort_line" \
        || fail "'manage' was issued before 'abort' for a node in '$st' — manage cannot accept a transient state, so the order is the whole fix"
done
note "each transient state is aborted into 'error' and then managed, in that order  ✓"

# The list this script drives must be the list the control plane defines. Two hand-kept
# copies of one fact drift, and the drift is silent: a state added to the control plane
# and not here goes straight back to being swallowed by the permissive branch.
e2e_list="$(sed -nE 's/^E2E_TRANSIENT="([^"]+)".*/\1/p' "$E2E" | head -1)"
maas_list="$(sed -nE 's/^TRANSIENT_STATES="([^"]+)".*/\1/p' "$LAB_DIR/maas-lab.sh" | head -1)"
[[ -n "$e2e_list" && -n "$maas_list" ]] \
    || fail "could not read both transient-state lists (run-e2e.sh: '$e2e_list', maas-lab.sh: '$maas_list')"
[[ "$e2e_list" == "$maas_list" ]] \
    || fail "REGRESSION: run-e2e.sh's transient-state list ('$e2e_list') no longer matches maas-lab.sh's ('$maas_list'). A state the control plane treats as transient but this script does not is a state that gets waved through as 'already advanced' — silently, and two phases from where it fails"
note "the driver's transient-state list matches the control plane's  ✓"

pass "phase 4 gets the node to 'manageable' from wherever the last run left it — managing enrolled/error/available, aborting a strand, releasing an active node whose domain phase 3 just rebuilt — and STOPS on anything it cannot drive there rather than waving it through"
