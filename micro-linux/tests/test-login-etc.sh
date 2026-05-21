#!/usr/bin/env bash
# getty + login setup: stage_etc must emit a usable root account (a valid
# SHA-512 crypt hash that the lab password actually verifies against), a
# securetty covering the serial consoles, and an /etc/issue that advertises the
# credentials (discoverability).  Isolated via MLBUILD_OUT_DIR.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
need python3

out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
export MLBUILD_OUT_DIR="$out"
# shellcheck source=/dev/null
source "$MLBUILD"
set +e

etc="$(stage_etc)" || fail "stage_etc failed"
[ -d "$etc" ] || fail "stage_etc did not create a dir"

grep -q "^${LAB_USER}:x:0:0:" "$etc/passwd" || fail "passwd has no root account"
grep -q '^console$' "$etc/securetty" || fail "securetty missing 'console'"
grep -q '^ttyS0$'   "$etc/securetty" || fail "securetty missing 'ttyS0'"
grep -q '^ttyAMA0$' "$etc/securetty" || fail "securetty missing 'ttyAMA0'"
note "passwd + securetty cover root and the serial consoles"

shadow_hash="$(cut -d: -f2 "$etc/shadow")"
case "$shadow_hash" in
    '$6$'*) note "shadow holds a SHA-512 crypt() hash" ;;
    *)      fail "shadow hash is not SHA-512 crypt: $shadow_hash" ;;
esac

# The password must verify against the generated hash: crypt(pw, hash) == hash.
ok="$(python3 -W ignore -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], sys.argv[2]) == sys.argv[2])' \
        "$LAB_PASSWORD" "$shadow_hash")"
[ "$ok" = True ] || fail "LAB_PASSWORD does not verify against the generated shadow hash"
note "LAB_PASSWORD verifies against the shadow hash"

grep -q "$LAB_USER"     "$etc/issue" || fail "/etc/issue does not mention the login user"
grep -q "$LAB_PASSWORD" "$etc/issue" || fail "/etc/issue does not advertise the password"
note "/etc/issue advertises login + password (discoverable)"

pass "login /etc setup OK"
