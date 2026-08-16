#!/usr/bin/env bash
# Regression (REVIEW-phase4.md P4-2 and P4-3), two defects that compound each other.
#
# P4-2 — `cmd_up` validates lab, service AND pod names up front, and its comment states
# the reason exactly: they "become quadlet unit *paths*". `cmd_generate` did the same
# writes — `install -d "$(lab_dir "$lab")"`, `cp spec.toml`, `emit_*_unit` — and called
# `validate_name` ZERO times. A `../`-bearing lab name made it create a directory two
# levels ABOVE the state dir and copy the config into it, outside the tree `cmd_down`'s
# `rm -rf` prefix assertion exists to protect. `down` then refuses that lab name, so
# nothing the tool offers can clean it up.
#
# P4-3 — the quadlet emitters reported success on a FAILED write: rc=0, `[info] wrote
# <path>`, zero files on disk, and a dangling symlink recorded in `quadlet-links/` — the
# directory whose entire job is to record what `down` must reverse. A record with no
# subject, and a false success, which CLAUDE.md ranks above an honest failure.
#
# Everything here is redirected into a scratch tree; nothing touches the real
# ~/.config/containers/systemd.
#
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
if ! command -v tomlq >/dev/null 2>&1 && ! command -v dasel >/dev/null 2>&1 \
   && ! { command -v yq >/dev/null 2>&1 && printf 'a = 1\n' | yq -p toml -o json - >/dev/null 2>&1; }; then
    skip "no TOML parser (need tomlq, dasel, or a yq supporting -p toml)"
fi
command -v podman >/dev/null 2>&1 || skip "podman not installed (generate requires the quadlet check)"

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
export LAB_STATE_DIR="$tmp/state"
# QUADLET_USER_DIR is readonly in the driver and derived from XDG_CONFIG_HOME, so THIS
# is the redirect — and it matters: without it the test would write into (and, worse,
# occupy a path in) the operator's real ~/.config/containers/systemd.
export XDG_CONFIG_HOME="$tmp/xdg"
QUADLET_USER_DIR="$tmp/xdg/containers/systemd"
mkdir -p "$LAB_STATE_DIR" "$QUADLET_USER_DIR"
[[ "$QUADLET_USER_DIR" == "$tmp"/* ]] || fail "refusing to run: the quadlet dir is not inside the scratch tree"

# ── P4-2: a traversal in the lab name ──────────────────────────────────────────────
cat > "$tmp/trav.toml" <<'TOML'
[lab]
name = "../../ESCAPED"

[[service]]
name  = "web"
image = "alpine:latest"
TOML

# `up` already refuses this — the control that proves the rule is understood.
out="$("$LAB_PODMAN" up --config "$tmp/trav.toml" 2>&1)" && rc=0 || rc=$?
(( rc != 0 )) || fail "control: 'up' must refuse a traversal lab name; it did not"
grep -qi 'invalid lab name' <<<"$out" || fail "control: 'up' refused but not with the name error; got: $out"
note "control: 'up' refuses a '../' lab name (it always did)"

out="$("$LAB_PODMAN" generate --config "$tmp/trav.toml" 2>&1)" && rc=0 || rc=$?
(( rc != 0 )) \
    || fail "REGRESSION: 'generate' accepted a '../' lab name that 'up' refuses, and it performs the same writes; output: $out"
grep -qi 'invalid lab name' <<<"$out" \
    || fail "'generate' refused the traversal name but did not say why; got: $out"

# The outcome, not the message: nothing may be written outside the state dir.
escaped="$(find "$tmp" -name spec.toml -not -path "$LAB_STATE_DIR/*" 2>/dev/null | head -3)"
[[ -z "$escaped" ]] \
    || fail "REGRESSION: 'generate' wrote outside the state dir despite the refusal: $escaped"
[[ ! -e "$tmp/ESCAPED" ]] \
    || fail "REGRESSION: 'generate' created $tmp/ESCAPED — two levels above the state dir"
note "P4-2: 'generate' refuses the traversal name AND writes nothing outside the state dir"

# Service and pod names too — `up` validates all three, so `generate` must as well.
for field in service pod; do
    cat > "$tmp/bad-$field.toml" <<TOML
[lab]
name = "goodlab"

[[${field}]]
name = "../evil"
$( [[ "$field" == service ]] && printf 'image = "alpine:latest"' )
TOML
    out="$("$LAB_PODMAN" generate --config "$tmp/bad-$field.toml" 2>&1)" && rc=0 || rc=$?
    (( rc != 0 )) \
        || fail "REGRESSION: 'generate' accepted an invalid $field name; output: $out"
    grep -qi "invalid $field name" <<<"$out" \
        || fail "'generate' refused the bad $field name but did not name the field; got: $out"
done
note "P4-2: service and pod names are validated too, matching 'up'"

# ── P4-3: a write that fails must not report success ───────────────────────────────
# The failure is made name-independent by occupying the target path with a DIRECTORY,
# so this reproduces with entirely valid names and is independent of P4-2.
#
# NOTE the control that had to be discarded: making the quadlet dir read-only "proved"
# the write succeeded, because `install -d -m 0755` re-chmods it on every call (§3).
# A control that silently defeats itself is exactly what this repo's conventions exist
# to catch.
cat > "$tmp/ok.toml" <<'TOML'
[lab]
name = "goodname"

[[service]]
name  = "web"
image = "alpine:latest"
TOML

mkdir -p "$QUADLET_USER_DIR/lab-goodname-web.container"   # occupy the unit path
out="$("$LAB_PODMAN" generate --config "$tmp/ok.toml" 2>&1)" && rc=0 || rc=$?

(( rc != 0 )) \
    || fail "REGRESSION: 'generate' exited 0 while the unit file could not be written — a false success outranks an honest failure. Output: $out"
grep -q 'wrote .*lab-goodname-web.container' <<<"$out" \
    && fail "REGRESSION: 'generate' printed 'wrote <path>' for a path it did not write"

# ...and it must not record a unit that does not exist.
links="$LAB_STATE_DIR/podman/goodname/quadlet-links"
if [[ -d "$links" ]]; then
    for l in "$links"/*.container; do
        [[ -e "$l" ]] || continue          # glob with no match
        [[ -e "$(readlink -f "$l")" ]] \
            || fail "REGRESSION: a DANGLING symlink was recorded in quadlet-links/ for a unit that was never written — 'down' reverses that directory, so it now records a subject that does not exist"
    done
fi
note "P4-3: a failed unit write fails loudly and records nothing"

# Control: with the path free, the same config must succeed and record a REAL unit.
rmdir "$QUADLET_USER_DIR/lab-goodname-web.container"
out="$("$LAB_PODMAN" generate --config "$tmp/ok.toml" 2>&1)" && rc=0 || rc=$?
(( rc == 0 )) || fail "control: 'generate' must succeed when the path is writable; rc=$rc, output: $out"
[[ -f "$QUADLET_USER_DIR/lab-goodname-web.container" ]] \
    || fail "control: the unit file was not written on the success path"
[[ -L "$links/lab-goodname-web.container" && -e "$(readlink -f "$links/lab-goodname-web.container")" ]] \
    || fail "control: the success path did not record a resolvable tracked unit"
note "control: with the path free, the unit is written AND tracked"

pass "'generate' validates names like 'up', and a failed unit write is loud and untracked (P4-2, P4-3)"
