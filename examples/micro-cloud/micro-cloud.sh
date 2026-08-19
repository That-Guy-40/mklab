#!/usr/bin/env bash
# micro-cloud.sh — MICRO_CLOUD_LAB_PLAN.md §9.1 / §14 slice 10: the demo.
#
#        examples/micro-cloud/micro-cloud.sh plan     # the ordered commands. Runs NOTHING.
#   sudo examples/micro-cloud/micro-cloud.sh up       # runs them, halting on the first failure
#        examples/micro-cloud/micro-cloud.sh status   # derived, unprivileged
#   sudo examples/micro-cloud/micro-cloud.sh down     # reverses ours, asserts absence, compares Calico
#
# -----------------------------------------------------------------------------
# WHAT THIS SCRIPT IS, AND THE THREE THINGS IT REFUSES TO BE
#
# It orders the phase tools.  It does not *know* the order: `plan_up`/`plan_down` in
# `phase6-tui/lab_tui/topology.py` already compute it — which slot runs when, which driver
# has `up` and which has `create`+`start`, which name a `start` takes — and slice 6 paid
# for every one of those answers by measuring the drivers rather than reading their help.
# Re-deriving them here would be §4.1's *clone in disguise*, and the copy would be wrong
# the first time a driver grew a verb.  So this script ASKS for the plan and executes it,
# and the only thing it adds is the one layer the control plane does not own:
#
#   THE FABRIC.  `topology.py`'s own docstring says it: *"the tap is NOT ours to make …
#   a bring-up through this screen therefore assumes the fabric already ran."*  `lab-fc.sh`
#   validates a tap and never creates one, because two owners for one resource is the
#   stale-record bug this repo keeps finding.  `fabric.sh` owns tap lifecycle and needs
#   root.  Putting the two together — fabric first, instances second, reversed on the way
#   down — is this file's entire contribution.
#
# 1. IT IS NOT A FIFTH DRIVER.  Every command it runs is one you can type; `plan` prints
#    them, in order, with the `cd` that makes the relative paths resolve.  §0.2: *delete
#    the guided path and nothing is lost.*  `plan` is the proof, and it is what
#    tests/test-micro-cloud-plan.sh asserts against.
#
# 2. IT DOES NOT WAIT FOR READINESS, AND SAYS SO.  `up` orders INVOCATIONS, not states.
#    Nothing here blocks until a guest answers, so a first-boot script that talks to a peer
#    can lose the race with it — `edge`'s cloud-init pings `api1`, and the control plane
#    starts VMs before microVMs, so on a cold `up` that probe reports FAIL.  Reordering the
#    slot tuple would not fix it (a 0.5 s microVM boot still races a cloud-init that began
#    30 s earlier); a readiness wait would, and the control plane has none.  `status` is
#    where you find out, and RUNBOOK-micro-cloud.md re-runs the peer check from there.
#
# 3. IT RECORDS NOTHING IT COULD DERIVE.  There is no state file of instance addresses.
#    §8.4a settled it: *derive the facts, record only the intent.*  The intent is
#    `micro-cloud.toml`; the addresses come back out of the fabric's lease file, the
#    liveness out of each driver's own `inspect`.  A cached address list is the record that
#    outlives its subject, and this plan has a whole table of those.
#
# WHY `up` HALTS INSTEAD OF CONVERGING
# ------------------------------------
# `lab-chroot.sh create` refuses a target that exists; `lab-fc.sh create` refuses an
# instance that exists (it would clobber a per-instance rootfs copy).  Those refusals are
# correct and this script does not work around them: a second `up` halts, naming the step
# and its exit status.  Converging is a different verb with a different contract and it is
# already built — `phase6-tui/lab_tui/apply.py`, whose whole design note is that a second
# pass must be a no-op *because the diff finds nothing to do*.  A `--force` here would be a
# third answer to a question two components already answer.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"
# Overridable so the plan test can aim this at a DELIBERATELY BROKEN copy of the spec and
# watch the assertions bite.  A guard nobody has seen fail is not known to work, and a test
# that can only ever feed the real spec can only ever watch it pass.
SPEC_REL="${MC_SPEC:-examples/micro-cloud/micro-cloud.toml}"
# An absolute MC_SPEC used to be pasted onto the repo root -- "$REPO//tmp/x.toml" -- and the
# failure was silent in the worst way: `plan_json` passes SPEC_REL straight through and was
# fine, so the topology half of the plan looked perfect while `tap_instances` read a path
# that does not exist and contributed NO fabric taps at all. A plan missing every tap still
# parses, still orders correctly, and would have brought up VMMs opening devices nobody
# made. Found by the tap assertion in tests/test-micro-cloud-plan.sh on its first real run.
if [[ "$SPEC_REL" == /* ]]; then SPEC="$SPEC_REL"; else SPEC="$REPO/$SPEC_REL"; fi
FABRIC="$HERE/fabric.sh"
LAB="micro-cloud"

# The `cd` is not a convenience, it is the same line `plan` prints for the reader.  The
# spec's `kernel`/`rootfs` are repo-relative and `lab-fc.sh` uses them as given, so a run
# from anywhere else resolves them somewhere else -- and the failure would be "kernel not
# readable", which reads like a missing image rather than a wrong directory.  Running the
# script and pasting its plan must be the same act; this makes them so.
cd "$REPO"

# ── WHO RUNS THE INSTANCES, AND WHY IT IS NOT ROOT ───────────────────────────
# `up` needs root, but only for the FABRIC. Running the instance steps as root too was the
# first privileged run's blocking defect, and it is worth stating precisely because it looks
# like a permissions nuisance and is actually the lab's central lesson inverted:
#
#     FAIL  tap mc-api1 is owned by uid 1000, not 0 — Firecracker would get EPERM
#
# `fabric.sh` hands each tap to the INVOKING user on purpose, so the VMM can open it with no
# privilege at all — that is slice 2's finding and slice 5a's test drops both VMMs to uid
# 1000 precisely so the ownership assertion means something. A root `up` would have run
# Firecracker as uid 0 against a tap built for uid 1000: refused by the preflight, and had it
# not been, it would have thrown away the isolation property this lab exists to demonstrate.
# The same collision sits one step further on — `lab-podman.sh` refuses to run as root at
# all, because `metrics` is a ROOTLESS sidecar (§9.3's exhibit).
#
# So the privilege boundary follows the resource: the network is root's, the instances are
# yours. `runuser` sets HOME to the target user's, which is what makes `lab-fc.sh` and
# friends use YOUR state directory rather than root's — otherwise root creates instances a
# later unprivileged `status` cannot see.
#
# The owner is read from the SAME variable `fabric.sh` uses to decide who owns a tap. Two
# independent answers to "who is this lab for" is exactly how the two halves came to
# disagree in the first place.
RUN_AS="${MC_OWNER:-${SUDO_USER:-}}"

# WHICH SLOTS KEEP ROOT, AND WHY EACH ONE DOES.
#
# The privilege requirement is PER SLOT, not uniform. The first version of this drop was
# uniform, which would have run `lab-chroot.sh create` as an unprivileged user
# — which would have traded one collision for another. Each entry names the reason, because
# a list of slot names with no reasons is a cached decision nobody can re-check:
#
#   chroot  KEEPS ROOT. `debootstrap` makes device nodes and chroots into the tree. Phase 1
#           does have a `--rootless` mode (fakechroot), but it does not survive a base with
#           systemd helpers, which a Debian bookworm base has.
#
# Everything else is dropped, and for each the reason is a property of the resource:
#   vm, fc  the TAPS ARE THE USER'S (fabric.sh creates them owned by $RUN_AS so the VMM
#           needs no privilege at all — slice 2, and slice 5a's test asserts it).
#   podman  `lab-podman.sh` REFUSES to run as root without --allow-root: `metrics` is a
#           rootless sidecar and that is §9.3's exhibit.
#   lxd     the engine is reached through a group-owned socket (`incus-admin`/`lxd`), so the
#           user reaches it and root would create instances under a different project view.
#   docker  same shape, via the `docker` group.
_ROOT_SLOTS=" chroot "

# The argv prefix that drops privilege for THIS slot, or nothing when there is none to drop
# or the slot must keep it. It is PREPENDED INTO THE PLAN rather than applied invisibly at
# execution time, so `plan` prints the command that actually runs — a plan that quietly
# differs from the run is not a view of anything.
drop_prefix() {
    local slot="${1:-}"
    [[ "$_ROOT_SLOTS" == *" $slot "* ]] && return 0
    if (( EUID == 0 )) && [[ -n "$RUN_AS" && "$RUN_AS" != root ]]; then
        printf '%s\n' runuser -u "$RUN_AS" --
    fi
}

ESC=$'\033'
bold(){ printf '%s[1m%s%s[0m\n' "$ESC" "$*" "$ESC"; }
c_ok(){   printf '  %s[32m+%s[0m %s\n' "$ESC" "$ESC" "$*"; }
c_run(){  printf '%s[1m-> %s%s[0m\n' "$ESC" "$*" "$ESC"; }
c_warn(){ printf '  %s[33m!%s[0m %s\n' "$ESC" "$ESC" "$*"; }
die(){    printf '%s[31mFAIL:%s[0m %s\n' "$ESC" "$ESC" "$*" >&2; exit 1; }

# The instances that need a tap from the fabric.  DERIVED from the spec — a hand-written
# list here would be a second description of the topology, and it would go stale in the
# direction that hurts: an instance added to the TOML would come up with no tap, and
# `lab-fc.sh`'s preflight would refuse it while pointing at a fabric nobody had told.
# A `tap =` line is what makes an instance the fabric's business.
tap_instances(){
    python3 - "$SPEC" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for block in ("microvm", "vm"):
    for item in doc.get(block) or []:
        if item.get("tap"):
            print(item["name"])
PY
}

microvm_names(){
    python3 - "$SPEC" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for item in doc.get("microvm") or []:
    print(item["name"])
PY
}

need_root(){
    [[ ${EUID} -eq 0 ]] || die "'$1' needs root: the fabric creates a bridge, taps and nft rules (CAP_NET_ADMIN). Re-run with: sudo $0 $1"
}

# The topology plan, as argv ARRAYS.  `--json` rather than the text form because splitting
# a joined command on whitespace is the lossy seam quoting exists to remove, and this is
# the one script whose whole job is running the same command the plan names.
plan_json(){
    local op="$1"
    PYTHONPATH="$REPO/phase6-tui" python3 -m lab_tui.topology --json "$op" "$SPEC_REL" \
        || die "could not compute the $op plan from $SPEC_REL (lab_tui.topology). That module is stdlib-only, so this is a spec error rather than a missing dependency — the message above is the parser's."
}

# Run one step, or print it.  Halts the whole run on a non-zero, naming the step: a
# tear-down that carried on past a failure would report success over a half-removed lab.
DRY=0
# Quote an argv for a human to paste.  `printf '%q ' "$@"` is the obvious one-liner and it
# leaves a TRAILING SPACE on every line — which cost this file its first ordering check:
# `grep 'fabric.sh up$'` matched nothing, so the check compared two empty positions and the
# negative control appeared to bite for a reason that was not the one under test.  Joining
# an array with IFS has no such edge.
quoted(){ local -a q=(); local a; for a in "$@"; do q+=("$(printf '%q' "$a")"); done; printf '%s' "${q[*]}"; }

step(){
    local desc="$1" rc=0; shift
    if (( DRY )); then
        printf '# %s\n' "$desc"
        printf '%s\n' "$(quoted "$@")"
        return 0
    fi
    c_run "$desc"
    # Not `... || die`: the status of the command is the gate, so it is captured on its own
    # line and tested afterwards.  A pipe or a `||` chain here reports somebody else's rc.
    "$@" || rc=$?
    (( rc == 0 )) || die "step failed (rc=$rc): $desc
    the command was: $(quoted "$@")"
}

run_topology(){
    local op="$1" json n i desc
    json="$(plan_json "$op")"
    n="$(jq 'length' <<<"$json")"
    for ((i = 0; i < n; i++)); do
        local -a argv=()
        # NUL-delimited, so an argument containing a space survives.  `lab-vm.sh` and
        # `lab-chroot.sh` are addressed by absolute path and a repo checked out under
        # "/my labs/" would otherwise split into two arguments here.
        mapfile -t -d '' argv < <(jq -j --argjson i "$i" '.[$i].argv[] | (. + ([0] | implode))' <<<"$json")
        desc="$(jq -r --argjson i "$i" '.[$i].description' <<<"$json")"
        # The instances are the invoking user's; see the note by RUN_AS. An `echo` step is
        # the driver telling you something (phase 1 and 2 emit advice rather than acting),
        # so it is left alone -- wrapping a message in runuser would be theatre.
        local slot; slot="$(jq -r --argjson i "$i" '.[$i].slot' <<<"$json")"
        local -a pre=()
        if [[ "${argv[0]}" != "echo" ]]; then
            mapfile -t pre < <(drop_prefix "$slot")
        fi
        step "$desc" ${pre+"${pre[@]}"} "${argv[@]}"
    done
}

fabric_steps(){
    local name
    step "fabric: bridge, nft, dnsmasq" "$FABRIC" up
    while read -r name; do
        [[ -n "$name" ]] && step "fabric: tap for $name" "$FABRIC" tap "$name"
    done < <(tap_instances)
}

cmd_plan(){
    DRY=1
    printf '# micro-cloud - the whole lab, as commands. Nothing below has been run.\n'
    printf '# Paths in %s are repo-relative, so the directory is part of the plan:\n' "$SPEC_REL"
    printf 'cd %q\n\n' "$REPO"
    printf '# -- the fabric (root; the control plane does not own the network) --\n'
    fabric_steps
    printf '\n# -- the instances (lab_tui.topology decides this order, not this script) --\n'
    run_topology up
    printf '\n# -- and back down --\n'
    run_topology down
    step "fabric: reverse ONLY ours, assert absence, compare Calico" "$FABRIC" down
}

# Rootless podman needs a user runtime directory, and root's is not it.
#
# `runuser` resets HOME but leaves XDG_RUNTIME_DIR alone, so a step dropped to $RUN_AS would
# inherit whatever the root shell had -- unset, or /run/user/0. Rootless podman then cannot
# find its runtime state and fails in a way that reads like a podman problem rather than an
# environment one. `sudo -E` usually carries the right value through, but "usually" is not a
# contract, so it is derived from the target user here and exported for every dropped step.
fix_runtime_dir(){
    local uid
    [[ -n "$RUN_AS" && "$RUN_AS" != root ]] || return 0
    (( EUID == 0 )) || return 0
    uid="$(id -u "$RUN_AS" 2>/dev/null)" || return 0
    if [[ -d "/run/user/$uid" ]]; then
        export XDG_RUNTIME_DIR="/run/user/$uid"
    else
        c_warn "no /run/user/$uid — rootless podman may refuse; log in as $RUN_AS once, or"
        c_warn "enable lingering: loginctl enable-linger $RUN_AS"
    fi
}

cmd_up(){
    need_root up
    [[ -r "$SPEC" ]] || die "spec not found: $SPEC"
    fix_runtime_dir
    fabric_steps
    run_topology up
    printf '\n'
    c_ok "every step returned 0 - which is not the same as every guest being ready."
    c_warn "run '$0 status' for what is actually up, and see RUNBOOK-micro-cloud.md for"
    c_warn "the peer check: 'up' orders invocations, not readiness (header note 2)."
}

# Which declared VMs are still running, by asking phase 2 rather than guessing.
#
# `down` stops microVMs and leaves VMs alone -- deliberately: a VM's disk is expensive
# persistent state and a teardown that reaps it is one you run once and then stop trusting.
# But the fabric step immediately after DELETES THE TAPS those VMs are using, so a VM that
# survives `down` survives it with its network yanked out. Observed 2026-08-19: `edge` was
# still `running` after a clean `down rc=0`, on a tap that no longer existed.
#
# That is not a reason to start destroying VMs. It is a reason to SAY SO: on this repo's own
# ladder, a machine left in a state nobody named is the STRANDED rung, and the difference
# between stranded and merely stopped is entirely whether the operator was told.
running_vms(){
    local n
    while read -r n; do
        [[ -n "$n" ]] || continue
        "$REPO/phase2-qemu-vm/lab-vm.sh" list 2>/dev/null \
            | awk -v want="$n" '$1 == want && $0 ~ /running/ { print want }'
    done < <(python3 - "$SPEC" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for item in doc.get("vm") or []:
    if item.get("tap"):
        print(item["name"])
PY
)
}

cmd_down(){
    need_root down
    fix_runtime_dir
    run_topology down

    local -a stranded=()
    mapfile -t stranded < <(running_vms)
    if (( ${#stranded[@]} )); then
        printf '\n'
        c_warn "STILL RUNNING, and the next step removes the taps they are using:"
        c_warn "  ${stranded[*]}"
        c_warn "phase 2 keeps VMs across a teardown on purpose (the disk is expensive), but"
        c_warn "the fabric owns the taps and is about to delete them — so these will keep"
        c_warn "running with a dead NIC. Stop them first if that is not what you want:"
        local v
        for v in "${stranded[@]}"; do
            c_warn "  $REPO/phase2-qemu-vm/lab-vm.sh stop $v"
        done
    fi

    step "fabric: reverse ONLY ours, assert absence, compare Calico" "$FABRIC" down
}

# `status` derives.  It reads nothing this script wrote, because this script writes nothing.
cmd_status(){
    local name state rc
    bold "-- the fabric --"
    rc=0; "$FABRIC" status || rc=$?
    (( rc == 0 )) || c_warn "fabric status returned rc=$rc"

    bold ""
    bold "-- the instances, each driver asked directly --"
    # THREE OUTCOMES, AND THE MIDDLE ONE IS THE REASON THIS LOOKS FUSSY.
    #
    # The first version ran `inspect <name> --json` and piped it to jq. Phase 7's `inspect`
    # HAS NO `--json` — phases 2 and 5 do, and the flag was written here by analogy with
    # them — and it does not reject the unknown flag either: it prints its ordinary TOML and
    # exits 0. So jq failed, the fallback fired, and `status` reported
    #     api1  microvm  UNKNOWN (driver could not be asked)
    # about a microVM that was RUNNING and answering `inspect` perfectly. Measured on the
    # first successful privileged run, where step 3b's direct call printed `state = "running"`
    # three lines further down the same log.
    #
    # A false UNKNOWN is not the safe direction. The whole point of UNKNOWN being a verdict
    # is that it means *nobody could look* — and once it can also mean *I looked wrongly*, it
    # stops carrying information in either direction. So the driver's own exit status decides
    # which of the three this is, and "could not be asked" is reserved for the case where it
    # genuinely could not.
    local out rc
    while read -r name; do
        [[ -n "$name" ]] || continue
        rc=0; out="$("$REPO/phase7-firecracker/lab-fc.sh" inspect "$name" 2>&1)" || rc=$?
        if (( rc != 0 )); then
            # The driver refused. It says why — usually "no such instance" — and that is a
            # fact about the lab, not a failure to observe it.
            printf '  %-9s %-10s %s\n' "$name" "microvm" "not created (${out##*: })"
        else
            state="$(sed -n 's/^state[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' <<<"$out" | head -1)"
            printf '  %-9s %-10s %s\n' "$name" "microvm" \
                "${state:-UNKNOWN: the driver answered but printed no state line}"
        fi
    done < <(microvm_names)

    rc=0; "$REPO/phase2-qemu-vm/lab-vm.sh"    list                2>/dev/null | sed 's/^/  vm      /' || rc=$?
    rc=0; "$REPO/phase4-podman/lab-podman.sh" status "$LAB"       2>/dev/null | sed 's/^/  podman  /' || c_warn "podman: nothing for lab '$LAB'"
    rc=0; "$REPO/phase5-lxd/lab-lxd.sh"       status "$LAB"       2>/dev/null | sed 's/^/  lxd     /' || c_warn "lxd: nothing for lab '$LAB'"

    bold ""
    bold "-- addresses, read back from the leases, never from a record of ours --"
    # The fabric's dnsmasq lease file. THIS PATH IS A COPY OF `STATE` IN fabric.sh, and it
    # is the second thing in this lab bound to its source by a test rather than trusted:
    # tests/test-spec-is-one-description.sh reads fabric.sh's own STATE= line and refuses a
    # mismatch. The first version of this line guessed `/var/lib/misc/mc-dnsmasq.leases` —
    # dnsmasq's distro default, and not what the fabric passes to `--dhcp-leasefile` — so
    # `status` would have reported every address as UNKNOWN on every run, while looking like
    # it had checked. Caught by reading fabric.sh before the first privileged run, not by it.
    local leases="${MC_LEASES:-/run/mklab-mc/leases}"
    if [[ -r "$leases" && -s "$leases" ]]; then
        awk '{printf "  %-18s %-16s %s\n", $4, $3, $2}' "$leases"
    elif [[ -r "$leases" ]]; then
        # AN EMPTY LEASE FILE IS NOT AN UNREADABLE ONE. The fabric truncates this file at
        # `up`, so "exists but empty" means the fabric is serving and nothing has asked yet
        # -- a reserved instance that has not booted, or one that booted without a NIC. The
        # first version printed nothing at all here, which read as though the section had
        # failed to run.
        c_warn "the fabric is up and its lease file is EMPTY: no guest has taken an address YET."
        c_warn "A reservation is not a lease -- 'fabric.sh tap <name>' reserves one, and a"
        c_warn "guest appears here only once it has actually DHCPed."
        c_warn "IF YOU RAN THIS STRAIGHT AFTER 'up', THIS IS THE READINESS GAP, NOT A FAULT:"
        c_warn "'up' returns when the VMMs are running, and a guest still has to boot and"
        c_warn "complete a DHCP exchange after that. Observed 2026-08-19: this section was"
        c_warn "empty while both guests' consoles already showed 'dhcp rc=0' and their"
        c_warn "reserved addresses. Wait a moment and run 'status' again, or read the truth"
        c_warn "from the guest itself: less \$LAB_STATE_DIR/fc/<name>/fc.log"
    else
        c_warn "no readable lease file at $leases"
        c_warn "addresses are UNKNOWN, which is not the same as 'none' - the fabric may be"
        c_warn "down, or the file may simply not be readable as this user."
    fi
}

usage(){
    cat <<EOF
micro-cloud.sh - order the phase tools for the whole lab (plan section 9.1, slice 10)

USAGE
  micro-cloud.sh plan          the ordered commands, with the cd. Runs nothing.
  micro-cloud.sh up            run them (needs root: the fabric does)
  micro-cloud.sh status        what is actually up, derived. Unprivileged.
  micro-cloud.sh down          reverse ours, assert absence, compare Calico's binding

The spec is $SPEC_REL - one file, five blocks, each one a block a phase driver
already parses. The order comes from lab_tui.topology, not from this script.

'up' orders invocations, not readiness: nothing here waits for a guest to answer.
EOF
}

case "${1:-}" in
    plan)           shift; cmd_plan "$@" ;;
    up)             shift; cmd_up "$@" ;;
    down)           shift; cmd_down "$@" ;;
    status)         shift; cmd_status "$@" ;;
    help|--help|-h) usage ;;
    "")             usage >&2; exit 1 ;;
    *)              printf 'unknown verb: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
esac
