#!/usr/bin/env bash
# Unit test: healthcheck and depends_on are correctly emitted in compose export.
# No docker run needed — only export (which is pure template rendering).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

require_toml_parser

cfg="$(mktemp --suffix=.toml)"
on_exit 'rm -f "$cfg"'

cat > "$cfg" <<'TOML'
[lab]
name = "hctest"

[[service]]
name  = "db"
image = "postgres:16-alpine"

[service.healthcheck]
test         = "pg_isready -U postgres"
interval     = "10s"
timeout      = "5s"
retries      = 5
start_period = "30s"

[[service]]
name        = "web"
image       = "nginx:alpine"
depends_on  = ["db"]
TOML

yml="$(mktemp --suffix=.yml)"
on_exit 'rm -f "$yml"'
"$LAB_DOCKER" export --config "$cfg" >"$yml" || fail "export failed"

# Assert on the PARSED values, not on the text that encodes them: the emitter now
# quotes every scalar (P3-2), so `grep -q 'interval: 10s'` would be testing the
# rendering rather than the artifact.
j="$(yaml_json "$yml")" || skip "no YAML reader (python3+PyYAML or a yq that supports -p yaml)"

# ── healthcheck block ───────────────────────────────────────────────────────
jq -e '.services.db.healthcheck' >/dev/null <<<"$j" || fail "healthcheck block missing"
[[ "$(jq -r '.services.db.healthcheck.test[0]' <<<"$j")" == "CMD-SHELL" ]] \
    || fail "healthcheck test is not in CMD-SHELL form"
[[ "$(jq -r '.services.db.healthcheck.test[1]' <<<"$j")" == "pg_isready -U postgres" ]] \
    || fail "healthcheck test command missing or mangled"
[[ "$(jq -r '.services.db.healthcheck.test | length' <<<"$j")" == "2" ]] \
    || fail "healthcheck test should be a 2-element flow sequence"
[[ "$(jq -r '.services.db.healthcheck.interval'     <<<"$j")" == "10s" ]] || fail "interval missing/wrong"
[[ "$(jq -r '.services.db.healthcheck.timeout'      <<<"$j")" == "5s"  ]] || fail "timeout missing/wrong"
[[ "$(jq -r '.services.db.healthcheck.retries'      <<<"$j")" == "5"   ]] || fail "retries missing/wrong"
[[ "$(jq -r '.services.db.healthcheck.start_period' <<<"$j")" == "30s" ]] || fail "start_period missing/wrong"
note "healthcheck block emitted correctly"

# ── depends_on block with condition ────────────────────────────────────────
[[ "$(jq -r '.services.web.depends_on.db.condition' <<<"$j")" == "service_healthy" ]] \
    || fail "web should depend_on db with condition service_healthy (db has a healthcheck)"
note "depends_on with service_healthy emitted correctly"

# ── no depends_on emitted for db (it has none) ─────────────────────────────
[[ "$(jq -r '.services.db.depends_on // "none"' <<<"$j")" == "none" ]] \
    || fail "db should have no depends_on block"
note "db has no spurious depends_on"

# The container_name must carry the lab prefix `up` would use — the exported file
# is a second way to run the same lab, so the names have to agree.
[[ "$(jq -r '.services.db.container_name' <<<"$j")" == "lab-hctest-db" ]] \
    || fail "exported container_name diverges from the name 'up' would create"
note "container_name matches what 'up' would create"

pass "healthcheck + depends_on export OK"
