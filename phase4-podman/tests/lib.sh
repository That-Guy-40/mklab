#!/usr/bin/env bash
# Shared helpers for phase4-podman tests.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_PODMAN="${TEST_DIR}/../lab-podman.sh"

skip()  { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note()  { printf '  - %s\n' "$*" >&2; }

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

cleanup_container() {
    local cname="$1"
    podman rm -f "$cname" >/dev/null 2>&1 || true
}
