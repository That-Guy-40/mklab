#!/usr/bin/env bash
# Regression (REVIEW-phase4.md P4-5): `export --format compose` is a SECOND WAY TO RUN
# THE LAB, and it was the one with no guards — Phase 3's P3-1 and P3-2 recurring in
# Phase 4's separate implementation of the same idea.
#
# Facet (a): the F4 loopback default was not applied. The contrast lived inside ONE
# driver, from ONE spec, in two artifacts it generates:
#
#     quadlet unit (.container):        compose export:
#       PublishPort=127.0.0.1:18097:80    - "18097:80"
#
# Same tool, same input, one artifact guarded and one not — an omission, not a design
# decision. (That half was fixed on 2026-08-16 alongside Phase 3's P3-1; this file now
# guards it.)
#
# Facet (b): `image` and `command` were emitted raw, under a comment asserting they are
# "engine-validated" — which cannot apply to a file the engine never sees, since
# `--format compose` is a pure text transformation over spec.toml. A newline in either
# injected a RESOLVED compose attribute.
#
# Asserted on the attribute compose RESOLVES and on the value a YAML parser reads back,
# never on the emitted text: a text grep for `privileged: true` also matches that string
# sitting harmlessly inside another scalar.
#
# The payloads are inert — YAML data fed to a parser. Nothing here is ever `up`ed.
#
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_toml_parser
require_yaml_reader
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
    || skip "docker compose not available to resolve the exported file"

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
export LAB_STATE_DIR="$tmp/state"
lab="p4xp$$"
d="$LAB_STATE_DIR/podman/$lab"
mkdir -p "$d"

cfg_json() { docker compose -f "$1" config --format json 2>"$tmp/cfgerr.txt"; }

# ── facet (a): the F4 loopback default ─────────────────────────────────────────────
cat > "$d/spec.toml" <<TOML
[lab]
name = "${lab}"

[[service]]
name  = "web"
image = "alpine:latest"
ports = ["18097:80", "127.0.0.1:18096:81", "0.0.0.0:18095:82", "53:53/udp"]
TOML

"$LAB_PODMAN" export "$lab" --format compose > "$tmp/a.yml" 2>"$tmp/err.txt" \
    || fail "export failed: $(cat "$tmp/err.txt")"
j="$(cfg_json "$tmp/a.yml")" || fail "compose refuses the exported file: $(cat "$tmp/cfgerr.txt")"

mapfile -t got < <(jq -r '.services.web.ports[] | "\(.host_ip):\(.published):\(.target)/\(.protocol)"' <<<"$j")
want=(
    "127.0.0.1:18097:80/tcp"   # bare -> loopback default (F4)
    "127.0.0.1:18096:81/tcp"   # control: already loopback, unchanged
    "0.0.0.0:18095:82/tcp"     # control: explicit wide bind is the opt-in, unchanged
    "127.0.0.1:53:53/udp"      # bare + proto -> loopback, proto preserved
)
(( ${#got[@]} == ${#want[@]} )) || fail "exported ${#got[@]} port(s), expected ${#want[@]}: ${got[*]}"
for i in "${!want[@]}"; do
    [[ "${got[i]}" == "${want[i]}" ]] \
        || fail "REGRESSION: exported port $i is '${got[i]}', expected '${want[i]}' — the compose export does not apply _pub_host (Review F4), while the quadlet writer in the SAME driver does"
done
note "P4-5a: exported ports carry the F4 loopback default; explicit binds unchanged"

# The two artifacts this driver generates must agree with each other.
export XDG_CONFIG_HOME="$tmp/xdg"; mkdir -p "$tmp/xdg/containers/systemd"
if "$LAB_PODMAN" generate --config "$d/spec.toml" >/dev/null 2>&1; then
    unit="$tmp/xdg/containers/systemd/lab-${lab}-web.container"
    if [[ -f "$unit" ]]; then
        grep -q '^PublishPort=127\.0\.0\.1:18097:80$' "$unit" \
            || fail "the quadlet unit lost the loopback default: $(grep '^PublishPort' "$unit" | tr '\n' ' ')"
        note "P4-5a: the quadlet unit and the compose export now agree on the same spec"
    fi
fi

# ── facet (b): scalars must not inject, and must survive ───────────────────────────
# Written with the literal two-character \n, which the TOML parser decodes to a real
# newline (a raw newline is illegal in a TOML basic string).
cat > "$d/spec.toml" <<TOML
[lab]
name = "${lab}"

[[service]]
name    = "web"
image   = "alpine:latest"
command = "sleep 1\n    privileged: true\n    volumes:\n      - /:/host"
TOML

"$LAB_PODMAN" export "$lab" --format compose > "$tmp/b.yml" 2>"$tmp/err.txt" \
    || fail "export of the injection fixture failed: $(cat "$tmp/err.txt")"
j="$(cfg_json "$tmp/b.yml")" \
    || fail "REGRESSION: compose refuses the exported file for a command containing a newline: $(cat "$tmp/cfgerr.txt")"

[[ "$(jq -r '.services.web.privileged // false' <<<"$j")" != "true" ]] \
    || fail "REGRESSION: a newline in [[service]].command injected a RESOLVED 'privileged: true' the TOML never declared"
(( $(jq -r '.services.web.volumes // [] | length' <<<"$j") == 0 )) \
    || fail "REGRESSION: a newline in [[service]].command injected a host bind mount the TOML never declared"
note "P4-5b: a newline in a scalar injects no compose attribute"

cmd_back="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.stdout.write(d["services"]["web"]["command"])' "$tmp/b.yml")"
[[ "$cmd_back" == *"privileged: true"* && "$cmd_back" == "sleep 1"* ]] \
    || fail "the value did not survive escaping — escaping that loses data is a different bug wearing the same green tick; got: $cmd_back"
note "P4-5b: ...and the value round-trips intact"

# Ordinary values must not break the artifact either.
for c in 'sh -c echo hi: there' 'true' '*.sh' 'yes' 'a "quoted" arg' '#leading hash'; do
    {   printf '[lab]\nname = "%s"\n\n[[service]]\nname = "web"\nimage = "alpine:latest"\n' "$lab"
        printf 'command = %s\n' "$(jq -Rn --arg c "$c" '$c')"
    } > "$d/spec.toml"
    "$LAB_PODMAN" export "$lab" --format compose > "$tmp/c.yml" 2>"$tmp/err.txt" \
        || fail "REGRESSION: export refused an ordinary command [$c]: $(cat "$tmp/err.txt")"
    cfg_json "$tmp/c.yml" >/dev/null \
        || fail "REGRESSION: compose refuses the exported file for an ordinary command [$c]: $(cat "$tmp/cfgerr.txt")"
    back="$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); v=d["services"]["web"].get("command"); sys.stdout.write(v if isinstance(v,str) else repr(v))' "$tmp/c.yml")"
    [[ "$back" == "$c" ]] \
        || fail "REGRESSION: command [$c] round-tripped as [$back] — YAML re-typed or mangled an ordinary string"
done
note "P4-5b: 6 ordinary command strings round-trip through the exported compose"

# An image is a scalar too, and it was emitted raw beside the command.
{   printf '[lab]\nname = "%s"\n\n[[service]]\nname = "web"\n' "$lab"
    printf 'image = "alpine:latest\\n    privileged: true"\n'
} > "$d/spec.toml"
"$LAB_PODMAN" export "$lab" --format compose > "$tmp/i.yml" 2>/dev/null || true
if ij="$(cfg_json "$tmp/i.yml")"; then
    [[ "$(jq -r '.services.web.privileged // false' <<<"$ij")" != "true" ]] \
        || fail "REGRESSION: a newline in [[service]].image injected 'privileged: true'"
fi
note "P4-5b: the image scalar is escaped too, not just the command"

# The env KEY was raw while its value was escaped — the same asymmetry Phase 3 had.
{   printf '[lab]\nname = "%s"\n\n[[service]]\nname = "web"\nimage = "alpine:latest"\n\n' "$lab"
    printf '[service.environment]\n"K: 1" = "v: 1"\n'
} > "$d/spec.toml"
"$LAB_PODMAN" export "$lab" --format compose > "$tmp/e.yml" 2>"$tmp/err.txt" \
    || fail "export with a ': '-bearing env key failed: $(cat "$tmp/err.txt")"
ej="$(cfg_json "$tmp/e.yml")" \
    || fail "REGRESSION: compose refuses the export when an environment KEY contains ': ' (the key was emitted raw while its value was escaped): $(cat "$tmp/cfgerr.txt")"
[[ "$(jq -r '.services.web.environment["K: 1"]' <<<"$ej")" == "v: 1" ]] \
    || fail "REGRESSION: an environment key/value containing ': ' did not round-trip"
note "P4-5b: environment keys are escaped like their values"

# ── the obsolete top-level `version:` key ──────────────────────────────────────────
# Compose v2 treats it as obsolete and warns; Phase 3 already omits it deliberately.
jq -e 'has("version")' >/dev/null <<<"$ej" \
    && fail "the exported compose still carries the obsolete top-level 'version:' key that current Compose warns about"
note "P4-5: no obsolete 'version:' key"

pass "compose export applies the F4 default and escapes every scalar (P4-5)"
