#!/usr/bin/env bash
# Unit test: healthcheck and depends_on are correctly emitted in compose export.
# No docker run needed — only export (which is pure template rendering).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

# Need a TOML parser.
if ! command -v tomlq >/dev/null 2>&1 \
   && ! command -v dasel >/dev/null 2>&1 \
   && ! ( command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah ); then
    skip "no TOML parser (need yq/tomlq/dasel)"
fi

cfg="$(mktemp --suffix=.toml)"
trap 'rm -f "$cfg"' EXIT

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

out="$("$LAB_DOCKER" export --config "$cfg")"

# ── healthcheck block ───────────────────────────────────────────────────────
grep -q '    healthcheck:'          <<<"$out" || fail "healthcheck: block missing"
grep -q 'CMD-SHELL'                 <<<"$out" || fail "CMD-SHELL prefix missing"
grep -q 'pg_isready'                <<<"$out" || fail "healthcheck test command missing"
grep -q 'interval: 10s'             <<<"$out" || fail "interval missing"
grep -q 'timeout: 5s'               <<<"$out" || fail "timeout missing"
grep -q 'retries: 5'                <<<"$out" || fail "retries missing"
grep -q 'start_period: 30s'         <<<"$out" || fail "start_period missing"
note "healthcheck block emitted correctly"

# ── depends_on block with condition ────────────────────────────────────────
grep -q '    depends_on:'           <<<"$out" || fail "depends_on: block missing"
grep -q '      db:'                 <<<"$out" || fail "depends_on: db entry missing"
grep -q 'condition: service_healthy' <<<"$out" || fail "condition should be service_healthy (db has healthcheck)"
note "depends_on with service_healthy emitted correctly"

# ── no depends_on emitted for db (it has none) ─────────────────────────────
# The depends_on block belongs under 'web:' — verify it is NOT under 'db:'.
# Extract the 'db:' service block (lines between 'db:' and the next top-level
# service or end of services section) and assert no depends_on there.
db_section="$(awk '/^  db:/{p=1} p && /^  [a-z]/ && !/^  db:/{p=0} p' <<<"$out")"
if grep -q 'depends_on' <<<"$db_section"; then
    fail "db should have no depends_on block; got:\n$db_section"
fi
note "db has no spurious depends_on"

pass "healthcheck + depends_on export OK"
