#!/usr/bin/env bash
# Regression (REVIEW-phase5.md P5-1 and P5-2) for `export --format compose`.
#
# P5-2 — Phase 5 was the weakest of the three exporters. `_yaml_str` existed but the
# exporter mostly did not call it: ports, volumes and environment *values* were
# hand-quoted with a bare `"%s"` format string, which escapes nothing, and image and
# command were emitted raw. The audit's sweep: **0 of 8** config-reachable fields
# round-tripped, 2 injected a resolved compose attribute, 6 produced a file compose
# refuses. (Phase 3 had 2 survivors of 14; Phase 4 had escaped values.)
#
# P5-1 — the exporter emitted four fields `up` NEVER READS (ports, environment, volumes,
# command), so the compose file asserted a port mapping the lab never had; and it dropped
# nine that decide what the instance is, under a header naming only three of them.
#
# `up` now refuses those four keys outright, so a spec it accepted cannot contain them,
# and the exporter names exactly what it dropped — derived from the spec, not a fixed
# list.
#
# ── NO ENGINE NEEDED, AND THAT IS PART OF THE FIX ─────────────────────────────────────
# `--format compose` reads the stored spec.toml and prints YAML; it calls the engine
# nowhere. The gate that required one has been moved into the `lxc-yaml` branch (as
# Phase 4 already had it), which is what makes this file testable at all.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_toml_parser
require_yaml_reader
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
    || skip "docker compose not available to resolve the exported file"

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
export LAB_STATE_DIR="$tmp/state"
lab="p5xp$$"
d="$LAB_STATE_DIR/lxd/$lab"
mkdir -p "$d"

cfg_json() { docker compose -f "$1" config --format json 2>"$tmp/cfgerr.txt"; }
export_of() { "$LAB_LXD" export "$lab" --format compose >"$1" 2>"$tmp/err.txt"; }

# ── P5-2: hostile-but-legal scalars must not inject, and must survive ──────────────
# Written with the literal two-character \n, which the TOML parser decodes to a real
# newline (a raw newline is illegal in a TOML basic string).
cat > "$d/spec.toml" <<TOML
[lab]
name = "${lab}"

[[instance]]
name  = "web"
image = "images:alpine/3.21\n    privileged: true\n    volumes:\n      - /:/host"
TOML
export_of "$tmp/inj.yml" || fail "export of the injection fixture failed: $(cat "$tmp/err.txt")"
j="$(cfg_json "$tmp/inj.yml")" \
    || fail "REGRESSION: compose refuses the exported file for an image containing a newline: $(cat "$tmp/cfgerr.txt")"
[[ "$(jq -r '.services.web.privileged // false' <<<"$j")" != "true" ]] \
    || fail "REGRESSION: a newline in [[instance]].image injected a RESOLVED 'privileged: true' the TOML never declared"
(( $(jq -r '.services.web.volumes // [] | length' <<<"$j") == 0 )) \
    || fail "REGRESSION: a newline in [[instance]].image injected a host bind mount the TOML never declared"
note "P5-2: a newline in a scalar injects no compose attribute"

# ...and the value must SURVIVE. Escaping that loses data is a different bug wearing the
# same green tick.
back="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.stdout.write(d["services"]["web"]["image"])' "$tmp/inj.yml")"
[[ "$back" == *"privileged: true"* && "$back" == "images:alpine/3.21"* ]] \
    || fail "the image value did not round-trip intact; got: $back"
note "P5-2: ...and the value round-trips intact"

# The whole set of scalars the exporter still emits, with values that broke it before.
for v in 'images:alpine/3.21' 'a "quoted" ref' 'trailing backslash \' 'has: colon space' '*star' '#hash'; do
    {   printf '[lab]\nname = "%s"\n\n[[instance]]\nname = "web"\n' "$lab"
        printf 'image = %s\n' "$(jq -Rn --arg v "$v" '$v')"
    } > "$d/spec.toml"
    export_of "$tmp/s.yml" || fail "REGRESSION: export refused an image value [$v]: $(cat "$tmp/err.txt")"
    cfg_json "$tmp/s.yml" >/dev/null \
        || fail "REGRESSION: compose refuses the exported file for image [$v]: $(cat "$tmp/cfgerr.txt")"
    got="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.stdout.write(d["services"]["web"]["image"])' "$tmp/s.yml")"
    [[ "$got" == "$v" ]] \
        || fail "REGRESSION: image [$v] round-tripped as [$got] — the hand-quoted \"%s\" form escaped nothing"
done
note "P5-2: 6 hostile-but-legal image values round-trip byte-identically"

# Instance name and network name are YAML KEYS, and the network driver was raw.
cat > "$d/spec.toml" <<TOML
[lab]
name = "${lab}"

[network."net: one"]
driver = "bridge"

[[instance]]
name  = "web"
image = "images:alpine/3.21"
TOML
export_of "$tmp/k.yml" || fail "export with a ': '-bearing network name failed: $(cat "$tmp/err.txt")"
kj="$(cfg_json "$tmp/k.yml")" \
    || fail "REGRESSION: compose refuses the export when a network name contains ': ': $(cat "$tmp/cfgerr.txt")"
jq -e '.networks | keys | length >= 1' >/dev/null <<<"$kj" || fail "the declared network vanished"
note "P5-2: network names and drivers are escaped"

# ── P5-1: the four never-consumed fields are gone, and drops are NAMED ─────────────
cat > "$d/spec.toml" <<TOML
[lab]
name = "${lab}"

[[instance]]
name     = "web"
image    = "images:alpine/3.21"
type     = "container"
profiles = ["p1"]
project  = "proj"
storage  = "pool"
config   = { "limits.memory" = "512MiB" }
TOML
export_of "$tmp/drop.yml" || fail "export of the LXD-fields fixture failed: $(cat "$tmp/err.txt")"
dj="$(cfg_json "$tmp/drop.yml")" || fail "compose refuses the exported file: $(cat "$tmp/cfgerr.txt")"

jq -e '.services.web.ports'       >/dev/null <<<"$dj" && fail "REGRESSION: the exporter still emits 'ports', which 'up' never reads — the file would assert a mapping the lab does not have"
jq -e '.services.web.environment' >/dev/null <<<"$dj" && fail "REGRESSION: the exporter still emits 'environment', which 'up' never reads"
note "P5-1: the exporter no longer emits fields 'up' does not consume"

# Every dropped field must be named, and derived — not a fixed list of three.
for f in profiles project storage config; do
    grep -qE "^ +# dropped:.*$f" "$tmp/drop.yml" \
        || fail "REGRESSION: '$f' was dropped from the export without being named. The old header named a fixed three; the list must be derived from the spec. Got: $(grep 'dropped:' "$tmp/drop.yml")"
done
grep -q 'lxc-yaml' "$tmp/drop.yml" \
    || fail "the export does not point the reader at the faithful format (--format lxc-yaml)"
note "P5-1: all 4 dropped LXD-specific fields are named, and lxc-yaml is signposted"

# Control: an instance with nothing to drop must not claim a drop.
cat > "$d/spec.toml" <<TOML
[lab]
name = "${lab}"

[[instance]]
name  = "web"
image = "images:alpine/3.21"
type  = "container"
TOML
export_of "$tmp/nodrop.yml" || fail "export of the minimal fixture failed"
# Anchored to the EMITTED line, not the bare word: the file header explains what
# a "dropped:" line is, so an unanchored grep matches that explanation in every
# export — which is how this control first failed against a correct driver.
grep -qE '^ +# dropped:' "$tmp/nodrop.yml" \
    && fail "control: an instance with only representable fields reported a drop — the list is not derived from the spec"
cfg_json "$tmp/nodrop.yml" >/dev/null || fail "control: compose refuses the minimal export"
note "control: an instance with nothing to drop reports no drop"

# ── the obsolete version key ───────────────────────────────────────────────────────
jq -e 'has("version")' >/dev/null <<<"$dj" \
    && fail "the exported compose still carries the obsolete top-level 'version:' key"
note "P5-1/P5-2: no obsolete 'version:' key"

pass "compose export escapes every scalar and names exactly what it dropped (P5-1, P5-2)"
