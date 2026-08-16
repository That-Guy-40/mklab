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

require_toml_parser

# ─── export: usage / format guards ─────────────────────────────────────────
expect_error "export without --config" "config topology.toml" -- export
expect_error "export unknown format"   "unknown export format" -- export --config /dev/null --format kube

# ─── export: valid compose on a multi-service TOML ─────────────────────────
cfg="$(mktemp --suffix=.toml)"
lab="xp$$"
on_exit 'rm -f "$cfg" "${out:-}"; cleanup_lab "$lab"'

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

# Assert on the PARSED document rather than on the text that encodes it — the
# emitter quotes every scalar now (P3-2), and a `grep '^  webdata:'` was asserting
# the rendering, not the presence of the volume.
j="$(yaml_json "$out")" || skip "no YAML reader (python3+PyYAML or a yq that supports -p yaml)"

jq -e '.services'          >/dev/null <<<"$j" || fail "missing 'services:' key"
jq -e '.services.web'      >/dev/null <<<"$j" || fail "missing service 'web'"
jq -e '.services.db'       >/dev/null <<<"$j" || fail "missing service 'db'"
jq -e '.services.scanner'  >/dev/null <<<"$j" && fail "podman-engine service leaked into docker compose export"
jq -e '.networks'          >/dev/null <<<"$j" || fail "missing 'networks:' key"
jq -e '.networks.front'    >/dev/null <<<"$j" || fail "missing network 'front'"
jq -e '.volumes'           >/dev/null <<<"$j" || fail "missing top-level 'volumes:' for named volume"
jq -e '.volumes | has("webdata")' >/dev/null <<<"$j" || fail "named volume 'webdata' not declared"
[[ "$(jq -r '.services.web.container_name' <<<"$j")" == "lab-${lab}-web" ]] \
    || fail "container_name not prefixed with lab-<lab>-"

# Compose v2 obsoletes top-level version:, so it should NOT be present.
jq -e 'has("version")' >/dev/null <<<"$j" && fail "compose YAML carries obsolete 'version:' key"
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
has_match '── docker info' -- "$LAB_DOCKER" status \
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
