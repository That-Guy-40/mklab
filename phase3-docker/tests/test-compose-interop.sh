#!/usr/bin/env bash
# Unit test: load_config() accepts docker-compose .yml / .yaml files and
# produces the same internal JSON schema as TOML files.
# No docker run needed — pure JSON schema verification.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

# Compose YAML interop needs a YAML reader — asked as a capability, not a banner.
# This test SKIPPED on the audit host for two years' worth of yq releases (4.2.0
# fails the vendor grep), and the skip was hiding a stale assertion: the round-trip
# checks at the bottom still grepped for the UNQUOTED `^  web:` that `export` stopped
# emitting when Finding 21 quoted YAML keys.  An unrun test rots silently.
require_yaml_reader

# Source load_config and compose_to_json without running main().
export LAB_LOG_LEVEL=error
# shellcheck disable=SC1090
. "$LAB_DOCKER" 2>/dev/null || true

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'

# ── Minimal compose YAML → internal schema ──────────────────────────────────
cat > "$tmp/compose.yml" <<'YAML'
name: mylab

networks:
  front:
    driver: bridge

services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
    networks:
      - front
    depends_on:
      - db

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: lab
    networks:
      - front
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
YAML

json="$(load_config "$tmp/compose.yml")"

# [lab].name
name="$(jq -r '.lab.name' <<<"$json")"
[[ "$name" == "mylab" ]] || fail ".lab.name: expected 'mylab', got '$name'"
note ".lab.name OK"

# network section
net_driver="$(jq -r '.network.front.driver' <<<"$json")"
[[ "$net_driver" == "bridge" ]] || fail ".network.front.driver: expected bridge, got '$net_driver'"
note ".network OK"

# service count
svc_count="$(jq '.service | length' <<<"$json")"
[[ "$svc_count" -eq 2 ]] || fail "expected 2 services, got $svc_count"
note ".service count OK"

# web service
web_img="$(jq -r '.service[] | select(.name=="web") | .image' <<<"$json")"
[[ "$web_img" == "nginx:alpine" ]] || fail "web.image: expected nginx:alpine, got '$web_img'"
web_port="$(jq -r '.service[] | select(.name=="web") | .ports[0]' <<<"$json")"
[[ "$web_port" == "8080:80" ]] || fail "web.ports[0]: expected 8080:80, got '$web_port'"
web_dep="$(jq -r '.service[] | select(.name=="web") | .depends_on[0]' <<<"$json")"
[[ "$web_dep" == "db" ]] || fail "web.depends_on[0]: expected db, got '$web_dep'"
note "web service fields OK"

# db service healthcheck
db_hc="$(jq -r '.service[] | select(.name=="db") | .healthcheck.test' <<<"$json")"
[[ "$db_hc" == "pg_isready -U postgres" ]] \
    || fail "db.healthcheck.test: expected 'pg_isready -U postgres', got '$db_hc'"
db_interval="$(jq -r '.service[] | select(.name=="db") | .healthcheck.interval' <<<"$json")"
[[ "$db_interval" == "10s" ]] || fail "db.healthcheck.interval: expected 10s, got '$db_interval'"
note "db healthcheck fields OK"

# db environment
db_env="$(jq -r '.service[] | select(.name=="db") | .environment.POSTGRES_PASSWORD' <<<"$json")"
[[ "$db_env" == "lab" ]] || fail "db.environment.POSTGRES_PASSWORD: expected lab, got '$db_env'"
note "db environment OK"

# ── .yaml extension also dispatches to compose_to_json ──────────────────────
cp "$tmp/compose.yml" "$tmp/compose.yaml"
json2="$(load_config "$tmp/compose.yaml")"
name2="$(jq -r '.lab.name' <<<"$json2")"
[[ "$name2" == "mylab" ]] || fail ".yaml extension: .lab.name mismatch: '$name2'"
note ".yaml extension dispatched correctly"

# ── healthcheck exec form: CMD carries an ARGV, not a shell string ─────────
# The internal schema holds a shell string (docker run --health-cmd runs it through
# a shell), so an exec-form test has to be RENDERED into one.  Joining on spaces is
# right for CMD-SHELL and wrong for CMD: ["CMD","a b","c"] joined is "a b c", which
# the shell re-splits into three words — a two-argument check silently becomes a
# three-argument one.  (REVIEW-phase3.md §3b flagged this as a reading; with a YAML
# reader on hand it is now a measurement.)
cat > "$tmp/exec.yml" <<'YAML'
name: execlab
services:
  probe:
    image: busybox
    healthcheck:
      test: ["CMD", "/bin/check", "one arg with spaces", "second"]
YAML
exec_hc="$(jq -r '.service[] | select(.name=="probe") | .healthcheck.test' <<<"$(load_config "$tmp/exec.yml")")"
[[ "$exec_hc" != "/bin/check one arg with spaces second" ]] \
    || fail "REGRESSION: an exec-form CMD healthcheck was joined on spaces, so 'one arg with spaces' re-splits into four words when the shell runs it"
# The rendering must survive a round trip through the shell's own word splitting.
# `t[1:]` drops the "CMD" marker, so three argv elements must survive as three
# shell words — the joined-on-spaces rendering yields six.
mapfile -t words < <(eval "printf '%s\n' $exec_hc")
(( ${#words[@]} == 3 )) \
    || fail "REGRESSION: exec-form healthcheck rendered to ${#words[@]} shell words, expected 3: ${words[*]}"
[[ "${words[1]}" == "one arg with spaces" ]] \
    || fail "REGRESSION: exec-form healthcheck lost an argument boundary: got '${words[1]}'"
note "CMD exec-form healthcheck keeps its argument boundaries (@sh)"

# ── inherit-from-host env: a null value is NOT the string "null" (Finding 32) ──
cat > "$tmp/inherit.yml" <<'YAML'
name: envlab
services:
  app:
    image: busybox
    environment:
      - INHERITED
      - EXPLICIT=set
      - LITERAL=null
YAML
ij="$(load_config "$tmp/inherit.yml")"
[[ "$(jq -r '.service[0].environment.INHERITED' <<<"$ij")" == "null" ]] \
    || fail "an environment entry with no '=' should become a JSON null (inherit from host)"
[[ "$(jq -r '.service[0].environment | .INHERITED == null' <<<"$ij")" == "true" ]] \
    || fail "INHERITED should be a JSON null, not the string \"null\""
[[ "$(jq -r '.service[0].environment | .LITERAL == "null"' <<<"$ij")" == "true" ]] \
    || fail "REGRESSION: a literal value of \"null\" collided with the inherit sentinel"
note "inherit-from-host env is a JSON null, distinct from the literal string"

# ...and export must render the two differently: a bare key for inherit, a quoted
# scalar for the literal.  This is the seam where the sentinel used to collide.
"$LAB_DOCKER" export --config "$tmp/inherit.yml" > "$tmp/inherit-out.yml" \
    || fail "export of the inherit fixture failed"
ej="$(yaml_json "$tmp/inherit-out.yml")" || skip "no YAML reader for the export round-trip"
[[ "$(jq -r '.services.app.environment.INHERITED == null' <<<"$ej")" == "true" ]] \
    || fail "REGRESSION: an inherit-from-host env var was exported with a value"
[[ "$(jq -r '.services.app.environment.LITERAL' <<<"$ej")" == "null" ]] \
    || fail "REGRESSION: a literal env value of \"null\" was dropped by export"
note "export renders inherit-from-host and the literal \"null\" differently"

# ── export round-trip: compose YAML in → compose YAML out ──────────────────
"$LAB_DOCKER" export --config "$tmp/compose.yml" > "$tmp/rt.yml" || fail "round-trip export failed"
rt="$(yaml_json "$tmp/rt.yml")" || skip "no YAML reader for the round-trip assertions"
jq -e '.services.web' >/dev/null <<<"$rt" || fail "round-trip export: missing web"
jq -e '.services.db'  >/dev/null <<<"$rt" || fail "round-trip export: missing db"
jq -e '.services.db.healthcheck' >/dev/null <<<"$rt" || fail "round-trip export: healthcheck missing from db"
jq -e '.services.web.depends_on' >/dev/null <<<"$rt" || fail "round-trip export: depends_on missing from web"
# The port came in bare ("8080:80"), so the export must apply the F4 loopback
# default to it exactly as `up` would (P3-1) — the compose-YAML input path is a
# publish site too.
[[ "$(jq -r '.services.web.ports[0]' <<<"$rt")" == "127.0.0.1:8080:80" ]] \
    || fail "REGRESSION: a bare port read from compose YAML was exported without the F4 loopback default"
note "round-trip compose → export OK, including the loopback default"

pass "compose YAML interop OK (schema, exec-form healthcheck, inherit-env, export round-trip)"
