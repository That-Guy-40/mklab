#!/usr/bin/env bash
# Unit test: `list --json` emits a schema_version=1 array of the script-managed
# chroots, derived from their manifests, honoring --lab.  No root, no network —
# uses a throwaway LAB_STATE_DIR with hand-written manifests.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

export LAB_STATE_DIR; LAB_STATE_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$LAB_STATE_DIR'" EXIT
mkdir -p "$LAB_STATE_DIR/chroots"

cat > "$LAB_STATE_DIR/chroots/alpha.toml" <<'EOF'
name       = "alpha"
target     = "/srv/alpha"
backend    = "debootstrap"
distro     = "debian"
suite      = "bookworm"
arch       = "x86_64"
manager    = "none"
lab        = "demo"
created_at = "2026-01-01T00:00:00Z"
rootless   = "true"
EOF
cat > "$LAB_STATE_DIR/chroots/beta.toml" <<'EOF'
name    = "beta"
target  = "/srv/beta"
backend = "dnf"
distro  = "rocky"
suite   = "9"
arch    = "x86_64"
manager = "nspawn"
lab     = ""
EOF

out="$("$LAB_CHROOT" list --json)"
jq -e . >/dev/null 2>&1 <<<"$out"                       || fail "not valid JSON: $out"
[[ "$(jq -r '.schema_version'  <<<"$out")" == "1" ]]    || fail "schema_version != 1"
[[ "$(jq -r '.chroots|length'  <<<"$out")" == "2" ]]    || fail "expected 2 chroots, got: $out"
[[ "$(jq -r '.chroots[]|select(.name=="alpha").backend' <<<"$out")" == "debootstrap" ]] || fail "alpha.backend wrong"
[[ "$(jq -r '.chroots[]|select(.name=="alpha").rootless' <<<"$out")" == "true"  ]] || fail "alpha.rootless should be true"
[[ "$(jq -r '.chroots[]|select(.name=="beta").rootless'  <<<"$out")" == "false" ]] || fail "beta.rootless should default false"
note "two chroots, schema_version=1, rootless bool correct"

# --lab filters in JSON mode
out="$("$LAB_CHROOT" list --json --lab demo)"
[[ "$(jq -r '.chroots|length' <<<"$out")" == "1" ]]      || fail "--lab demo should yield 1"
[[ "$(jq -r '.chroots[0].name' <<<"$out")" == "alpha" ]] || fail "--lab demo should be alpha"
note "--lab filter honored in JSON mode"

# empty state → valid JSON with an empty array
empty="$(mktemp -d)"
LAB_STATE_DIR="$empty" "$LAB_CHROOT" list --json | jq -e '.chroots == []' >/dev/null \
    || fail "empty state should give chroots: []"
rm -rf "$empty"
note "empty state → chroots: []"

pass "list --json OK"
