# lib/e2e-common.sh — helpers shared by the live runners (run-e2e-image.sh,
# run-e2e-measured.sh). Sourced, not executed.
#
# Requires the caller to have set: MAAS (path to maas-lab.sh), and to provide
# `info` and `die`.

# make_deployable <node> — bring a node to a state `deploy` will accept, or refuse
# with the verb that would.
#
# WHY THIS IS SHARED RATHER THAN COPIED. Both runners need it, and they had it in
# different states of completeness: run-e2e-image.sh handled `active`, `error` and
# `manageable`, run-e2e-measured.sh handled nothing at all, and NEITHER handled a
# node stuck in a **transient** state. That gap cost a full live run on 2026-07-29 —
# an earlier attempt was interrupted at the EFI shell, leaving node3 in `deploying`,
# and the next run rebuilt the fleet, rebuilt a 20 MB UKI, staged, signed and started
# the sink before the state machine finally said
#
#     maas: cannot 'deploy' node 'node3' from state 'deploying'
#           — needs one of: available active
#
# ...which is correct behaviour from the control plane and a preflight failure
# arriving several minutes late. So: one implementation, called early.
#
# THE TRANSIENT CASE IS THE INTERESTING ONE. A node stranded mid-transition is the
# STRANDED rung of this lab's own chaos ladder, and the recovery the system offers is
# `abort` (transient -> error, with the reason recorded) followed by `retry` and
# `provide`. Using the real verbs matters: a harness that reached into the registry
# and wrote `available` would be testing a state the control plane never produces.
make_deployable() {
    local node="$1" st
    st="$( ( "$MAAS" state "$node" ) 2>/dev/null )"
    case "$st" in
        available)
            return 0 ;;
        active)
            info "'$node' is active — releasing it back to available first"
            ( "$MAAS" release "$node" --wiped ) >/dev/null 2>&1 || true ;;
        error)
            ( "$MAAS" retry "$node" )   >/dev/null 2>&1 || true
            ( "$MAAS" provide "$node" ) >/dev/null 2>&1 || true ;;
        manageable)
            ( "$MAAS" provide "$node" ) >/dev/null 2>&1 || true ;;
        enrolled|verifying)
            ( "$MAAS" manage "$node" )  >/dev/null 2>&1 || true
            ( "$MAAS" provide "$node" ) >/dev/null 2>&1 || true ;;
        deploying|cleaning|releasing|maintenance)
            # Stranded mid-transition, almost always because a previous run was
            # interrupted. Say so — a run that silently repairs the wreckage of the
            # last one hides the fact that the last one did not finish.
            info "'$node' is stuck in the transient state '$st' (an earlier run was"
            info "  interrupted). Recovering with the verbs the control plane offers:"
            info "  abort -> retry -> provide."
            ( "$MAAS" abort "$node" --reason "interrupted live run (recovered by $(basename "${0:-e2e}"))" ) >/dev/null 2>&1 || true
            ( "$MAAS" retry "$node" )   >/dev/null 2>&1 || true
            ( "$MAAS" provide "$node" ) >/dev/null 2>&1 || true ;;
        "")
            die "node '$node' has no state — is it enrolled?" ;;
    esac

    st="$( ( "$MAAS" state "$node" ) 2>/dev/null )"
    case "$st" in
        available|active) ;;
        *) die "'$node' is in state '$st', which 'deploy' will not accept (it needs
available or active), and the recovery verbs did not move it. Look at the node and
recover it by hand:
  $MAAS show $node
  $MAAS abort $node   # if it is stuck mid-transition
  $MAAS retry $node ; $MAAS provide $node" ;;
    esac
    info "'$node' is '$st' — deployable"
}
