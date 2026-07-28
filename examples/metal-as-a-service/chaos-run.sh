#!/usr/bin/env bash
# chaos-run.sh — inject a fault at each point a deploy can break, and grade how the
# control plane falls.
#
# THE LADDER. Fallback and graceful failure are not the goal; they are the acceptable
# INTERMEDIATE rungs. The goal is that a fault never becomes a failure at all:
#
#   ABSORBED   the fault never reached the service at all — the bad image was refused
#              BEFORE it was deployed, so the node never stopped serving. ← the goal
#   DEGRADED   still serving, but the bad image did get deployed and the node had to
#              fall back to its previous one. There was an outage window; the tenant
#              is up again and someone must still fix the new image.  ← acceptable
#   HALTED     not serving, but it stopped HONESTLY: `error`, with a reason, and a
#              verb that can pick it back up.                         ← acceptable
#   ─────────────────────────────────────────────────────────────────────────────
#   STRANDED   stuck in a transient state (deploying/cleaning/…) that no verb
#              accepts. Nothing is wrong with the hardware and nothing can be done
#              with it either.                                        ← CRITICAL
#   LIED       the registry claims something reality does not support — `active` on
#              an image that never deployed. Worse than being down, because
#              everything downstream believes it.                     ← CRITICAL
#   STALE      `active`, and it WAS true when the gate ran — but the node has since
#              gone unhealthy and nothing re-checks. Also a lie, just a slower one.
#                                                                     ← CRITICAL
#
# A run PASSES when there are ZERO critical outcomes. Intermediate rungs are counted
# and reported — each one names what would have to change to move it up.
#
# The harness attempts the RECOVERY the control plane offers before grading: `abort`
# for a node stuck mid-transition, `recheck` for one that passed its gate and has since
# died. That is the honest test — "critical" should mean "nothing can be done about
# it", not "the first thing I looked at was still wrong". Both verbs exist BECAUSE this
# harness found the cases; see PLAN.md's increment-5 notes.
#
# Headless: mock BMC, chaos driver, throwaway registry. No libvirt, no root, no boot.
# Faults are injected at TWO layers, because they fail differently: the deploy driver
# (drivers/chaos.sh) and the out-of-band seam (mock-bmc.sh's fault knobs).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"
JSON=0; [[ "${1:-}" == "--json" ]] && JSON=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export MAAS_STATE="$WORK/maas"
export MAAS_BMC="$HERE/tests/mock-bmc.sh"
export MOCK_BMC_LOG="$WORK/bmc.log"; : > "$MOCK_BMC_LOG"
export MOCK_BMC_POWER_DIR="$WORK/power"
export MAAS_DRIVER_DIR="$HERE/drivers"
export MAAS_IMAGES_DIR="$WORK/images"
export MAAS_HEALTH_TIMEOUT=2 MAAS_POLL_INTERVAL=0
export CHAOS_STATE="$WORK/chaos"
export CHAOS_LOG="$WORK/chaos-calls.log"; : > "$CHAOS_LOG"
mkdir -p "$MAAS_IMAGES_DIR/trust" "$CHAOS_STATE"
"$HERE/drivers/verify-lib.sh" gen-keys --dir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
    || { echo "chaos-run: openssl is required (verify-lib gen-keys failed)" >&2; exit 77; }
for img in good-v1 good-v2 bad-v2; do
    mkdir -p "$MAAS_IMAGES_DIR/$img"
    printf 'PAYLOAD-%s\n' "$img" > "$MAAS_IMAGES_DIR/$img/payload.img"
    "$HERE/drivers/verify-lib.sh" sign "$MAAS_IMAGES_DIR/$img/payload.img" \
        --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1
done

TRANSIENT="verifying deploying cleaning rescuing deleting"
crit=0; total=0; declare -a ROWS=()

state_of() { ( "$MAAS" state "$1" ) 2>/dev/null; }
img_of()   { cat "$MAAS_STATE/$1/image" 2>/dev/null; }
# did the bad image actually get deployed to this node, or was it refused first?
was_deployed() { grep -q "^deploy $1 $2" "$CHAOS_LOG" 2>/dev/null; }
# re-run the driver's OWN health check on what the registry says is current. This is
# the question the control plane never asks again after activation.
still_healthy() {
    local node="$1" img; img="$(img_of "$node")"
    [[ -n "$img" ]] || return 1
    ( CHAOS_FAULT="$2" MAAS_STATE="$MAAS_STATE" "$HERE/drivers/chaos.sh" health "$node" "$img" ) >/dev/null 2>&1
}

# grade <node> <had-previous:0|1> <fault> — put the final condition on the ladder.
grade() {
    local node="$1" had_prev="$2" fault="$3" subject="$4" st img
    st="$(state_of "$node")"; img="$(img_of "$node")"
    for t in $TRANSIENT; do
        if [[ "$st" == "$t" ]]; then
            # Is there a way out? `abort` is the verb that exists for exactly this.
            ( "$MAAS" abort "$node" --reason "stranded by an injected fault" ) >/dev/null 2>&1
            if [[ "$(state_of "$node")" == error ]]; then
                printf 'HALTED\twas stuck mid-%s; `abort` recovered it to "error", then `retry`\n' "$t"
            else
                printf 'STRANDED\tstuck in transient state "%s"; no verb accepts it\n' "$st"
            fi
            return
        fi
    done
    case "$st" in
    active)
        if [[ "$img" == "$subject" ]]; then
            # the node is running the image this scenario deployed
            if still_healthy "$node" "$fault"; then
                printf 'ABSORBED\tdeployed "%s" and it is healthy\n' "$img"
            elif ! was_deployed "$node" "$subject"; then
                printf 'LIED\tregistry says active on "%s", which never deployed\n' "$img"
            else
                # It was true when the gate ran. Does anything ever ask again?
                ( export CHAOS_FAULT="$fault"; "$MAAS" recheck "$node" ) >/dev/null 2>&1
                if [[ "$(state_of "$node")" == error ]]; then
                    printf 'HALTED\tpassed its gate then died; `recheck` caught it and demoted it to "error"\n'
                else
                    printf 'STALE\tactive on "%s" — true at the gate, unhealthy now, nothing re-checks\n' "$img"
                fi
            fi
        elif [[ "$had_prev" == 1 ]] && was_deployed "$node" "$subject"; then
            printf 'DEGRADED\tfell back to "%s" after "%s" was deployed and failed\n' "$img" "$subject"
        elif [[ "$had_prev" == 1 ]]; then
            printf 'ABSORBED\tstill active on "%s"; "%s" was refused before it was deployed\n' "$img" "$subject"
        else
            printf 'ABSORBED\tactive on "%s"\n' "$img"
        fi ;;
    error)
        printf 'HALTED\tstopped in "error" — retry/abort can pick it up\n' ;;
    *)  printf 'HALTED\tended in "%s"\n' "$st" ;;
    esac
}

# scenario <name> <fault> <seed-good:0|1> <description>
scenario() {
    local name="$1" fault="$2" seed="$3" desc="$4"
    local node="n$((total+1))"
    # the no-fault control deploys an image that is MEANT to work; every other
    # scenario deploys the one the fault targets
    local subject=bad-v2; [[ "$fault" == none ]] && subject=good-v2
    total=$((total+1))
    ( "$MAAS" enroll "$node" --bmc-port "$((6300+total))" ) >/dev/null 2>&1
    ( "$MAAS" manage  "$node" ) >/dev/null 2>&1
    ( "$MAAS" provide "$node" ) >/dev/null 2>&1
    local had_prev=0
    if [[ "$seed" == 1 ]]; then
        ( export CHAOS_FAULT=none; "$MAAS" deploy "$node" --driver chaos --image good-v1 ) >/dev/null 2>&1
        [[ "$(state_of "$node")" == active ]] || { echo "chaos-run: could not seed $node with a good image" >&2; exit 1; }
        had_prev=1
    fi

    if [[ "$fault" == control-plane-killed ]]; then
        # The control plane itself dies mid-deploy. Kill BY PID (never a pattern —
        # `pkill -f maas` would match this harness and the editor you are reading it in).
        ( export CHAOS_FAULT=deploy-slow CHAOS_SLOW=10
          "$MAAS" deploy "$node" --driver chaos --image "$subject" ) >/dev/null 2>&1 &
        local pid=$!
        sleep 1
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    elif [[ "$fault" == bmc-drop ]]; then
        # The out-of-band layer dies while the deploy is in flight. The fault is at the
        # BMC seam, not in the driver — so the driver runs clean and reaches for
        # hardware that no longer answers.
        ( export CHAOS_FAULT=none CHAOS_USE_BMC=1 MOCK_BMC_FAIL=power
          "$MAAS" deploy "$node" --driver chaos --image "$subject" ) >/dev/null 2>&1
    else
        ( export CHAOS_FAULT="$fault"
          "$MAAS" deploy "$node" --driver chaos --image "$subject" ) >/dev/null 2>&1
    fi

    local verdict why
    IFS=$'\t' read -r verdict why < <(grade "$node" "$had_prev" "$fault" "$subject")
    case "$verdict" in STRANDED|LIED|STALE) crit=$((crit+1)) ;; esac
    ROWS+=("$verdict|$name|$desc|$why")
}

# ── the matrix ───────────────────────────────────────────────────────────────
# Every scenario deploys `bad-v2`. Half start from a node already serving `good-v1`,
# so the A/B fallback has somewhere to fall; half start fresh, where it does not.
scenario "none (control)"           none                 1 "no fault at all — the positive control"
scenario "verify-fail (had good)"   verify-fail          1 "F2 refuses the new image"
scenario "verify-fail (fresh)"      verify-fail          0 "F2 refuses, nothing to fall back to"
scenario "deploy-fail (had good)"   deploy-fail          1 "the deploy step fails cleanly"
scenario "deploy-crash (had good)"  deploy-crash         1 "the driver dies with no message"
scenario "deploy-crash (fresh)"     deploy-crash         0 "driver dies, nothing to fall back to"
scenario "partial (had good)"       partial              1 "deploy reports success; the payload is broken"
scenario "health-fail (had good)"   health-fail          1 "boots, never becomes healthy"
scenario "health-fail (fresh)"      health-fail          0 "never healthy, nothing to fall back to"
scenario "health-flap (had good)"   health-flap          1 "passes the gate, then dies"
scenario "bmc-drop (had good)"      bmc-drop             1 "the BMC stops answering mid-deploy"
scenario "control-plane-killed"     control-plane-killed 1 "maas-lab.sh is killed mid-deploy"

# ── the report ───────────────────────────────────────────────────────────────
# JSON string escaping: the detail strings quote image names, so an unescaped
# emitter produces output that only LOOKS like JSON until something parses it.
jesc() { local x="${1//\\/\\\\}"; x="${x//\"/\\\"}"; printf '%s' "$x"; }

if [[ $JSON == 1 ]]; then
    printf '{"total":%d,"critical":%d,"rows":[' "$total" "$crit"
    sep=""
    for r in "${ROWS[@]}"; do
        IFS='|' read -r v n d w <<<"$r"
        printf '%s{"verdict":"%s","scenario":"%s","fault":"%s","detail":"%s"}' \
            "$sep" "$(jesc "$v")" "$(jesc "$n")" "$(jesc "$d")" "$(jesc "$w")"
        sep=","
    done
    printf ']}\n'
    exit $(( crit > 0 ))
fi

printf '\n  %-9s  %-24s  %s\n' VERDICT SCENARIO OUTCOME >&2
printf '  %-9s  %-24s  %s\n' "---------" "------------------------" "-------" >&2
for r in "${ROWS[@]}"; do
    IFS='|' read -r v n d w <<<"$r"
    printf '  %-9s  %-24s  %s\n' "$v" "$n" "$w" >&2
done

absorbed=0; degraded=0; halted=0
for r in "${ROWS[@]}"; do
    case "${r%%|*}" in ABSORBED) absorbed=$((absorbed+1)) ;; DEGRADED) degraded=$((degraded+1)) ;; HALTED) halted=$((halted+1)) ;; esac
done
printf '\n  %d scenarios: %d absorbed (goal), %d degraded, %d halted honestly, %d CRITICAL\n' \
    "$total" "$absorbed" "$degraded" "$halted" "$crit" >&2

if [[ $crit -gt 0 ]]; then
    printf 'FAIL: %d of %d injected faults became a CRITICAL failure — a node stranded in a transient state no verb accepts, or a registry claiming an image that never deployed or has since died\n' "$crit" "$total" >&2
    exit 1
fi
printf 'PASS: no injected fault became a critical failure — every one was absorbed, fell back to a good image, or halted honestly with a verb that can recover it\n' >&2
