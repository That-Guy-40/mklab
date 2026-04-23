#!/usr/bin/env bash
# Test the `inspect [--json]` verb against a hand-built fake chroot.
# No root, no network, no debootstrap — just a directory tree shaped
# the way inspect's probes expect.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

WORK="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT

# --- build a fake chroot tree ---
ROOT="$WORK/fake-chroot"
mkdir -p "$ROOT/etc" "$ROOT/var/lib/dpkg"
cat > "$ROOT/etc/os-release" <<'EOF'
NAME="Test Linux"
ID=testos
VERSION_ID="42"
VERSION_CODENAME=galaxy
PRETTY_NAME="Test Linux 42 (Galaxy)"
EOF
# 5 packages → grep -c '^Package: ' should yield 5
printf 'Package: alpha\n\nPackage: beta\n\nPackage: gamma\n\nPackage: delta\n\nPackage: epsilon\n\n' \
    > "$ROOT/var/lib/dpkg/status"

note "running inspect (human form)"
out="$("$LAB_CHROOT" inspect "$ROOT" 2>&1)"
case "$out" in
    *"[manifest]"*"[live]"*) ;;
    *) fail "human form missing [manifest] / [live] sections; got:\n$out" ;;
esac
case "$out" in
    *"name        fake-chroot"*) ;;
    *) fail "human form: synthesized name not found in output" ;;
esac
case "$out" in
    *"target.exists       true"*) ;;
    *) fail "human form: target.exists not surfaced" ;;
esac
case "$out" in
    *"os_release.pretty   Test Linux 42 (Galaxy)"*) ;;
    *) fail "human form: os_release.pretty not surfaced" ;;
esac
case "$out" in
    *"packages.count      5"*) ;;
    *) fail "human form: packages.count expected 5, got:\n$out" ;;
esac

note "running inspect --json"
json="$("$LAB_CHROOT" inspect "$ROOT" --json)"
# Validate it parses + has the expected schema_version.
echo "$json" | jq -e '.schema_version == 1' >/dev/null \
    || fail "json: schema_version != 1"

note "schema spot-checks"
[[ "$(jq -r '.name' <<<"$json")" == "fake-chroot" ]] \
    || fail "json: .name != fake-chroot"
[[ "$(jq -r '.target.exists' <<<"$json")" == "true" ]] \
    || fail "json: .target.exists != true"
[[ "$(jq -r '.target.size_bytes | type' <<<"$json")" == "number" ]] \
    || fail "json: .target.size_bytes is not a number"
[[ "$(jq -r '.os_release.pretty_name' <<<"$json")" == "Test Linux 42 (Galaxy)" ]] \
    || fail "json: .os_release.pretty_name mismatch"
[[ "$(jq -r '.packages.manager' <<<"$json")" == "dpkg" ]] \
    || fail "json: .packages.manager != dpkg"
[[ "$(jq -r '.packages.count' <<<"$json")" == "5" ]] \
    || fail "json: .packages.count != 5"
[[ "$(jq -r '.manager_state.kind' <<<"$json")" == "none" ]] \
    || fail "json: .manager_state.kind != none"
[[ "$(jq -r '.manager_state.registered' <<<"$json")" == "true" ]] \
    || fail "json: .manager_state.registered != true (bare chroot is its own registration)"

note "no-os-release variant"
ROOT2="$WORK/no-osr"
mkdir -p "$ROOT2"
out2="$("$LAB_CHROOT" inspect "$ROOT2" --json)"
[[ "$(jq -r '.os_release' <<<"$out2")" == "null" ]] \
    || fail "json: .os_release should be null when /etc/os-release is missing"
[[ "$(jq -r '.packages' <<<"$out2")" == "null" ]] \
    || fail "json: .packages should be null when no package db is present"

note "missing-target failure path"
if "$LAB_CHROOT" inspect /this/does/not/exist 2>/dev/null; then
    fail "inspect should fail on a non-existent path"
fi

note "usage error: no arg"
if "$LAB_CHROOT" inspect 2>/dev/null; then
    fail "inspect with no arg should fail"
fi

pass "inspect [--json] OK"
