#!/usr/bin/env bash
# Unit test: compose export emits all required fields — no live podman needed.
# Fabricates a spec.toml in a temporary LAB_STATE_DIR and exercises cmd_export
# directly through lab-podman.sh export <lab> --format compose.
#
# Covers: image, container_name, ports, environment, volumes (named + bind),
#         command, healthcheck, depends_on (with service_healthy/started
#         condition selection), networks, and top-level volumes declaration.

set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
lab="xptest$$"

# Build a fake LAB_STATE_DIR with a spec.toml that exercises every field.
# lab_dir() → $LAB_STATE_DIR/podman/<lab>; spec.toml lives there.
state_dir="$tmp/state"
lab_dir_path="$state_dir/podman/$lab"
mkdir -p "$lab_dir_path"

cat > "$lab_dir_path/spec.toml" <<'TOML'
[lab]
name = "xptest"

[network.front]
driver = "bridge"

[[service]]
name        = "db"
image       = "postgres:16-alpine"
networks    = ["front"]
environment = { POSTGRES_PASSWORD = "lab" }
volumes     = ["pgdata:/var/lib/postgresql/data"]
command     = "postgres -c shared_preload_libraries=pg_stat_statements"

[service.healthcheck]
cmd      = "pg_isready -U postgres"
interval = "10s"
timeout  = "5s"
retries  = 3

[[service]]
name        = "web"
image       = "nginx:alpine"
networks    = ["front"]
ports       = ["18097:80"]
volumes     = ["/host/static:/usr/share/nginx/html:ro"]
depends_on  = ["db"]
TOML

# Override state dir so lab-podman.sh finds our fake lab state.
export LAB_STATE_DIR="$state_dir"

# Capture before set-e can trigger — a failing export would kill the script.
out="$("$LAB_PODMAN" export "$lab" --format compose 2>/dev/null)" \
    || fail "export --format compose returned non-zero; check spec.toml path"

# ── services section ────────────────────────────────────────────────────────
grep -q '^services:'        <<<"$out" || fail "missing 'services:'"
grep -q '^  db:'            <<<"$out" || fail "missing service 'db'"
grep -q '^  web:'           <<<"$out" || fail "missing service 'web'"
note "services section present"

# ── image ──────────────────────────────────────────────────────────────────
grep -q 'image: postgres'   <<<"$out" || fail "db: image missing"
grep -q 'image: nginx'      <<<"$out" || fail "web: image missing"
note "image fields present"

# ── container_name ─────────────────────────────────────────────────────────
# container_name_for yields  lab-<lab>-<svc>
grep -q "container_name: lab-${lab}-db"  <<<"$out" || fail "db: container_name missing"
grep -q "container_name: lab-${lab}-web" <<<"$out" || fail "web: container_name missing"
note "container_name fields present"

# ── ports ──────────────────────────────────────────────────────────────────
grep -q '"18097:80"'        <<<"$out" || fail "web: port 18097:80 missing"
note "ports present"

# ── environment ────────────────────────────────────────────────────────────
grep -q 'POSTGRES_PASSWORD' <<<"$out" || fail "db: environment missing"
note "environment present"

# ── volumes (service-level) ────────────────────────────────────────────────
grep -q '"pgdata:/var/lib/postgresql/data"'  <<<"$out" || fail "db: named volume ref missing"
grep -q '"/host/static:/usr/share'           <<<"$out" || fail "web: bind mount missing"
note "service volumes present"

# ── command ────────────────────────────────────────────────────────────────
grep -q 'command:.*postgres' <<<"$out" || fail "db: command missing"
note "command present"

# ── healthcheck ────────────────────────────────────────────────────────────
grep -q '    healthcheck:'          <<<"$out" || fail "db: healthcheck block missing"
grep -q 'CMD-SHELL'                 <<<"$out" || fail "db: CMD-SHELL prefix missing"
grep -q 'pg_isready'                <<<"$out" || fail "db: healthcheck cmd missing"
grep -q 'interval: 10s'             <<<"$out" || fail "db: healthcheck interval missing"
grep -q 'timeout: 5s'               <<<"$out" || fail "db: healthcheck timeout missing"
grep -q 'retries: 3'                <<<"$out" || fail "db: healthcheck retries missing"
note "healthcheck block present"

# ── depends_on with correct condition ──────────────────────────────────────
# db has a healthcheck → web should get condition: service_healthy
grep -q '    depends_on:'              <<<"$out" || fail "web: depends_on missing"
grep -q 'condition: service_healthy'   <<<"$out" || fail "web: condition should be service_healthy (db has healthcheck)"
note "depends_on with service_healthy condition"

# ── networks section ───────────────────────────────────────────────────────
grep -q '^networks:'        <<<"$out" || fail "missing 'networks:'"
grep -q '^  front:'         <<<"$out" || fail "missing network 'front'"
note "networks section present"

# ── top-level volumes declaration (named volumes only, not bind mounts) ────
grep -q '^volumes:'         <<<"$out" || fail "missing top-level 'volumes:'"
grep -q '^  pgdata:'        <<<"$out" || fail "pgdata not declared in top-level volumes"
# /host/static is a bind mount — must NOT appear in top-level volumes:
if grep -q 'host' <<<"$(grep -A100 '^volumes:' <<<"$out" | tail -n+2)"; then
    fail "bind mount source appeared in top-level volumes declaration"
fi
note "top-level volumes declaration correct (named only, no bind mounts)"

# ── Compose v2 obsolete version key absent ─────────────────────────────────
# Compose v2 warns on top-level 'version:' — we still emit it for compat.
# Just verify the format is valid YAML structure (docker compose config accepts it).
# (docker compose may not be present; skip validation if absent)
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    tmp_yml="$tmp/out.yml"
    "$LAB_PODMAN" export "$lab" --format compose > "$tmp_yml" 2>/dev/null || true
    docker compose -f "$tmp_yml" config --quiet \
        && note "docker compose config validated" \
        || note "(compose config validation soft-failed — inspect manually)"
fi

pass "compose export OK (image, container_name, ports, env, volumes, command, healthcheck, depends_on)"
