#!/usr/bin/env bash
# Shared helpers for phase4-podman tests.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_PODMAN="${TEST_DIR}/../lab-podman.sh"

# _VERDICT guards the EXIT net below: a test that already printed FAIL must not also
# be told "no verdict was printed", or the net becomes noise a reader skips past.
_VERDICT=0
skip()  { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note()  { printf '  - %s\n' "$*" >&2; }

# ── the ONE EXIT trap, and the only place cleanup belongs ────────────────────────────
#
# Belt-and-suspenders (CLAUDE.md): if a test dies early — `set -e` tripping, or a `die`
# inside lab-podman.sh slipping past the assertions — this prints a FAIL verdict, so the
# terminal is never left blank with a bare non-zero rc.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap … EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing its own silently REPLACES this net — measured across the
# repo on 2026-08-06, when 11 of 13 of these tests had no net at all. Register instead:
#
#     on_exit 'rm -rf "$tmp"'     # evaluated at exit, so it may name a later variable
#
# `tests/test-harness-net.sh` proves the net fires and refuses a test that installs an
# EXIT trap of its own.
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
    # Registered cleanup can READ the exit status as $_EXIT_RC. Without it a teardown
    # that needs to know whether the run failed — keep the evidence, skip the tidy-up —
    # has to write its own `trap … EXIT`, which is the defect this block exists to stop.
    _EXIT_RC=$rc
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT


require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

require_podman() {
    require_cmd podman
    local v
    v="$(podman version --format '{{.Client.Version}}' 2>/dev/null | awk -F. '{printf "%d.%d", $1, $2}')"
    [[ -n "$v" ]] || skip "couldn't determine podman version"
    # Require 4.0+
    local maj min
    maj="${v%.*}"; min="${v#*.}"
    if (( maj < 4 )); then
        skip "podman $v too old (need >= 4.0)"
    fi
}

require_podman_quadlet() {
    require_podman
    local v maj min
    v="$(podman version --format '{{.Client.Version}}' | awk -F. '{printf "%d.%d", $1, $2}')"
    maj="${v%.*}"; min="${v#*.}"
    (( maj > 4 )) || (( maj == 4 && min >= 4 )) \
        || skip "podman $v too old for quadlet (need >= 4.4)"
}

# require_oci_runtime [image] — can podman's OCI runtime actually START a container here?
#
# FOUND 2026-07-29 on GitHub's hosted runners: three tests in this suite went red on
# `main` with
#
#     time="..." level=error msg="\"crun: unknown version specified: OCI runtime error\""
#     Error: starting some containers: internal libpod error
#
# That is crun REJECTING THE OCI SPEC VERSION in the config podman generated for it — a
# podman/crun mismatch in the runner image, not anything in this repo. Established rather
# than assumed: re-running a commit that had passed an hour earlier failed identically,
# so the machine changed and the repository did not.
#
# WHY THIS PROBES WITH RAW `podman` AND NEVER `lab-podman.sh`. The point is to separate
# "this host cannot run containers" from "this lab is broken". If plain `podman run true`
# cannot start a container, nothing in this repo could either, and a FAIL would blame the
# lab for the machine. Because the probe touches none of the code under test, it cannot
# mask a regression in it — a bug in lab-podman.sh still fails, loudly, as it should.
#
# A red suite that means "the runner is broken" is indistinguishable from one that means
# "the lab is broken", and a repo where red is normal stops carrying signal. So: say which.
require_oci_runtime() {
    local img="${1:-docker.io/library/alpine:latest}" out rc runtime
    out="$(podman run --rm --pull=missing "$img" true 2>&1)"; rc=$?
    (( rc == 0 )) && return 0
    runtime="$(podman info --format '{{.Host.OCIRuntime.Name}}' 2>/dev/null)"
    if grep -qiE 'OCI runtime|unknown version specified|internal libpod error|\bcrun\b|\brunc\b' <<<"$out"; then
        skip "${runtime:-the OCI runtime} cannot start a container on this host — the environment, not this lab: ${out//$'\n'/ }"
    fi
    skip "podman cannot start a container here (rc=$rc), so nothing this lab does could either: ${out//$'\n'/ }"
}

require_rootless_ready() {
    [[ $EUID -eq 0 ]] && skip "test wants non-root (rootless podman); running as root"
    local user; user="$(id -un)"
    [[ -r /etc/subuid ]] && grep -q "^${user}:" /etc/subuid \
        || skip "no subuid entry for $user; run 'sudo usermod --add-subuids 100000-165535 $user'"
    [[ -r /etc/subgid ]] && grep -q "^${user}:" /etc/subgid \
        || skip "no subgid entry for $user"
}

# expect_error LABEL PATTERN -- ARGS...
expect_error() {
    local label="$1" pattern="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local out rc
    out="$("$LAB_PODMAN" "$@" 2>&1)" && rc=0 || rc=$?
    if (( rc == 0 )); then
        fail "$label — expected non-zero exit, got 0; output: $out"
    fi
    if ! grep -qi -- "$pattern" <<<"$out"; then
        fail "$label — error did not match /$pattern/i; got: $out"
    fi
    note "$label OK"
}

cleanup_lab() {
    local lab="$1"
    "$LAB_PODMAN" down --lab "$lab" >/dev/null 2>&1 || true
}

# ── preconditions, asked as CAPABILITIES rather than as banners ─────────────────────────
#
# These used to be `yq --version | grep -qi mikefarah`, which asks who wrote the tool
# when the question is whether it can do the job.  yq 4.2.0 prints "yq version 4.2.0"
# with no vendor name and was rejected as "not mikefarah" — right here by accident,
# since 4.2.0 also lacks `-p`, but the check could not tell those two facts apart.
# They were also STRICTER than the driver, which now accepts python3's tomllib/PyYAML:
# a test that skips while the driver would have worked reports UNKNOWN for no reason.
require_toml_parser() {
    command -v tomlq >/dev/null 2>&1 && return 0
    command -v dasel >/dev/null 2>&1 && return 0
    if command -v yq >/dev/null 2>&1 && printf 'a = 1\n' | yq -p toml -o json - >/dev/null 2>&1; then
        return 0
    fi
    python3 -c 'import tomllib' >/dev/null 2>&1 && return 0
    skip "no TOML parser (need tomlq, dasel, a yq supporting -p toml, or python3 >= 3.11)"
}

require_yaml_reader() {
    if command -v yq >/dev/null 2>&1 && printf 'a: 1\n' | yq -p yaml -o json - >/dev/null 2>&1; then
        return 0
    fi
    python3 -c 'import yaml' >/dev/null 2>&1 && return 0
    skip "no YAML reader (need a yq supporting -p yaml, or python3 + PyYAML)"
}

# ── reading an emitted artifact by VALUE, not by the text that encodes it ───────────────
#
# `grep -q 'interval: 30s'` asserts a RENDERING, so it fails the moment the emitter
# starts quoting its scalars — which it now must, because an unquoted `command: true`
# is a YAML boolean and an unquoted newline is an injected sibling key (P3-2).  Nothing
# was broken when those greps went red; the assertion was simply naming the mechanism.
#
# So: parse the artifact and assert on the value.  Returns non-zero when the host has no
# YAML reader at all, which callers should turn into a SKIP — an unmet precondition is an
# UNKNOWN, not a pass.  `safe_load`, never `load`: the full loader builds arbitrary Python
# objects from `!!python/object` tags.
yaml_json() {  # yaml_json FILE  → JSON on stdout
    if python3 -c 'import yaml' >/dev/null 2>&1; then
        python3 -c '
import json, sys, yaml
with open(sys.argv[1]) as fh:
    json.dump(yaml.safe_load(fh), sys.stdout)
' "$1"
    elif command -v yq >/dev/null 2>&1 && printf 'a: 1\n' | yq -p yaml -o json - >/dev/null 2>&1; then
        yq -p yaml -o json "$1"
    else
        return 1
    fi
}

cleanup_container() {
    local cname="$1"
    podman rm -f "$cname" >/dev/null 2>&1 || true
}

# ── awaiting an EVENTUAL state, without the two traps that shape has ────────────────────
# `producer | grep -q PATTERN || fail` is wrong here in two independent ways, and CI on
# main has now gone red twice from it (2026-08-07: a container's logs, and a pod's members).
#
#   1. THE STATE IS EVENTUAL.  A tool returning is not the container having done the thing:
#      `run --detach` returns once the container is CREATED, so its first line of output may
#      not exist yet, and `up` returning is not every service `running`.  An instant assert
#      is a race that passes on an idle laptop and fails on a loaded runner.
#   2. `grep -q` EXITS ON FIRST MATCH and closes the pipe.  The producer can then die on
#      SIGPIPE, and with `pipefail` set (this lib does) the PIPELINE reports failure — so a
#      match that WAS found is reported as absent.  This repo has documented that inversion
#      three times (fabric.sh's `ip … | grep -q inet`, plan §6's `mke2fs -h`); these were the
#      fourth and fifth instances.
#
# Both vanish if you CAPTURE FIRST AND TEST SECOND, with a deadline.  No pipe, so no
# SIGPIPE and no pipefail inversion; a retry loop, so eventual state is allowed to arrive.
# On timeout the captured output is echoed, because "not found" is far more debuggable with
# the haystack than without it.
#
#   await_line  <secs> <exact-line> -- <cmd…>     # whole-line match (was `grep -qx`)
#   await_match <secs> <substring>  -- <cmd…>     # substring match  (was `grep -q`)
#
# NOT for negative assertions.  A "must NOT appear" check must not retry — it would simply
# wait out the deadline every time and turn a fast test slow while proving the same thing.
_await() {   # _await <mode: line|match> <secs> <needle> -- <cmd…>
    local mode="$1" secs="$2" needle="$3"; shift 3
    [[ "${1:-}" == -- ]] && shift
    local deadline=$(( SECONDS + secs )) out
    while :; do
        out="$("$@" 2>/dev/null)" || true
        if [[ "$mode" == line ]]; then
            grep -qxF -- "$needle" <<<"$out" && return 0
        else
            grep -qF -- "$needle" <<<"$out" && return 0
        fi
        (( SECONDS >= deadline )) && { printf '%s' "$out"; return 1; }
        sleep 0.3
    done
}
await_line()  { _await line  "$@"; }
await_match() { _await match "$@"; }

# ── the same shape, in its other three polarities ──────────────────────────────────────
#
# await_line/await_match above handle EVENTUAL PRESENCE. Two more cases exist and each is
# wrong in its own way when written as `producer | grep -q … || fail`:
#
# `await_absent` — EVENTUAL ABSENCE ("gone after destroy/down"). These were written
# `producer | grep -qx NAME && fail "still present"`, and the SIGPIPE inversion there fails
# in the DANGEROUS direction: if grep matches (the container IS still there, i.e. the test
# should fail) and the producer then dies on SIGPIPE, `pipefail` makes the pipeline non-zero,
# `&& fail` does NOT fire, and the test PASSES with the container still present. A missed
# failure, not a spurious one. They are also genuinely eventual — `destroy` returning is not
# the container being reaped — so they retry until it is gone rather than sampling once.
#
# NOTE the distinction, because it corrects a too-broad rule: "a negative assertion must not
# retry" is true of an INVARIANT ("this must never appear"), which would just wait out the
# deadline every time. It is false of eventual absence, which is what all three of these are.
#
# `has_line` / `has_match` — IMMEDIATE state (inspect output, a completed build, a synchronous
# command's own stdout). Nothing to wait for, so retrying would only add latency — but the
# SIGPIPE inversion is still live, so they capture first and test second.
await_absent() {  # await_absent <secs> <exact-line> -- <cmd…>
    local secs="$1" needle="$2"; shift 2
    [[ "${1:-}" == -- ]] && shift
    local deadline=$(( SECONDS + secs )) out
    while :; do
        out="$("$@" 2>/dev/null)" || true
        grep -qxF -- "$needle" <<<"$out" || return 0
        (( SECONDS >= deadline )) && { printf '%s' "$out"; return 1; }
        sleep 0.3
    done
}
has_line()  { local needle="$1"; shift; [[ "${1:-}" == -- ]] && shift
              local out; out="$("$@" 2>/dev/null)" || true; grep -qxF -- "$needle" <<<"$out"; }
has_match() { local needle="$1"; shift; [[ "${1:-}" == -- ]] && shift
              local out; out="$("$@" 2>/dev/null)" || true; grep -qF -- "$needle" <<<"$out"; }
