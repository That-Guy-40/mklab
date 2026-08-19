#!/usr/bin/env bash
# Verdict: `micro-cloud.sh plan` is the whole lab, as commands you could type — and it
# ran none of them.
#
# MICRO_CLOUD_LAB_PLAN §14 slice 10 is "the demo", and §0.2's invariant applies to it more
# than to anything else in the lab: *the guided path is a VIEW of the raw path … delete the
# guided path and nothing is lost.*  `micro-cloud.sh` is the top of that view, so the
# question this file asks is not "does up work" (that needs root, a bridge, and five
# engines) but the one a green CI run CAN answer:
#
#     is the plan a faithful, complete, executable description of the lab?
#
# Four ways it could fail to be, each with its own assertion:
#
#   COMPLETE      every instance the spec declares appears in the plan.  DERIVED from the
#                 TOML, so an instance added to the spec and forgotten by the router fails
#                 here rather than being quietly absent from the lab.
#   ORDERED       the fabric comes up before any instance and goes down after all of them.
#                 `lab-fc.sh` validates a tap and never makes one; an instance step ahead
#                 of its tap is a refusal at best and a silent dynamic lease at worst.
#   PARSEABLE     the plan is valid shell, so a reader who pastes it gets the command the
#                 script would have run rather than a syntax error.  (Whether each VERB is
#                 real is asked by tools/check-guided-path-is-a-view.sh §3 — see below.)
#   INERT         `plan` executed nothing.  It is the one verb a reader is invited to run
#                 before they trust the script, so it must be safe to run while distrusting
#                 it.
#
# AND EACH ONE IS RUN AGAINST A BROKEN SPEC FIRST.  §0 below aims the same assertions at a
# copy of the spec with a fault injected and requires them to FAIL.  An all-PASS result is
# indistinguishable from a check that looks at nothing — this repo has shipped that twice,
# both times a regex standing in for a question — so the controls run every time, not once
# when the file was written.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need python3 jq
MC="$LAB_DIR/micro-cloud.sh"
[[ -x "$MC" ]] || fail "micro-cloud.sh is missing or not executable: $MC"

WORK="$(mktemp -d)"
on_exit 'rm -rf -- "$WORK"'

# ── helpers ─────────────────────────────────────────────────────────────────
# The declared names, per block, straight out of the TOML the script is aimed at.
declared_names() {
    python3 - "$1" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for block in ("chroot", "vm", "microvm", "instance", "service"):
    for item in doc.get(block) or []:
        print(f"{block}\t{item['name']}")
PY
}

plan_of() {  # plan_of <spec-path> -> stdout, rc preserved
    local spec="$1" rc=0 out
    out="$(MC_SPEC="$spec" "$MC" plan 2>&1)" || rc=$?
    printf '%s\n' "$out"
    return "$rc"
}

# The four questions, as functions, so §0 can aim them at a broken spec and §1 at the real
# one.  Each returns 0 when the property HOLDS.  They print nothing: the caller decides
# whether a failure is the point.
q_complete() {  # every declared name appears in the plan text
    local plan="$1" spec="$2" block name
    while IFS=$'\t' read -r block name; do
        [[ -n "$name" ]] || continue
        # chroot and the two container blocks are addressed by --config rather than by
        # name, so their NAME need not appear; what must appear is their driver.
        case "$block" in
            microvm|vm) grep -qE "(^| )$name( |$)" <<<"$plan" || return 1 ;;
        esac
    done < <(declared_names "$spec")
    return 0
}

q_ordered() {  # fabric up before every instance step; fabric down after every one
    local plan="$1"
    local up_line down_line first_inst last_inst
    up_line="$(grep -n 'fabric.sh up$'   <<<"$plan" | head -1 | cut -d: -f1)"
    down_line="$(grep -n 'fabric.sh down$' <<<"$plan" | tail -1 | cut -d: -f1)"
    first_inst="$(grep -nE 'lab-(chroot|vm|fc|podman|lxd|docker)\.sh ' <<<"$plan" | head -1 | cut -d: -f1)"
    last_inst="$( grep -nE 'lab-(chroot|vm|fc|podman|lxd|docker)\.sh ' <<<"$plan" | tail -1 | cut -d: -f1)"
    [[ -n "$up_line" && -n "$down_line" && -n "$first_inst" && -n "$last_inst" ]] || return 1
    (( up_line < first_inst )) || return 1
    (( down_line > last_inst )) || return 1
    return 0
}

# THERE IS NO VERB PROBE IN THIS FILE, ON PURPOSE.
# "every verb the plan names is a verb that tool has" is asked by
# tools/check-guided-path-is-a-view.sh §3, which renders this exact plan and runs each
# command's tool with the verb and with a verb nobody has.  A second copy of that probe
# here would be the duplication this whole slice argues against — and the first draft of
# this file proved the point by getting it wrong: it added `--help` to the invocation, so
# `lab-vm.sh start --help` and `lab-vm.sh <nonce> --help` printed the same banner and the
# probe declared the real verb ABSENT.  One implementation, proved once, in the file that
# already carries its 8 self-controls.  This suite execs it: tests/test-guided-path-is-a-view.sh.

# ── §0 — the controls. Break it, watch each assertion bite. ──────────────────
note "§0 negative controls — each assertion aimed at a deliberately broken plan"

# (a) COMPLETE: drop a microVM from the spec but leave the plan's expectation derived from
#     a spec that still has it.  Aim q_complete at the FULL spec while planning the SHORT
#     one: the missing instance must be noticed.
python3 - "$LAB_DIR/micro-cloud.toml" "$WORK/short.toml" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# Remove the api2 block: from its [[microvm]] header to the next top-level table.
out = re.sub(r'\[\[microvm\]\]\nname    = "api2".*?(?=\n#|\n\[\[)', '', src, flags=re.S)
assert 'name    = "api2"' not in out, "control fixture did not actually drop api2"
open(sys.argv[2], "w").write(out)
PY
short_plan="$(plan_of "$WORK/short.toml")" || fail "the control spec did not even plan: $short_plan"
if q_complete "$short_plan" "$LAB_DIR/micro-cloud.toml"; then
    fail "CONTROL DID NOT BITE: a spec missing api2 planned without it and the completeness check passed anyway — it is not comparing the plan against the declaration"
fi
note "(a) completeness bit when api2 was dropped from the spec"

# (b) ORDERED: move the fabric's `up` from the top of the real plan to the bottom and
#     require q_ordered to object.  Built by EDITING the real plan, so the control cannot
#     drift away from the thing it controls.
#
#     The first version of this control passed while proving nothing, which is the reason it
#     is worth writing down: `micro-cloud.sh plan` used to end every line with a trailing
#     space (from `printf '%q '`), so `grep 'fabric.sh up$'` matched neither the line it
#     removed nor the line it was looking for — the control "bit" because BOTH positions
#     came back empty, not because the order was wrong.  The plan's printer is fixed and
#     this control now removes a line that is really there; the guard below says so.
real_plan="$(plan_of "$LAB_DIR/micro-cloud.toml")"
grep -qE 'fabric\.sh up$' <<<"$real_plan" \
    || fail "the control cannot run: no line in the plan matches 'fabric.sh up$' at all, so removing it proves nothing. That is how this control passed for the wrong reason once already"
bad_order="$(grep -vE 'fabric\.sh up$' <<<"$real_plan"; printf '%s up\n' "$LAB_DIR/fabric.sh")"
if q_ordered "$bad_order"; then
    fail "CONTROL DID NOT BITE: the fabric's 'up' moved to the END of the plan and the ordering check still passed — it is not comparing positions"
fi
note "(b) ordering bit when 'fabric.sh up' was moved after the instances"

# ── §1 — the real spec ───────────────────────────────────────────────────────
SPEC="$LAB_DIR/micro-cloud.toml"
[[ -r "$SPEC" ]] || fail "the lab's one spec is missing: $SPEC"

rc=0
PLAN="$(plan_of "$SPEC")" || rc=$?
(( rc == 0 )) || fail "'micro-cloud.sh plan' exited rc=$rc as an unprivileged user. It must run nothing, so it must need nothing: $PLAN"

q_complete "$PLAN" "$SPEC" \
    || fail "INCOMPLETE: an instance declared in micro-cloud.toml does not appear in the plan — the router did not claim it, so 'up' would bring up a lab that is missing it silently"
note "every declared microVM and VM appears in the plan"

q_ordered "$PLAN" \
    || fail "MIS-ORDERED: the fabric does not come up before the first instance step, or down after the last. lab-fc.sh validates a tap and never creates one, so an instance ahead of its tap is refused — or worse, takes a dynamic lease and looks fine"
note "fabric up precedes every instance step; fabric down follows every one"

# Every tap-carrying instance is given a tap, and no other.  The fabric and the spec are
# two files that have to agree about which instances are the fabric's business.
for name in $(python3 - "$SPEC" <<'PY'
import sys, tomllib
doc = tomllib.load(open(sys.argv[1], "rb"))
for b in ("microvm", "vm"):
    for i in doc.get(b) or []:
        if i.get("tap"):
            print(i["name"])
PY
); do
    grep -qE "fabric\.sh tap $name( |$)" <<<"$PLAN" \
        || fail "'$name' declares a tap in the spec but the plan never asks the fabric for one — its VMM would open a device that does not exist"
done
note "every instance declaring a tap has a matching 'fabric.sh tap' step"

# The plan is a script, so it has to parse as one.  `%q`-quoted argv that did not survive
# the JSON round trip shows up here rather than at 2 a.m. in a paste.
printf '%s\n' "$PLAN" | bash -n 2>"$WORK/parse.err" \
    || fail "the plan is not valid shell — a reader pasting it gets a syntax error: $(head -3 "$WORK/parse.err")"
note "the plan parses as a shell script (bash -n)"

# INERT.  `plan` is the verb you run while still distrusting the script.
[[ ! -d /sys/class/net/br-mc0 ]] \
    || fail "REGRESSION: br-mc0 exists after 'micro-cloud.sh plan' — plan executed the fabric instead of printing it"
stray="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -c '^mc-' || true)"
(( stray == 0 )) \
    || fail "REGRESSION: $stray mc-* taps exist after 'micro-cloud.sh plan' — plan is not inert"
note "plan created no bridge and no taps: it printed, it did not run"

# The repo's kill rule, on the two scripts this slice adds to the lab.
for f in "$MC" "$LAB_DIR/fabric.sh"; do
    if grep -nE '\b(pkill|killall)\b' "$f" >/dev/null 2>&1; then
        fail "$(basename "$f") kills by pattern (pkill/killall). A pattern matches every process whose argv contains the string — here that includes the QEMU whose cmdline carries the same tap and socket paths"
    fi
done
note "neither micro-cloud.sh nor fabric.sh kills by pattern"

pass "the plan is complete, ordered, parseable and inert — and both controls bit first"
