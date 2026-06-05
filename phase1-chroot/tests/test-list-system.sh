#!/usr/bin/env bash
# Unit test: `list --system` folds root's registry (LAB_SYSTEM_STATE_DIR) into an
# unprivileged list — read-only, deduped (active registry wins), with an OWNER
# column / "owner" JSON key.  Default output (no --system) is unchanged.
# No root, no network — two throwaway registries with hand-written manifests.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

# --system surfaces root's registry only when run UNPRIVILEGED (as root the
# active registry already IS root's, so the flag is a no-op).
[[ ${EUID:-$(id -u)} -ne 0 ]] || skip "list --system is a no-op as root"

USER_DIR="$(mktemp -d)"; SYS_DIR="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$USER_DIR' '$SYS_DIR'" EXIT
mkdir -p "$USER_DIR/chroots" "$SYS_DIR/chroots"

# Active (user) registry: one rootless chroot.
cat > "$USER_DIR/chroots/user-a.toml" <<'EOF'
name = "user-a"
target = "/home/u/user-a"
backend = "debootstrap"
distro = "debian"
arch = "x86_64"
manager = "none"
lab = ""
EOF
# System registry: a root chroot, plus a name that COLLIDES with the user one.
cat > "$SYS_DIR/chroots/sys-a.toml" <<'EOF'
name = "sys-a"
target = "/var/chroots/sys-a"
backend = "debootstrap"
distro = "debian"
arch = "x86_64"
manager = "none"
lab = ""
EOF
cat > "$SYS_DIR/chroots/user-a.toml" <<'EOF'
name = "user-a"
target = "/var/chroots/user-a"
backend = "debootstrap"
distro = "debian"
arch = "x86_64"
manager = "none"
lab = ""
EOF

export LAB_STATE_DIR="$USER_DIR" LAB_SYSTEM_STATE_DIR="$SYS_DIR"
me="$(id -un)"

# 1. --system --json: union of both registries, deduped, with owner labels.
out="$("$LAB_CHROOT" list --system --json)"
jq -e . >/dev/null 2>&1 <<<"$out"                        || fail "not valid JSON: $out"
[[ "$(jq -r '.chroots|length' <<<"$out")" == "2" ]]      || fail "expected 2 chroots (deduped), got: $out"
[[ "$(jq -r '.chroots[]|select(.name=="sys-a").owner'  <<<"$out")" == "root" ]] || fail "sys-a owner should be root"
[[ "$(jq -r '.chroots[]|select(.name=="user-a").owner' <<<"$out")" == "$me" ]] || fail "user-a owner should be $me"
# dedup: the ACTIVE (user) registry wins for the colliding name.
[[ "$(jq -r '.chroots[]|select(.name=="user-a").target' <<<"$out")" == "/home/u/user-a" ]] \
    || fail "user-a should resolve to the user registry (active wins), got: $out"
note "union + dedup (active wins) + owner labels in --system --json"

# 2. Default --json (no --system): only the active registry, NO owner key.
out="$("$LAB_CHROOT" list --json)"
[[ "$(jq -r '.chroots|length' <<<"$out")" == "1" ]]      || fail "default --json should show only the active registry"
[[ "$(jq -r '.chroots[0].name' <<<"$out")" == "user-a" ]] || fail "default --json should be user-a"
[[ "$(jq -r '.chroots[0]|has("owner")' <<<"$out")" == "false" ]] || fail "default --json must NOT carry an owner key"
note "default --json unchanged (single registry, no owner key)"

# 3. Human --system: OWNER column present, the root chroot shown.
out="$("$LAB_CHROOT" list --system)"
grep -q 'OWNER' <<<"$out"                                || fail "--system header should have an OWNER column"
grep -qE 'sys-a .* root .* /var/chroots/sys-a' <<<"$out" || fail "--system should list sys-a as owner root"
note "human --system shows OWNER column + root chroots"

# 4. Default human list: no OWNER column.
out="$("$LAB_CHROOT" list)"
grep -q 'OWNER' <<<"$out" && fail "default human list must NOT have an OWNER column"
note "default human list unchanged (no OWNER column)"

pass "list --system OK"
