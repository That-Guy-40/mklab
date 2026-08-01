#!/usr/bin/env bash
# lab-sweep.sh — find (and optionally remove) mklab TEST DEBRIS across every engine.
#
#   usage:  tools/lab-sweep.sh            # DRY RUN — inventory + what it would remove
#           tools/lab-sweep.sh --apply    # actually remove it
#   exits:  0 = clean · 1 = something could not be removed (the engine's reason is
#           printed) · 2 = debris found on a dry run — usable as a post-suite leak gate
#
# WHY THIS EXISTS. Test suites leave debris for two reasons, and only one of them is a
# bug you can fix in the test:
#
#   1. The run was killed with SIGKILL. An EXIT trap never fires. Every phase-5 test HAS
#      a correct trap; ~17 empty projects and 3 instances accumulated anyway. No amount of
#      trap discipline fixes this — it needs a sweep.
#   2. The ENGINE refused to deliver a SIGNAL. AppArmor mediates signals at BOTH ends:
#      a container runs under `docker-default`, whose stock template has no rule
#      admitting a *confined* sender. So a dockerd that is itself confined — snap
#      docker runs as `snap.docker.dockerd` — cannot kill its own containers:
#
#        apparmor="DENIED" operation="signal" class="signal" profile="docker-default"
#          requested_mask="receive" signal=kill peer="snap.docker.dockerd"
#
#      Confirm anywhere with: journalctl -k | grep 'class="signal"'. RESOLVED on this
#      host by moving to the unconfined deb docker-ce daemon (an unconfined sender is
#      not mediated); phase 3 went 12 passed/4 skipped -> 15 passed/1 skipped, and the
#      per-run probe leak stopped. Kept here because the condition recurs on any host
#      running a confined dockerd.
#
# USE THE VERB THE OBJECT'S STATE CALLS FOR. `docker rm -f` KILLS FIRST, unconditionally
# — so on an already-EXITED container it fails on a kill that did not need to happen,
# while plain `docker rm` succeeds instantly.
#
# THREE THEORIES, TWO WRONG, each killed by a measurement rather than an argument:
#   "the daemon degrades under churn; restart it"  -> restart, identical denial. Worse:
#       `systemctl restart docker` starts the *deb* service, so it was never a no-op.
#   "two daemons fight over the `docker-default` name" -> deb stopped, snap restarted,
#       denial byte-identical.
#   "the SENDER is confined and the profile admits no confined peer" -> unconfined deb
#       dockerd, `docker kill` rc=0, zero denials. Also isolated to AppArmor and not
#       seccomp: `seccomp=unconfined` still denied, `apparmor=unconfined` worked.
#
# The check that produced the first two tested `rm -f` on a RUNNING container and
# generalised to "reaping is broken" — asserting a mechanism (can it kill?) in place of
# the outcome that mattered (can this specific object be removed?). So there is no global
# precondition gate here any more. Each object is removed with the verb its state calls
# for, and a failure reports the engine's own words.
#
# SAFETY. Dry run by default. It removes ONLY objects matching this repo's own test-debris
# name patterns, and carries an explicit KEEP list of things that look like debris and are
# not. It never calls `rm`, never prunes by "unused" (that would destroy multi-hour lab
# build images), and never kills by pattern.
set -uo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export REPO

# Debris name patterns — how this repo's own tests name throwaway objects.
#   phase5: test-profiles-projects.sh -> project ppp$$ ; test-vm-lifecycle.sh -> lab vlc$$
#   phase3: preflight probes probe-<tag>-preflight-$$ ; ad-hoc lab-xp$$-statusprobe
readonly PAT_PROJECT='^ppp[0-9]+$'
readonly PAT_INSTANCE='^lab-(ppp|vlc|xp|ttd)[0-9]+-'
readonly PAT_DOCKER_C='^(probe-(topo|rad|inspect)-preflight-[0-9]+|lab-xp[0-9]+-statusprobe|cleanup-probe-PLACEHOLDER-[0-9]+)$'
readonly PAT_DOCKER_N='^lab-[a-z]+[0-9]+-'
readonly PAT_PROFILE='^prof-[0-9]+$'

found_n=0 removed_n=0
declare -a PLAN=() FAILED=()

plan() { PLAN+=("$1"); found_n=$((found_n+1)); }

run() {   # run <description> <cmd...>
    local desc="$1"; shift
    if [[ "$APPLY" -eq 0 ]]; then printf '  would: %s\n' "$desc"; return 0; fi
    local err rc
    # Capture stderr. A sweep that prints "(command failed)" tells you a thing did not
    # happen and not one word about why -- the same defect this repo's test rule forbids
    # ("a failure must name the specific defect, not just say failed"). Real instance:
    # two `incus project delete` calls failed and the reason -- "Only empty projects can
    # be removed", because each still held a cached image -- was thrown away.
    err="$("$@" 2>&1 >/dev/null)"; rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf '  ✓ %s\n' "$desc"; removed_n=$((removed_n+1))
    else
        printf '  ✗ %s\n      rc=%d: %s\n' "$desc" "$rc" "${err:-<no stderr>}"
        FAILED+=("$desc :: ${err:-rc=$rc}")
    fi
}

hr() { printf '%s\n' "──────────────────────────────────────────────────────────────────────────────"; }

# ══ 1. LXD / Incus — instances, then projects, then the inherited profile ══
for engine in lxc incus; do
    command -v "$engine" >/dev/null 2>&1 || continue
    timeout 60 "$engine" info >/dev/null 2>&1 || continue

    while IFS=$'\t' read -r iname iproj; do
        [[ -z "$iname" ]] && continue
        [[ "$iname" =~ $PAT_INSTANCE ]] || continue
        plan "$engine delete -f $iname --project $iproj"
        run "$engine: instance $iname (project $iproj)" \
            "$engine" delete -f "$iname" --project "$iproj"
    done < <(timeout 60 "$engine" list --all-projects --format json 2>/dev/null \
             | python3 -c "
import json,sys
try:
    for i in json.load(sys.stdin): print(i['name']+'\t'+i.get('project','default'))
except Exception: pass" 2>/dev/null)

    while read -r pname; do
        [[ -z "$pname" ]] && continue
        [[ "$pname" =~ $PAT_PROJECT ]] || continue

        # A project that still holds ANYTHING refuses to delete ("Only empty projects can
        # be removed"). Launching an instance caches the image INTO the project, and that
        # copy outlives the instance -- so emptying the instances is not emptying the
        # project. Safe: the same fingerprint is retained in `default`, which is never
        # swept, so this drops a duplicate rather than the image.
        while read -r fp; do
            [[ -z "$fp" ]] && continue
            plan "$engine image delete $fp --project $pname"
            run "$engine: image ${fp:0:12} (project $pname)" \
                "$engine" image delete "$fp" --project "$pname"
        done < <(timeout 60 "$engine" image list --project "$pname" --format csv 2>/dev/null | cut -d, -f2)

        plan "$engine project delete $pname"
        run "$engine: project $pname" "$engine" project delete "$pname"
    done < <(timeout 60 "$engine" project list --format csv 2>/dev/null | cut -d, -f1)

    # Profiles created by test-profiles-projects.sh live in the DEFAULT project; the
    # ppp* projects only INHERIT them (features.profiles=false). Delete once, from default.
    while read -r prname; do
        [[ -z "$prname" ]] && continue
        [[ "$prname" =~ $PAT_PROFILE ]] || continue
        plan "$engine profile delete $prname (project default)"
        run "$engine: profile $prname" "$engine" profile delete "$prname" --project default
    done < <(timeout 60 "$engine" profile list --project default --format csv 2>/dev/null | cut -d, -f1)
done

# ══ 2. Docker ══
if command -v docker >/dev/null 2>&1 && timeout 60 docker info >/dev/null 2>&1; then
    # State-aware: `rm -f` kills first, so it FAILS on an exited container wherever
    # signal delivery is blocked — a kill that never needed to happen. Plain `rm` is
    # both correct and sufficient for anything not running.
    while IFS=$'\t' read -r cname cstate; do
        [[ -z "$cname" ]] && continue
        [[ "$cname" =~ $PAT_DOCKER_C ]] || continue
        if [[ "$cstate" == running || "$cstate" == restarting || "$cstate" == paused ]]; then
            plan "docker stop + rm $cname (state=$cstate)"
            if [[ "$APPLY" -eq 1 ]]; then timeout 60 docker stop -t 5 "$cname" >/dev/null 2>&1 || true; fi
            run "docker: container $cname (was $cstate)" docker rm -f "$cname"
        else
            plan "docker rm $cname (state=$cstate)"
            run "docker: container $cname ($cstate)" docker rm "$cname"
        fi
    done < <(timeout 60 docker ps -a --format '{{.Names}}\t{{.State}}' 2>/dev/null)

    while read -r net; do
        [[ -z "$net" ]] && continue
        [[ "$net" =~ $PAT_DOCKER_N ]] || continue
        plan "docker network rm $net"
        run "docker: network $net" docker network rm "$net"
    done < <(timeout 60 docker network ls --format '{{.Name}}' 2>/dev/null)
fi

# ══ 3. Podman — stopped lab containers only (rootless; reaps fine) ══
if command -v podman >/dev/null 2>&1; then
    while IFS=$'\t' read -r name status; do
        [[ -z "$name" ]] && continue
        [[ "$status" == Exited* ]] || continue
        plan "podman rm $name"
        run "podman: container $name (${status})" podman rm "$name"
    done < <(podman ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null)
fi

# ══ report ══
hr
printf 'KEPT ON PURPOSE — these look like debris and are not:\n'
cat <<'KEEP'
  libvirt alpine-node / node1 / node2 / node3   the metal-as-a-service + bmc-toolkit
                                                fleet; documented lab fixtures
  incusbr0                                      carries Calico's VXLAN tunnel endpoint
                                                for the live microk8s (Appendix D)
  podman images ofw-build, openbios-habitat-    multi-hour lab build boxes. `podman image
    build, micro-linux-builder, nix-build-box     prune -a` calls these 98% reclaimable
  ~/.local/state/lab-create/{micro-cloud-p2,    slice-1 inputs and the cloud-image cache
    trees}, ~/.cache/lab-create/images
  docker buildx_buildkit_lab-builder0           the reusable multi-arch builder
KEEP
hr

if [[ "$APPLY" -eq 0 ]]; then
    printf 'DRY RUN: %d object(s) would be swept. Re-run with --apply.\n' "$found_n"
    [[ "$found_n"   -gt 0 ]] && exit 2
    printf 'PASS: no test debris found\n'; exit 0
fi

printf 'SWEPT: %d removed, %d failed (of %d found)\n' \
    "$removed_n" "${#FAILED[@]}" "$found_n"
if [[ "${#FAILED[@]}" -gt 0 ]]; then
    printf 'FAILED, with the reason each engine gave:\n'
    for f in "${FAILED[@]}"; do printf '  ✗ %s\n' "$f"; done
fi
[[ "${#FAILED[@]}" -gt 0 ]] && {
    printf 'FAIL: %d object(s) could not be removed — the engine'"'"'s reason is printed above\n' \
        "${#FAILED[@]}"; exit 1; }
printf 'PASS: sweep complete\n'
exit 0
