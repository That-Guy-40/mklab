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
#   LIED       the registry and the machine DISAGREE — it says one image, the driver
#              really put another one there (or one that never deployed at all).
#              Worse than being down, because everything downstream believes it and
#              nothing can tell they diverged.                        ← CRITICAL
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
# HOUSE RULE (CLAUDE.md): every DISCRETE LAYER of this lab gets a fault-injection
# point, and a layer with no scenario here is a layer nobody has tested falling over.
# Each scenario declares the layer it injects at, `--layers` reports the coverage, and
# tests/test-chaos-matrix.sh FAILS when a deploy driver ships without a scenario. The
# layers, each with its own seam:
#
#   driver      the deploy interface   (drivers/chaos.sh, MAAS_DRIVER_DIR)
#   oob         the BMC seam           (MOCK_BMC_FAIL — the controller stops answering)
#   artifact    the signed payload store (MAAS_IMAGES_DIR — the payload is gone/corrupt)
#   registry    the state store        (MAAS_STATE — it cannot be written)
#   process     the control plane itself (killed mid-transition)
#   metadata    the facts sink         (metadata-serve.sh :8282 — no facts arrive)
#   console     the console/milestone stream (the log `watch` and the health gates read)
#   reconcile   the `apply` loop       (increment 6 — it computes from the REGISTRY,
#               the one thing the registry-layer fault proved can diverge from reality)
#   ui          the actions panel      (increment 7 — a surface that CALLS verbs fails
#               in ways the CLI cannot: a keypress that fires twice, a row that is
#               stale by the time it is acted on)
#
# Headless: mock BMC, chaos driver, throwaway registry. No libvirt, no root, no boot.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"
JSON=0; LAYERS_ONLY=0
case "${1:-}" in --json) JSON=1 ;; --layers) LAYERS_ONLY=1 ;; esac

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
crit=0; total=0; declare -a ROWS=(); LAYERS_SEEN=""
ALL_LAYERS="driver oob artifact registry process metadata console reconcile ui"

state_of() { ( "$MAAS" state "$1" ) 2>/dev/null; }
img_of()   { cat "$MAAS_STATE/$1/image" 2>/dev/null; }
# did the bad image actually get deployed to this node, or was it refused first?
was_deployed() { grep -q "^deploy $1 $2" "$CHAOS_LOG" 2>/dev/null; }
# what the DRIVER last actually put on the machine — the only reality check available
# from outside the registry. Comparing it against the registry is what catches a
# control plane that believes writes it never made.
really_running() { grep "^deploy $1 " "$CHAOS_LOG" 2>/dev/null | tail -1 | awk '{print $3}'; }
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
    # Before anything else: does the record match the machine? A node that reports a
    # tidy state while running a different image is the worst outcome on the ladder.
    local real; real="$(really_running "$node")"
    if [[ -n "$real" && -n "$img" && "$real" != "$img" && "$st" == active ]]; then
        printf 'LIED\tregistry says "%s" but the driver really deployed "%s"\n' "$img" "$real"
        return
    fi
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

# scenario <layer> <name> <fault> <seed-good:0|1> <description>
scenario() {
    local layer="$1" name="$2" fault="$3" seed="$4" desc="$5"
    LAYERS_SEEN="$LAYERS_SEEN $layer"
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
    elif [[ "$fault" == artifact-gone ]]; then
        # The ARTIFACT layer: the signed payload vanishes between staging and deploy
        # (a cleaned cache, a half-finished rsync). verify should refuse; the node
        # must not be powered on to boot something that is not there.
        rm -rf "${MAAS_IMAGES_DIR:?}/$subject"
        ( export CHAOS_FAULT=none CHAOS_USE_BMC=1
          "$MAAS" deploy "$node" --driver chaos --image "$subject" ) >/dev/null 2>&1
        mkdir -p "$MAAS_IMAGES_DIR/$subject"                     # restore for later scenarios
        printf 'PAYLOAD-%s\n' "$subject" > "$MAAS_IMAGES_DIR/$subject/payload.img"
        "$HERE/drivers/verify-lib.sh" sign "$MAAS_IMAGES_DIR/$subject/payload.img" \
            --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1
    elif [[ "$fault" == registry-readonly ]]; then
        # The REGISTRY layer: the state store goes read-only mid-deploy (a full disk,
        # a remounted volume). The question is whether the control plane notices, or
        # carries on believing writes it never made.
        chmod a-w "$MAAS_STATE/$node" 2>/dev/null
        ( export CHAOS_FAULT=none CHAOS_USE_BMC=1
          "$MAAS" deploy "$node" --driver chaos --image "$subject" ) >/dev/null 2>&1
        chmod u+w "$MAAS_STATE/$node" 2>/dev/null
    elif [[ "$fault" == bmc-drop ]]; then
        # The out-of-band layer dies while the deploy is in flight. The fault is at the
        # BMC seam, not in the driver — so the driver runs clean and reaches for
        # hardware that no longer answers.
        ( export CHAOS_FAULT=none CHAOS_USE_BMC=1 MOCK_BMC_FAIL=power
          "$MAAS" deploy "$node" --driver chaos --image "$subject" ) >/dev/null 2>&1
    elif [[ "$fault" == bmc-misbound ]]; then
        # The OOB layer's nastiest shape — the second live run hit it by accident, when
        # two BMCs defaulted to one port and the winner served IPMI for both: every
        # power command SUCCEEDED and every answer was TRUE, about the wrong machine.
        # `bmc-drop` announces itself; this one passes every through-the-seam check by
        # construction, so the defence under test is the health gate's CONSOLE check —
        # the console is bolted to the machine, not the BMC, and the subject's silent
        # console is the one witness the mis-binding cannot fake. (lib/vbmc_check.py
        # prevents the original accident at enroll time; this scenario asks what
        # happens when a mis-binding gets past it anyway.)
        mkdir -p "$WORK/consoles"
        ( export CHAOS_FAULT=none CHAOS_USE_BMC=1 \
                 CHAOS_CONSOLE_DIR="$WORK/consoles" MOCK_BMC_CONSOLE_DIR="$WORK/consoles" \
                 MOCK_BMC_ACTUATES="victim-of-$node"
          "$MAAS" deploy "$node" --driver chaos --image "$subject" ) >/dev/null 2>&1
        # Prove the fault FIRED: the victim machine must really have been powered on
        # behind its owner's back — that collateral is what makes this failure class
        # expensive, and a scenario whose fault never actuated grades nothing.
        [[ "$(cat "$MOCK_BMC_POWER_DIR/victim-of-$node.power" 2>/dev/null)" == on ]] \
            || { echo "chaos-run: bmc-misbound fault did not fire — the victim machine was never powered on" >&2; exit 1; }
    else
        ( export CHAOS_FAULT="$fault"
          "$MAAS" deploy "$node" --driver chaos --image "$subject" ) >/dev/null 2>&1
    fi

    local verdict why
    IFS=$'\t' read -r verdict why < <(grade "$node" "$had_prev" "$fault" "$subject")
    case "$verdict" in STRANDED|LIED|STALE) crit=$((crit+1)) ;; esac
    ROWS+=("$verdict|$name|$desc|$why|$layer")
}

# push_row <layer> <name> <desc> <verdict> <why> — for layers whose fault is not a
# deploy at all. They still land on the same ladder.
push_row() {
    total=$((total+1)); LAYERS_SEEN="$LAYERS_SEEN $1"
    case "$4" in STRANDED|LIED|STALE) crit=$((crit+1)) ;; esac
    ROWS+=("$4|$2|$3|$5|$1")
}

# METADATA layer: the facts sink never received anything (the service was down, or the
# probe never booted). `inspect --from-metadata` must refuse — recording facts it never
# got would put invented hardware into the scheduler's view.
scenario_metadata() {
    local node="m1"
    ( "$MAAS" enroll "$node" --bmc-port 6360 ) >/dev/null 2>&1
    ( "$MAAS" manage "$node" ) >/dev/null 2>&1
    if ( "$MAAS" inspect "$node" --from-metadata ) >/dev/null 2>&1; then
        push_row metadata "facts-sink-empty" "no facts ever arrived at the sink" \
            LIED "inspect recorded facts the sink never received"
    elif [[ "$( ( "$MAAS" state "$node" ) 2>/dev/null )" == manageable ]]; then
        push_row metadata "facts-sink-empty" "no facts ever arrived at the sink" \
            ABSORBED "refused; node stayed manageable with no invented facts"
    else
        push_row metadata "facts-sink-empty" "no facts ever arrived at the sink" \
            HALTED "refused and moved the node out of manageable"
    fi
}

# CONSOLE layer: the console log a node's progress is read from is not there. `watch`
# must say so — a progress bar invented from an absent stream is worse than none,
# because the operator watches it and believes it.
scenario_console() {
    local node="c1" out
    ( "$MAAS" enroll "$node" --bmc-port 6361 ) >/dev/null 2>&1
    ( "$MAAS" manage "$node" ) >/dev/null 2>&1
    out="$( ( "$MAAS" watch "$node" ) 2>&1 )"
    if [[ $? -eq 0 ]]; then
        push_row console "console-missing" "the console log does not exist" \
            LIED "watch reported progress from a stream that is not there"
    elif grep -qi "not found" <<<"$out"; then
        push_row console "console-missing" "the console log does not exist" \
            ABSORBED "watch refused and named the missing console"
    else
        push_row console "console-missing" "the console log does not exist" \
            HALTED "watch failed, but without naming the missing console"
    fi
}

# CONSOLE layer, the second shape: the console is RECORDED and nothing writes to it.
#
# This one is not hypothetical — it is what the first live end-to-end run actually hit.
# The registry named a console, so every check that asks "is it configured?" said yes,
# and the file stayed empty because no process and no device was attached to it. It is
# strictly nastier than a missing console: absent fails loudly at the first `watch`,
# whereas silent looks fully instrumented and only shows up as a health-gate timeout
# several minutes and one wrong diagnosis later.
#
# The bar: the divergence must be VISIBLE where an operator looks (`show`), not
# inferable from a downstream timeout.
scenario_console_silent() {
    local node="c2" con="$WORK/c2-console.log" out
    ( "$MAAS" enroll "$node" --bmc-port 6363 ) >/dev/null 2>&1
    ( "$MAAS" manage "$node" ) >/dev/null 2>&1
    : > "$con"                                   # recorded, exists, and stays empty
    ( "$MAAS" set-console "$node" "$con" ) >/dev/null 2>&1
    out="$( ( "$MAAS" show "$node" ) 2>&1 )"
    if grep -qiE 'console .*(empty|ABSENT)' <<<"$out"; then
        push_row console "console-silent" "the console is recorded but nothing writes to it" \
            ABSORBED "show flags the console as recorded-but-empty, before anything waits on it"
    elif grep -q "$con" <<<"$out"; then
        push_row console "console-silent" "the console is recorded but nothing writes to it" \
            STALE "show reports the console as configured and never checks whether anything is writing it — the record and reality agreed once and nobody re-checked"
    else
        push_row console "console-silent" "the console is recorded but nothing writes to it" \
            STALE "the recorded console is not surfaced at all, so a silent one cannot be noticed"
    fi
}

# RECONCILE layer: the registry says a node is active; its payload is dead. `apply`
# computes its actions from the registry, so without a reality check it would see the
# desired state SATISFIED and converge on a fleet that is not serving.
scenario_reconcile() {
    local node="r1" spec="$WORK/reconcile.toml"
    printf '[[node]]\nname="%s"\nbmc_port=6362\ndriver="chaos"\nimage="good-v1"\n' "$node" > "$spec"
    ( export CHAOS_FAULT=none; "$MAAS" apply "$spec" ) >/dev/null 2>&1
    [[ "$(state_of "$node")" == active ]] || {
        push_row reconcile "apply-over-dead-node" "apply cannot even converge a healthy node" \
            HALTED "apply did not reach active on a clean run"; return; }
    # now the payload dies underneath it — the registry still says active
    ( export CHAOS_FAULT=health-fail CHAOS_TARGET='good-*'
      "$MAAS" apply "$spec" ) >/dev/null 2>&1
    if [[ "$(state_of "$node")" == active ]]; then
        push_row reconcile "apply-over-dead-node" "the node's payload died; the registry still says active" \
            STALE "apply reported convergence over a node whose payload is dead"
    else
        push_row reconcile "apply-over-dead-node" "the node's payload died; the registry still says active" \
            HALTED "apply's pre-flight health re-check caught it before diffing"
    fi
}

# UI layer: a panel that CALLS verbs fails in ways a shell does not. Two shapes, both
# specific to a surface where a single key does something:
#   1. the key fires TWICE (auto-repeat, a double tap, an impatient operator)
#   2. the row acted on is STALE — the node moved on between the render and the press
# The declared-action contract is what is under test: MAAS says which of its verbs the
# panel may drive, and marks the one that is safe to repeat.
scenario_ui() {
    local node="u1" fleet="$WORK/cp" spec="$WORK/ui.toml"
    printf '[[node]]\nname="%s"\nbmc_port=6363\ndriver="chaos"\nimage="good-v1"\n' "$node" > "$spec"
    # env assignments belong INSIDE the subshell — `VAR=x ( … )` is a syntax error
    ( export LAB_STATE_DIR="$WORK" CHAOS_FAULT=none; "$MAAS" apply "$spec" ) >/dev/null 2>&1
    ( export LAB_STATE_DIR="$WORK"; "$MAAS" watch "$node" --register-only ) >/dev/null 2>&1
    fleet="$WORK/control-pane"
    local cp="$HERE/../../tools/control-pane"
    if [[ ! -x "$cp" || ! -f "$fleet/$node/node.toml" ]]; then
        push_row ui "double-press" "the panel key fires twice" \
            HALTED "control-pane or the registration is unavailable here"
        return
    fi

    # 1. the panel may only drive DECLARED verbs — never one it composed itself
    if ( "$cp" run "$node" "destroy-everything" --fleet "$fleet" ) >/dev/null 2>&1; then
        push_row ui "undeclared-verb" "the panel runs a verb the owner never declared" \
            LIED "the panel ran a command its owner never declared"
        return
    fi

    # 2. the reconcile key, pressed twice. It must converge, not repeat.
    local before after
    before="$(state_of "$node")"
    ( export CHAOS_FAULT=none; "$cp" run "$node" a --fleet "$fleet" ) >/dev/null 2>&1
    ( export CHAOS_FAULT=none; "$cp" run "$node" a --fleet "$fleet" ) >/dev/null 2>&1
    after="$(state_of "$node")"
    if [[ "$before" != active || "$after" != active ]]; then
        push_row ui "double-press" "the reconcile key fires twice" \
            HALTED "the node did not stay active across two presses (before=$before after=$after)"
        return
    fi

    # 3. a STALE row: the panel was rendered while the node was active, the node has
    #    since been pulled into maintenance, and the key is pressed against the old row.
    ( "$MAAS" maintenance "$node" ) >/dev/null 2>&1
    ( export CHAOS_FAULT=none; "$cp" run "$node" h --fleet "$fleet" ) >/dev/null 2>&1
    if [[ "$(state_of "$node")" == maintenance ]]; then
        push_row ui "stale-row" "a key pressed against a row that moved on" \
            ABSORBED "declared verbs only, safe to repeat, and a stale press hit the verb's own precondition"
    else
        push_row ui "stale-row" "a key pressed against a row that moved on" \
            LIED "a stale press moved a node out of maintenance behind the operator"
    fi
    ( "$MAAS" unmaintenance "$node" ) >/dev/null 2>&1
}

# ── the matrix ───────────────────────────────────────────────────────────────
# Every scenario deploys `bad-v2`. Half start from a node already serving `good-v1`,
# so the A/B fallback has somewhere to fall; half start fresh, where it does not.
scenario driver   "none (control)"           none                 1 "no fault at all — the positive control"
scenario driver   "verify-fail (had good)"   verify-fail          1 "F2 refuses the new image"
scenario driver   "verify-fail (fresh)"      verify-fail          0 "F2 refuses, nothing to fall back to"
scenario driver   "deploy-fail (had good)"   deploy-fail          1 "the deploy step fails cleanly"
scenario driver   "deploy-crash (had good)"  deploy-crash         1 "the driver dies with no message"
scenario driver   "deploy-crash (fresh)"     deploy-crash         0 "driver dies, nothing to fall back to"
scenario driver   "partial (had good)"       partial              1 "deploy reports success; the payload is broken"
scenario driver   "health-fail (had good)"   health-fail          1 "boots, never becomes healthy"
scenario driver   "health-fail (fresh)"      health-fail          0 "never healthy, nothing to fall back to"
scenario driver   "health-flap (had good)"   health-flap          1 "passes the gate, then dies"
scenario artifact "artifact-gone (had good)" artifact-gone        1 "the signed payload vanished after staging"
scenario registry "registry-readonly"        registry-readonly    1 "the state store goes read-only mid-deploy"
scenario oob      "bmc-drop (had good)"      bmc-drop             1 "the BMC stops answering mid-deploy"
scenario oob      "bmc-misbound (had good)"  bmc-misbound         1 "the BMC answers, truthfully, about a DIFFERENT machine"
scenario process  "control-plane-killed"     control-plane-killed 1 "maas-lab.sh is killed mid-deploy"
scenario_metadata
scenario_console
scenario_console_silent
scenario_reconcile
scenario_ui

# ── the report ───────────────────────────────────────────────────────────────
# JSON string escaping: the detail strings quote image names, so an unescaped
# emitter produces output that only LOOKS like JSON until something parses it.
jesc() { local x="${1//\\/\\\\}"; x="${x//\"/\\\"}"; printf '%s' "$x"; }

if [[ $JSON == 1 ]]; then
    printf '{"total":%d,"critical":%d,"layers":"%s","rows":[' "$total" "$crit" "$ALL_LAYERS"
    sep=""
    for r in "${ROWS[@]}"; do
        IFS='|' read -r v n d w l <<<"$r"
        printf '%s{"verdict":"%s","scenario":"%s","fault":"%s","detail":"%s","layer":"%s"}' \
            "$sep" "$(jesc "$v")" "$(jesc "$n")" "$(jesc "$d")" "$(jesc "$w")" "$(jesc "$l")"
        sep=","
    done
    printf ']}\n'
    exit $(( crit > 0 ))
fi

printf '\n  %-9s  %-9s  %-24s  %s\n' VERDICT LAYER SCENARIO OUTCOME >&2
printf '  %-9s  %-9s  %-24s  %s\n' "---------" "---------" "------------------------" "-------" >&2
for r in "${ROWS[@]}"; do
    IFS='|' read -r v n d w l <<<"$r"
    printf '  %-9s  %-9s  %-24s  %s\n' "$v" "$l" "$n" "$w" >&2
done

uncovered=""
for L in $ALL_LAYERS; do
    case " $LAYERS_SEEN " in *" $L "*) : ;; *) uncovered="$uncovered $L" ;; esac
done
if [[ $LAYERS_ONLY == 1 ]]; then
    for L in $ALL_LAYERS; do
        n=0; for r in "${ROWS[@]}"; do [[ "${r##*|}" == "$L" ]] && n=$((n+1)); done
        printf '%s %d\n' "$L" "$n"
    done
    exit 0
fi

absorbed=0; degraded=0; halted=0
for r in "${ROWS[@]}"; do
    case "${r%%|*}" in ABSORBED) absorbed=$((absorbed+1)) ;; DEGRADED) degraded=$((degraded+1)) ;; HALTED) halted=$((halted+1)) ;; esac
done
printf '\n  %d scenarios across %d layers (%s): %d absorbed (goal), %d degraded, %d halted honestly, %d CRITICAL\n' \
    "$total" "$(wc -w <<<"$ALL_LAYERS")" "$(tr -s " " <<<"$ALL_LAYERS")" "$absorbed" "$degraded" "$halted" "$crit" >&2
[[ -n "$uncovered" ]] && printf '  NOTE: declared layers with no scenario:%s\n' "$uncovered" >&2

if [[ $crit -gt 0 ]]; then
    printf 'FAIL: %d of %d injected faults became a CRITICAL failure — a node stranded in a transient state no verb accepts, or a registry claiming an image that never deployed or has since died\n' "$crit" "$total" >&2
    exit 1
fi
printf 'PASS: no injected fault became a critical failure — every one was absorbed, fell back to a good image, or halted honestly with a verb that can recover it\n' >&2
