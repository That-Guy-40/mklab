#!/usr/bin/env bash
# Regression (REVIEW-phase5.md P5-2, applied 2026-08-16): Phase 5's `_yaml_str`
# escaped the double-quote but NOT the backslash, while the identical helper in
# Phases 3 and 4 had carried Review L1's ordering for months.
#
# The failure is ordering, not omission.  A value ending in `\` emitted `"…\"` — the
# backslash escaped the CLOSING quote, so the scalar ran on and swallowed the next
# line of the document.  And the two escapes must happen in this order: escaping the
# quote first, then the backslash, would double-escape the `\"` the first pass just
# wrote.
#
# Pure unit test — no LXD/incus instance is created, so this runs on any host.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

export LAB_LOG_LEVEL=error
. "$LAB_LXD" 2>/dev/null || true

eq() { [[ "$2" == "$3" ]] || fail "$1: got $2, want $3"; note "$1"; }

eq "plain value"            "$(_yaml_str 'plain')"        '"plain"'
eq "embedded double-quote"  "$(_yaml_str 'a"b')"          '"a\"b"'
eq "trailing backslash"     "$(_yaml_str 'a\')"           '"a\\"'
eq "embedded backslash"     "$(_yaml_str 'a\b')"          '"a\\b"'
eq "backslash then quote"   "$(_yaml_str 'a\"b')"         '"a\\\"b"'
eq "only a backslash"       "$(_yaml_str '\')"            '"\\"'

# The outcome, not the rendering: a YAML parser must read back exactly what went in,
# and the value must not leak into the next key.  Escaping that produces a
# syntactically valid document while corrupting the value is a different bug wearing
# the same green tick.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    note "UNKNOWN: no PyYAML — the round-trip half was NOT exercised (the unit assertions above did run)"
    pass "Phase 5 _yaml_str escapes backslash before double-quote (Review L1)"
fi

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
for v in 'a\' 'a"b' 'a\"b' '\' 'plain' 'ends with two \\'; do
    {   printf 'top:\n'
        printf '  key: %s\n' "$(_yaml_str "$v")"
        printf '  sentinel: "untouched"\n'
    } > "$tmp/doc.yaml"
    got="$(python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["top"]["sentinel"] == "untouched", "the sentinel key was swallowed by the previous scalar"
sys.stdout.write(d["top"]["key"])' "$tmp/doc.yaml" 2>&1)" \
        || fail "REGRESSION: the emitted document is malformed for value [$v]: $got"
    [[ "$got" == "$v" ]] \
        || fail "REGRESSION: value [$v] round-tripped as [$got] — the escape is lossy"
done
note "6 values round-trip through a real YAML parser with the following key intact"

pass "Phase 5 _yaml_str escapes backslash before double-quote, and values round-trip (Review L1)"
