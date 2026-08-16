#!/usr/bin/env bash
# Regression (REVIEW-phase3.md §3), two guards that existed in the codebase and were
# absent from one of their call sites — the recurring shape across all six reviews.
#
#  1. `run --arch <unknown>` exited 1 with NO MESSAGE, where `build` named the problem.
#     `cmd_build` called is_known_arch; `cmd_run` did not, and reached
#     `args+=(--platform "$(docker_platform "$OPT_ARCH")")`.  docker_platform returns 1
#     for an unknown arch, the failed command substitution makes the array assignment
#     non-zero, and as the LAST command of an `&&` list under `set -e` that kills the
#     script before any diagnostic can print.  A bare rc=1 with a blank terminal.
#
#  2. The sensitive-mount advisory matched ONE OF TWO NAMES FOR THE SAME FILE.  On any
#     systemd host /var/run is a symlink to /run, so the canonical /run/docker.sock is
#     the same device and inode and got no warning — the advisory was silent for the
#     spelling most hosts use.  It asked "is this string /var/run/docker.sock?" when
#     the question is "is this the daemon socket?".  `/` had the same shape: `//`,
#     `/.`, and any symlink to `/` all evaded it.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ── 1. arch validation — no daemon needed, the gate is at the parser ───────────────
# Every verb that takes --arch must refuse an unknown one the same way, and must SAY SO.
for verb in "run --name a1 --image busybox" "build --tag x" "push --tag x"; do
    # shellcheck disable=SC2086
    out="$("$LAB_DOCKER" $verb --arch bogus-arch 2>&1)" && rc=0 || rc=$?
    (( rc != 0 )) || fail "'$verb --arch bogus-arch' exited 0; an unknown arch must be refused"
    grep -qi 'unknown arch' <<<"$out" \
        || fail "REGRESSION: '$verb --arch bogus-arch' failed with no diagnostic — rc=$rc, output was: [$out]"
    [[ -n "${out//[[:space:]]/}" ]] \
        || fail "REGRESSION: '$verb --arch bogus-arch' printed nothing at all (the silent-exit bug)"
done
note "every verb taking --arch refuses an unknown one WITH a message"

# Control: a known arch must pass the gate — the check must not refuse everything.
# (`run` then fails later for a different, named reason, which is the point.)
out="$("$LAB_DOCKER" run --arch aarch64 --name "" --image busybox 2>&1)" && rc=0 || rc=$?
grep -qi 'unknown arch' <<<"$out" \
    && fail "control: a KNOWN arch (aarch64) was rejected as unknown; output: $out"
note "control: a known arch passes the gate"

# ── 2. sensitive-mount advisory — unit-tested against the real helper ─────────────
export LAB_LOG_LEVEL=warn
. "$LAB_DOCKER" 2>/dev/null || true

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'

warns() {  # warns SOURCE — the advisory text for one volume source, if any
    _warn_sensitive_mount "$1" "" 2>&1
}

# The `/` spellings.  `//`, `/.` and a symlink to `/` are the same directory.
ln -s / "$tmp/rootlink"
for spelling in "/" "//" "/." "/../" "$tmp/rootlink"; do
    grep -qi 'entire host filesystem' <<<"$(warns "$spelling")" \
        || fail "REGRESSION: a volume source of '$spelling' resolves to '/' but produced no warning"
done
note "all 5 spellings of '/' are recognised as the host root"

# The docker.sock spellings.  The inode-identity half needs a socket to exist.
grep -qi 'docker.sock' <<<"$(warns /var/run/docker.sock)" \
    || fail "the original /var/run/docker.sock spelling stopped warning"
grep -qi 'docker.sock' <<<"$(warns /run/docker.sock)" \
    || fail "REGRESSION: /run/docker.sock — the canonical spelling on any systemd host — produced no warning"
grep -qi 'docker.sock' <<<"$(warns "$HOME/.docker/run/docker.sock")" \
    || fail "a rootless docker.sock path produced no warning (it is just as much daemon access)"
note "docker.sock is recognised by name in all 3 spellings"

if [[ -S /run/docker.sock || -S /var/run/docker.sock ]]; then
    real="/run/docker.sock"; [[ -S "$real" ]] || real="/var/run/docker.sock"
    # Same inode, a name that does not end in docker.sock: only the resolve-and-compare
    # half can catch this one.
    ln -s "$real" "$tmp/aliased.socket"
    grep -qi 'docker.sock' <<<"$(warns "$tmp/aliased.socket")" \
        || fail "REGRESSION: a symlink to the daemon socket under another name produced no warning"
    note "...and by inode, for a path that does not carry the name"
else
    note "UNKNOWN: no docker socket on this host — the inode-identity half was NOT exercised"
fi

# Controls: the advisory must not fire on ordinary mounts, or it becomes noise a
# reader learns to skip past.
for benign in "/tmp" "$tmp" "webdata" "./relative" "/var/run/docker.sock.bak" "/home"; do
    w="$(warns "$benign")"
    [[ -z "$w" ]] || fail "control: an ordinary volume source '$benign' produced a warning: $w"
done
note "control: 6 ordinary volume sources produce no warning"

pass "arch is validated once at the parser; the mount advisory asks about the file, not the string (§3)"
