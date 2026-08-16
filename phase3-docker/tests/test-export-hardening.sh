#!/usr/bin/env bash
# Regression (REVIEW-phase3.md P3-1, P3-2): `export` is a SECOND WAY TO RUN THE LAB,
# not a report about it — SHOWCASE.md pipes it straight into `docker compose up -d`.
# So every protection `up` applies on the way to Docker must also apply on the way to
# the compose file: the F4 loopback default, name validation, and YAML escaping.
#
# The assertions read the RESOLVED compose attribute out of `docker compose config
# --format json` rather than grepping the emitted text.  A text grep for
# `privileged: true` also matches that string sitting harmlessly INSIDE a healthcheck
# value — an earlier version of this sweep reported two false positives for exactly
# that reason (REVIEW-phase3.md §2, P3-2).
#
# The payloads below are INERT: they are YAML data fed to `docker compose config`,
# which parses and prints.  Nothing here is ever `up`ed and no shell evaluates them.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq docker tomlq python3
# `docker compose config` parses locally — it needs the CLI and the compose plugin,
# but not a reachable daemon.
docker compose version >/dev/null 2>&1 || skip "docker compose plugin not available"
python3 -c 'import yaml' 2>/dev/null || skip "python3 PyYAML not available (needed to read back the emitted YAML scalar)"

# yaml_scalar FILE SERVICE KEY — the value a YAML parser reads back, which is the
# seam `export` is responsible for.  (Compose's own shlex splitting of a string
# `command:` is downstream of it and legitimately lossy for shell metacharacters.)
yaml_scalar() {
    python3 -c 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
v=d["services"][sys.argv[2]].get(sys.argv[3])
sys.stdout.write(v if isinstance(v,str) else repr(v))' "$@"
}

tmp="$(mktemp -d)"
on_exit 'rm -rf "$tmp"'

# render TOML -> exported compose YAML; dies (rc!=0) are the caller's to interpret.
export_of() {  # export_of <toml-file> [outfile]
    local f="$1" out="${2:-$tmp/out.yml}"
    "$LAB_DOCKER" export --config "$f" >"$out" 2>"$tmp/err.txt"
}

# resolved compose attribute, via compose's own parser
cfg_json() { docker compose -f "$1" config --format json 2>"$tmp/cfgerr.txt"; }

# ── P3-1 — the F4 loopback default must survive the export ──────────────────────────
cat >"$tmp/ports.toml" <<'TOML'
[lab]
name = "exph"

[[service]]
name = "web"
image = "busybox"
ports = ["19003:80", "127.0.0.1:19001:80", "0.0.0.0:19002:80", "[::1]:19004:80", "53:53/udp"]
TOML

export_of "$tmp/ports.toml" || fail "export of a plain ports fixture failed: $(cat "$tmp/err.txt")"
mapfile -t got < <(jq -r '.services.web.ports[] | "\(.host_ip):\(.published):\(.target)/\(.protocol)"' \
    <(cfg_json "$tmp/out.yml"))

want=(
    "127.0.0.1:19003:80/tcp"   # bare -> loopback default (the F4 fix)
    "127.0.0.1:19001:80/tcp"   # control: already loopback, unchanged
    "0.0.0.0:19002:80/tcp"     # control: explicit wide bind is the opt-in, unchanged
    "::1:19004:80/tcp"         # control: explicit IPv6 bind, unchanged
    "127.0.0.1:53:53/udp"      # bare + proto -> loopback, proto preserved
)
(( ${#got[@]} == ${#want[@]} )) \
    || fail "REGRESSION: exported ${#got[@]} port(s), expected ${#want[@]}: ${got[*]}"
for i in "${!want[@]}"; do
    [[ "${got[i]}" == "${want[i]}" ]] \
        || fail "REGRESSION: exported port $i is '${got[i]}', expected '${want[i]}' — export does not apply _pub_host (Review F4), so the artifact binds every interface while 'up' binds loopback"
done
note "P3-1: exported ports carry the F4 loopback default; explicit binds unchanged"

# LAB_PUBLISH_HOST must steer the export exactly as it steers `up`.
LAB_PUBLISH_HOST=0.0.0.0 "$LAB_DOCKER" export --config "$tmp/ports.toml" >"$tmp/pub.yml" \
    || fail "export with LAB_PUBLISH_HOST=0.0.0.0 failed"
[[ "$(jq -r '.services.web.ports[0].host_ip' <(cfg_json "$tmp/pub.yml"))" == "0.0.0.0" ]] \
    || fail "REGRESSION: LAB_PUBLISH_HOST is honoured by 'up' but ignored by 'export'"
note "P3-1: LAB_PUBLISH_HOST steers the export too"

# ── P3-2 facet (a) — a newline in a scalar must not become a sibling compose key ─────
# `command` is the demonstrated vector; the TOML below declares NEITHER `privileged`
# NOR a host bind mount.  Written with the literal two-character \n, which the TOML
# parser decodes to a real newline (a raw newline is illegal in a TOML basic string).
cat >"$tmp/inj.toml" <<'TOML'
[lab]
name = "exph"

[[service]]
name = "web"
image = "busybox"
command = "sleep 1\n    privileged: true\n    volumes:\n      - /:/host"
TOML

export_of "$tmp/inj.toml" || fail "export of the injection fixture failed: $(cat "$tmp/err.txt")"
j="$(cfg_json "$tmp/out.yml")" || fail "REGRESSION: compose refuses the exported file for a command containing a newline: $(cat "$tmp/cfgerr.txt")"

priv="$(jq -r '.services.web.privileged // false' <<<"$j")"
[[ "$priv" != "true" ]] \
    || fail "REGRESSION: a newline in [[service]].command injected a RESOLVED 'privileged: true' the TOML never declared"
nvol="$(jq -r '.services.web.volumes // [] | length' <<<"$j")"
(( nvol == 0 )) \
    || fail "REGRESSION: a newline in [[service]].command injected $nvol volume(s) — the TOML declared none"
note "P3-2a: a newline in a scalar injects no compose attribute"

# ...and the value must SURVIVE, not merely be refused: escaping that loses data is
# a different bug wearing the same green tick.
cmd_out="$(yaml_scalar "$tmp/out.yml" web command)"
[[ "$cmd_out" == *"privileged: true"* && "$cmd_out" == "sleep 1"* ]] \
    || fail "the injected-looking command did not round-trip into the command scalar; got: $cmd_out"
note "P3-2a: ...and the value round-trips into the command scalar intact"

# ── P3-2 facet (b) — ordinary values must not break the artifact ─────────────────────
# Four of the first five produced a file `docker compose` refuses, before the fix.
#
# ASSERTED AT THE YAML SEAM, not at compose's argv.  Compose shell-splits a string
# `command:` with its own shlex, which legitimately drops `;` and `}` — so reading
# the RESOLVED argv back would be testing compose's splitter, not this exporter.
# The property that belongs to `export` is: the scalar a YAML parser reads back is
# the string the TOML declared, and compose accepts the file.
ordinary=(
    'sh -c echo hi: there'
    'true'
    '*.sh'
    '{ echo hi; }'
    'yes'
    'a "quoted" arg'
    '#leading hash'
    '- leading dash'
    '@at %pct `tick`'
)
# NOTE: a command ending in a bare backslash is deliberately NOT in this list — it
# is not a well-formed shell command line, and compose refusing it is correct
# behaviour, not an export defect.  Backslash fidelity is asserted below through a
# field nothing shell-splits.
for c in "${ordinary[@]}"; do
    {   printf '[lab]\nname = "exph"\n\n[[service]]\nname = "web"\nimage = "busybox"\n'
        printf 'command = %s\n' "$(jq -Rn --arg c "$c" '$c')"
    } >"$tmp/ord.toml"
    export_of "$tmp/ord.toml" "$tmp/ord.yml" \
        || fail "REGRESSION: export refused an ordinary command [$c]: $(cat "$tmp/err.txt")"
    cfg_json "$tmp/ord.yml" >/dev/null \
        || fail "REGRESSION: compose refuses the exported file for an ordinary command [$c]: $(cat "$tmp/cfgerr.txt")"
    oc="$(yaml_scalar "$tmp/ord.yml" web command)"
    [[ "$oc" == "$c" ]] \
        || fail "REGRESSION: command [$c] round-tripped as [$oc] — YAML re-typed or mangled an ordinary string"
done
note "P3-2b: ${#ordinary[@]} ordinary command strings round-trip through the exported compose"

# Scalar fidelity in a field nothing shell-splits.  Review L1: escape the backslash
# FIRST, then the double-quote, or a value ending in `\` escapes the closing quote
# and swallows the next line.  A control character must be escaped rather than
# emitted raw (P3-2) — and must come back byte-identical, since escaping that loses
# data is a different bug wearing the same green tick.
hostile=(
    'trailing backslash \'
    'a "quoted" value'
    'both \" together'
    'tab	here'
    'percent %s and backtick `x`'
    '${NOT_EXPANDED}'
)
for hv in "${hostile[@]}"; do
    {   printf '[lab]\nname = "exph"\n\n[[service]]\nname = "web"\nimage = "busybox"\n\n[service.environment]\n'
        printf 'HV = %s\n' "$(jq -Rn --arg v "$hv" '$v')"
    } >"$tmp/hos.toml"
    export_of "$tmp/hos.toml" "$tmp/hos.yml" \
        || fail "REGRESSION: export refused an env value [$hv]: $(cat "$tmp/err.txt")"
    cfg_json "$tmp/hos.yml" >/dev/null \
        || fail "REGRESSION: compose refuses the exported file for env value [$hv]: $(cat "$tmp/cfgerr.txt")"
    hout="$(python3 -c 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
sys.stdout.write(d["services"]["web"]["environment"]["HV"])' "$tmp/hos.yml")"
    [[ "$hout" == "$hv" ]] \
        || fail "REGRESSION: env value [$hv] round-tripped as [$hout] — YAML escaping is lossy or malformed"
done
note "P3-2b: ${#hostile[@]} hostile-but-legal scalars round-trip byte-identically"

# A newline in a scalar must be ESCAPED (\n inside the quoted form), not emitted raw
# and not refused — and it must read back as the same newline.
{   printf '[lab]\nname = "exph"\n\n[[service]]\nname = "web"\nimage = "busybox"\n\n[service.environment]\n'
    printf 'NL = "one\\ntwo"\n'
} >"$tmp/nl.toml"
export_of "$tmp/nl.toml" "$tmp/nl.yml" || fail "export refused an env value containing a newline: $(cat "$tmp/err.txt")"
[[ "$(grep -c '^      "NL":' "$tmp/nl.yml")" == "1" ]] \
    || fail "REGRESSION: a newline in an env value was emitted raw and split the scalar across lines"
cfg_json "$tmp/nl.yml" >/dev/null || fail "REGRESSION: compose refuses an exported env value containing a newline"
nlout="$(python3 -c 'import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
sys.stdout.write(repr(d["services"]["web"]["environment"]["NL"]))' "$tmp/nl.yml")"
[[ "$nlout" == "'one\nnew'" || "$nlout" == "'one\\ntwo'" ]] \
    || fail "REGRESSION: an env value containing a newline round-tripped as $nlout, expected 'one\\ntwo'"
note "P3-2b: a newline inside a scalar is escaped, kept on one line, and reads back intact"

# Every other config-reachable string field, same question.
cat >"$tmp/wide.toml" <<'TOML'
[lab]
name = "exph"

[network."net: one"]
driver = "bridge"

[[service]]
name = "web"
image = "busybox:latest"
networks = ["net: one"]
ports = ["19005:80"]
volumes = ["vol: one:/data", "/tmp:/host-tmp"]
command = "sleep 1"

[service.environment]
"K: 1" = "v: 1"
PLAIN = "plain"

[service.healthcheck]
test = "curl -f http://x || exit 1"
interval = "10s"
timeout = "3s"
retries = "3"
start_period = "5s"
TOML

export_of "$tmp/wide.toml" "$tmp/wide.yml" || fail "export of the wide fixture failed: $(cat "$tmp/err.txt")"
wj="$(cfg_json "$tmp/wide.yml")" \
    || fail "REGRESSION: compose refuses the exported file when ordinary values contain ': ' — $(cat "$tmp/cfgerr.txt")"

[[ "$(jq -r '.services.web.environment["K: 1"]' <<<"$wj")" == "v: 1" ]] \
    || fail "REGRESSION: an environment key/value containing ': ' did not round-trip"
[[ "$(jq -r '.networks | keys | length' <<<"$wj")" -ge 1 ]] \
    || fail "REGRESSION: the declared network vanished from the export"
[[ "$(jq -r '.services.web.healthcheck.retries' <<<"$wj")" == "3" ]] \
    || fail "REGRESSION: healthcheck.retries did not round-trip"
[[ "$(jq -r '.services.web.healthcheck.interval' <<<"$wj")" == "10s" ]] \
    || fail "REGRESSION: healthcheck.interval did not round-trip"
note "P3-2b: names, env, volumes, networks and the healthcheck block survive ': ' in every field"

# The healthcheck test must be ONE line — it used to be a pretty-printed jq array
# spanning four lines at column 2 inside a block indented to 6 (valid only because
# YAML flow context ignores indentation).
#
# NOTE the assertion this replaced: `grep -c '^      test: '` returned 1 for BOTH the
# compact and the pretty-printed form, because only the FIRST line of the pretty form
# carries the prefix — a cheap check that looked like the real one and could never
# fail.  Measured against the pre-fix driver on 2026-08-16.  The real question is
# whether the VALUE is complete on that line.
hc_line="$(grep '^      test: ' "$tmp/wide.yml" || true)"
[[ "$hc_line" == *']' ]] \
    || fail "healthcheck test spans more than one line (jq pretty-printed it); the emitted line was: [$hc_line]"
[[ "$hc_line" == '      test: ["CMD-SHELL",'* ]] \
    || fail "healthcheck test is not emitted as a compact single-line flow sequence; got: [$hc_line]"
note "P3-2b: healthcheck.test is emitted compact (jq -c), not pretty-printed"

# ── P3-2 facet (c) — export must validate names, as `up` does at its first line ──────
cat >"$tmp/badlab.toml" <<'TOML'
[lab]
name = "-not a valid name!"

[[service]]
name = "web"
image = "busybox"
TOML
out="$("$LAB_DOCKER" export --config "$tmp/badlab.toml" 2>&1)" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: export accepted an invalid lab name that 'up' refuses; emitted: $out"
grep -qi 'invalid lab name' <<<"$out" || fail "export refused the bad lab name but did not say why: $out"

cat >"$tmp/badsvc.toml" <<'TOML'
[lab]
name = "exph"

[[service]]
name = "also bad!!"
image = "busybox"
TOML
out="$("$LAB_DOCKER" export --config "$tmp/badsvc.toml" 2>&1)" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: export accepted an invalid service name that 'up' refuses; emitted: $out"
grep -qi 'invalid service name' <<<"$out" || fail "export refused the bad service name but did not say why: $out"
note "P3-2c: export validates lab and service names before emitting"

# ── §3 — a literal env value of "null" must not be read as the null sentinel ─────────
cat >"$tmp/nullenv.toml" <<'TOML'
[lab]
name = "exph"

[[service]]
name = "web"
image = "busybox"

[service.environment]
A = "null"
B = "keep"
TOML
export_of "$tmp/nullenv.toml" "$tmp/nullenv.yml" || fail "export of the null-env fixture failed"
nj="$(cfg_json "$tmp/nullenv.yml")" || fail "compose refuses the exported null-env file"
[[ "$(jq -r '.services.web.environment.A' <<<"$nj")" == "null" ]] \
    || fail "REGRESSION: a literal environment value of \"null\" was dropped — the sentinel for inherit-from-host collides with a legal value at the text seam"
[[ "$(jq -r '.services.web.environment.B' <<<"$nj")" == "keep" ]] \
    || fail "the control env var did not survive"
note "§3: a literal env value of \"null\" survives the export"

pass "export applies the F4 loopback default, validates names, and escapes every scalar (P3-1, P3-2)"
