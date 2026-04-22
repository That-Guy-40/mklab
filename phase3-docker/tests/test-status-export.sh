#!/usr/bin/env bash
# Covers the status + export (compose) subcommands added to close the
# genuinely-portable gap with Phase 4.
#
# status    — no-arg / lab-scoped / container-scoped forms
# export    — usage guard, format guard, valid compose YAML, cross-phase
#             engine filter (podman services are dropped)

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker
require_cmd jq

# Need a TOML parser.
if ! command -v tomlq >/dev/null 2>&1 \
   && ! command -v dasel >/dev/null 2>&1 \
   && ! ( command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah ); then
    skip "no TOML parser (need yq/tomlq/dasel)"
fi

# ─── export: usage / format guards ─────────────────────────────────────────
expect_error "export without --config" "config topology.toml" -- export
expect_error "export unknown format"   "unknown export format" -- export --config /dev/null --format kube

# ─── export: valid compose on a multi-service TOML ─────────────────────────
cfg="$(mktemp --suffix=.toml)"
lab="xp$$"
trap 'rm -f "$cfg" "${out:-}"; cleanup_lab "$lab"' EXIT

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[network.front]
driver = "bridge"

[[service]]
name     = "web"
image    = "nginx:alpine"
networks = ["front"]
ports    = ["18098:80"]
volumes  = ["webdata:/data"]

[[service]]
name     = "db"
image    = "postgres:16-alpine"
networks = ["front"]
environment = { POSTGRES_PASSWORD = "lab" }

# Cross-phase hint: podman-only service should NOT appear in the export.
[[service]]
name    = "scanner"
engine  = "podman"
image   = "docker.io/library/alpine:latest"
EOF

out="$(mktemp --suffix=.yml)"
note "export → compose YAML"
"$LAB_DOCKER" export --config "$cfg" --format compose > "$out"

grep -q '^services:'               "$out" || fail "missing 'services:' key"
grep -q '^  web:'                  "$out" || fail "missing service 'web'"
grep -q '^  db:'                   "$out" || fail "missing service 'db'"
grep -q '^  scanner:'              "$out" && fail "podman-engine service leaked into docker compose export"
grep -q '^networks:'               "$out" || fail "missing 'networks:' key"
grep -q '^  front:'                "$out" || fail "missing network 'front'"
grep -q '^volumes:'                "$out" || fail "missing top-level 'volumes:' for named volume"
grep -q '^  webdata:'              "$out" || fail "named volume 'webdata' not declared"
grep -q 'container_name: lab-'     "$out" || fail "container_name not prefixed with lab-"

# Compose v2 obsoletes top-level version:, so it should NOT be present.
grep -q '^version:' "$out" && fail "compose YAML carries obsolete 'version:' key"
note "export shape OK"

# If docker compose is on hand, verify the generated file actually parses.
if docker compose version >/dev/null 2>&1; then
    note "docker compose config --quiet"
    docker compose -f "$out" config --quiet \
        || fail "generated compose YAML did not validate"
    note "compose accepted the YAML"
else
    note "docker compose not available — skipping schema validation"
fi

# ─── status: usage / no-arg / bogus-target ─────────────────────────────────
note "status (no arg) dumps daemon summary"
"$LAB_DOCKER" status 2>&1 | grep -q '^── docker info' \
    || fail "bare 'status' did not print daemon summary"

expect_error "status on nonexistent target" "no lab or container" -- status not-a-real-lab-xyz

# ─── status: live lab via a labeled container ──────────────────────────────
cname="lab-${lab}-statusprobe"
note "launching a labeled container to exercise lab + container status paths"
docker run -d \
    --name "$cname" \
    --label "lab-create.tool=lab-docker" \
    --label "lab-create.lab=${lab}" \
    --label "lab-create.svc=statusprobe" \
    --hostname statusprobe \
    alpine:latest sleep 60 >/dev/null \
    || skip "could not start probe container (daemon problem, not a test failure)"

note "status <lab>"
lab_out="$("$LAB_DOCKER" status "$lab" 2>&1)"
grep -q '\[containers\]' <<<"$lab_out" \
    || fail "status <lab> did not show [containers] section; got: $lab_out"
grep -q "$cname"          <<<"$lab_out" \
    || fail "status <lab> did not mention probe container $cname; got: $lab_out"

note "status <lab>/<svc>"
svc_out="$("$LAB_DOCKER" status "${lab}/statusprobe" 2>&1)"
grep -q "^Name:.*$cname" <<<"$svc_out" \
    || fail "status <lab>/<svc> did not return container detail; got: $svc_out"

pass "status + export"
