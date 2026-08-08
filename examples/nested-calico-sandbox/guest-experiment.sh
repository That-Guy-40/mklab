#!/usr/bin/env bash
# guest-experiment.sh — run INSIDE the sandbox guest, as root. Prints machine-readable
# `NCS-*` lines that the host-side harness asserts on.
#
# ── WHAT IT MEASURES, AND WHY IN THIS ORDER ─────────────────────────────────────────────
#
#   §1  the guest's OWN candidate set + the Calico version. Constraint 1 of the brief: the
#       candidate ordering depends on which interfaces exist, and this guest has neither
#       `lxdbr0` nor `incusbr0` — the two that decided the host's F.8. Reusing the host's
#       list would be the cached-fact bug one layer down.
#   §2  rule 2 — two decoys, addressed, differing ONLY in name; then WAIT for the poll.
#   §3  the CONTROL that makes §2 mean anything — delete the winner and see where it falls
#       back to. Without it, "Calico took mc-decoy" is equally explained by "it took the
#       highest index", and the `^br-.*` exclusion is unproven.
#
# ── WAIT, DO NOT RESTART ────────────────────────────────────────────────────────────────
#
# Autodetection re-runs on a ~60-second poll for the process lifetime; restarting
# `calico-node` measures the STARTUP path only, which is the half already understood.
# Measured 2026-08-07: one interval was not enough — still on the incumbent at ~100 s,
# moved by ~3 min. So the waits here are generous and the script reports how long it took
# rather than assuming a number.
#
# ── EVERY microk8s CALL IS ABSOLUTE ─────────────────────────────────────────────────────
#
# `/snap/bin` is not on sudo's secure_path. A bare `microk8s` under sudo is
# "command not found", which the first spike reported as a cluster failure while the
# cluster was fine.
set -uo pipefail

MK=/snap/bin/microk8s
POLL_WAIT="${NCS_POLL_WAIT:-240}"   # generous: the migration took ~3 min when measured
DECOY_EXCLUDED=br-decoy             # matches ^br-.*  -> Calico should never pick it
DECOY_CANDIDATE=mc-decoy            # does not match  -> a legitimate candidate
ADDR_EXCLUDED=10.99.1.1/24
ADDR_CANDIDATE=10.99.2.1/24

say() { printf 'NCS-%s\n' "$*"; }

binding() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'dev [a-zA-Z0-9._-]+' | awk '{print $2}'; }
binding_addr() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+' | awk '{print $2}'; }

# Wait until the tunnel binds to something OTHER than $1, or the deadline passes.
# Returns the interface it ended on either way — a timeout is a result, not an error.
await_move() {  # await_move <from-iface> <secs>
    local from="$1" secs="$2" t0=$SECONDS now
    while (( SECONDS - t0 < secs )); do
        now="$(binding)"
        if [[ -n "$now" && "$now" != "$from" ]]; then
            printf '%s %s\n' "$now" "$((SECONDS - t0))"; return 0
        fi
        sleep 5
    done
    printf '%s %s\n' "$(binding)" "$((SECONDS - t0))"; return 1
}

# ── 1. this guest's own facts, derived here and never inherited ────────────
[[ $EUID -eq 0 ]] || { say "FATAL not-root"; exit 2; }
command -v "$MK" >/dev/null 2>&1 || { say "FATAL no-microk8s at $MK"; exit 2; }

CAL_IMG="$("$MK" kubectl get ds -n kube-system calico-node \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
[[ -n "$CAL_IMG" ]] || { say "FATAL no-calico-daemonset"; exit 2; }
say "CALICO-IMAGE=$CAL_IMG"
say "CALICO-VERSION=${CAL_IMG##*:}"
say "MICROK8S-VERSION=$(snap list microk8s 2>/dev/null | awk 'NR==2{print $2}')"

# The autodetection METHOD matters as much as the version: these rules are `first-found`
# behaviour, and a cluster pinned to `can-reach` or an interface regex would answer a
# different question while looking identical from outside.
METHOD="$("$MK" kubectl get ds -n kube-system calico-node \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null \
    | sed -n 's/^IP_AUTODETECTION_METHOD=//p')"
say "AUTODETECTION-METHOD=${METHOD:-<unset>}"

say "CANDIDATE-SET=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | tr '\n' ' ')"
START_IF="$(binding)"; START_ADDR="$(binding_addr)"
say "BINDING-BEFORE=${START_IF:-<absent>} addr=${START_ADDR:-<none>}"
[[ -n "$START_IF" ]] || { say "FATAL no-vxlan-calico — nothing to watch move"; exit 2; }

# ── 2. rule 2: an addressed interface becomes a candidate ──────────────────
# Both decoys are created and addressed. They differ ONLY in name, which is the entire
# independent variable — anything else that differed would confound the result.
for pair in "$DECOY_EXCLUDED $ADDR_EXCLUDED" "$DECOY_CANDIDATE $ADDR_CANDIDATE"; do
    set -- $pair
    ip link add "$1" type dummy 2>/dev/null
    ip addr add "$2" dev "$1" 2>/dev/null
    ip link set "$1" up 2>/dev/null
done
say "DECOYS-UP $(ip -o link show | awk -F': ' '/decoy/{printf "%s(idx %s) ", $2, $1}')"

read -r moved_if moved_secs <<<"$(await_move "$START_IF" "$POLL_WAIT")"
say "BINDING-AFTER-DECOYS=${moved_if:-<none>} after=${moved_secs}s"

# ── 3. THE CONTROL — delete the winner and see where it falls back ─────────
# This is what separates "the exclusion is real" from "the highest index won". If Calico
# now takes br-decoy (index HIGHER than the incumbent, addressed, up), then ordering
# explains everything and rule 1 is unproven. If it skips br-decoy for the incumbent, the
# only difference left is the NAME.
if [[ "$moved_if" == "$DECOY_CANDIDATE" ]]; then
    ip link del "$DECOY_CANDIDATE"
    say "CONTROL-DELETED=$DECOY_CANDIDATE (br-decoy still up, addressed, higher index than the incumbent)"
    read -r fallback_if fallback_secs <<<"$(await_move "$DECOY_CANDIDATE" "$POLL_WAIT")"
    say "BINDING-AFTER-CONTROL=${fallback_if:-<none>} after=${fallback_secs}s"
    say "EXCLUDED-DECOY-STILL-PRESENT=$(ip -4 -o addr show "$DECOY_EXCLUDED" 2>/dev/null | awk '{print $4}')"
else
    # Not a failure of the harness — a different answer, and it must be reported as one
    # rather than silently skipping the control.
    say "CONTROL-SKIPPED reason=calico-did-not-take-$DECOY_CANDIDATE (took '${moved_if:-nothing}')"
fi

say "END"
