#!/usr/bin/env bash
# Unit test: load_config() accepts docker-compose .yml / .yaml files and
# produces the same internal JSON schema as TOML files.
# No docker run needed — pure JSON schema verification.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

# Compose YAML interop requires mikefarah/yq.
if ! ( command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah ); then
    skip "Compose YAML interop requires mikefarah/yq"
fi

# Source load_config and compose_to_json without running main().
export LAB_LOG_LEVEL=error
# shellcheck disable=SC1090
. "$LAB_DOCKER" 2>/dev/null || true

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

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

# ── export round-trip: compose YAML in → compose YAML out ──────────────────
exported="$("$LAB_DOCKER" export --config "$tmp/compose.yml")"
grep -q '^services:'    <<<"$exported" || fail "round-trip export: missing services:"
grep -q '^  web:'       <<<"$exported" || fail "round-trip export: missing web:"
grep -q '^  db:'        <<<"$exported" || fail "round-trip export: missing db:"
grep -q 'healthcheck:'  <<<"$exported" || fail "round-trip export: healthcheck missing from db"
grep -q 'depends_on:'   <<<"$exported" || fail "round-trip export: depends_on missing from web"
note "round-trip compose → export OK"

pass "compose YAML interop OK"
