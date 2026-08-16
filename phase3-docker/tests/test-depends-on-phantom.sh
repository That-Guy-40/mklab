#!/usr/bin/env bash
# Regression (REVIEW-phase3.md P3-4): the depends_on "soft-check" was fatal.
#
# `_topo_visit` warned that a dependency was not in the topology — explicitly
# anticipating a legitimate reason ("may be a cross-engine service") — and then
# recursed into it anyway.  The phantom landed in _TOPO_SORTED, and because it is a
# DEPENDENCY it sorts FIRST, so `up` reached it before any real service and died with
# "service 'cache': specify one of image | from_tarball | from_chroot | build" —
# naming a service the user never wrote, with the whole lab dead.
#
# The warning promised a tolerance the code did not implement.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_toml_parser

# The sort is pure, so the ordering assertions need no daemon: source the driver and
# drive topo_sort directly.  The `up` assertion below is the outcome, and it is gated
# on docker separately so the pure half still runs on a host without one.
export LAB_LOG_LEVEL=error
. "$LAB_DOCKER" 2>/dev/null || true

svcs='[{"name":"web","depends_on":["cache"]},{"name":"db"}]'
topo_sort "$svcs"
sorted="${_TOPO_SORTED[*]}"

for s in "${_TOPO_SORTED[@]}"; do
    [[ "$s" == "cache" ]] \
        && fail "REGRESSION: the phantom dependency 'cache' was queued for startup; sorted order was: $sorted"
done
(( ${#_TOPO_SORTED[@]} == 2 )) \
    || fail "REGRESSION: expected exactly the 2 declared services in the sort, got ${#_TOPO_SORTED[@]}: $sorted"
note "an unknown depends_on target is not queued as a service to start"

# Control: a DECLARED dependency must still order before its dependent — the fix must
# skip only the names that do not exist, not stop sorting.
topo_sort '[{"name":"web","depends_on":["db"]},{"name":"db"}]'
[[ "${_TOPO_SORTED[0]}" == "db" && "${_TOPO_SORTED[1]}" == "web" ]] \
    || fail "control: a real dependency must still sort first; got: ${_TOPO_SORTED[*]}"
note "control: a declared dependency still sorts before its dependent"

# Control: a genuine cycle must still be detected (the skip must not swallow it).
if ( topo_sort '[{"name":"a","depends_on":["b"]},{"name":"b","depends_on":["a"]}]' ) 2>/dev/null; then
    fail "control: a depends_on cycle must still be refused"
fi
note "control: a depends_on cycle is still detected"

# ── the outcome: `up` starts the real service instead of dying on the phantom ──────
require_docker

lab="dep$$"
cfg="$(mktemp --suffix=.toml)"
on_exit 'rm -f "$cfg"; cleanup_lab "$lab"'

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[[service]]
name       = "web"
image      = "alpine:latest"
command    = "sleep 300"
depends_on = ["cache"]
EOF

# The sourcing above set LAB_LOG_LEVEL=error to keep the pure half quiet; the warning
# under test is a warn-level line, so restore the default before invoking the driver.
unset LAB_LOG_LEVEL
out="$("$LAB_DOCKER" up --config "$cfg" 2>&1)" && rc=0 || rc=$?
(( rc == 0 )) \
    || fail "REGRESSION: 'up' failed (rc=$rc) because of a depends_on target that is not in the topology; output: $out"
grep -q "not in this topology" <<<"$out" \
    || fail "the warning about the unknown dependency was not printed; got: $out"
grep -q "specify one of image" <<<"$out" \
    && fail "REGRESSION: 'up' tried to start the phantom dependency as a service; got: $out"
await_line 15 "lab-${lab}-web" -- docker ps --format '{{.Names}}' \
    || fail "REGRESSION: the real service 'web' never started; the phantom dependency killed the lab"
note "'up' warns about the unknown dependency and starts the real service anyway"

pass "an unknown depends_on target is warned about, not started (P3-4)"
