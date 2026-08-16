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

tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
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
ports       = ["18097:80", "0.0.0.0:18096:81"]
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
grep -q '^  "db":'          <<<"$out" || fail "missing service 'db' (service names now quoted as YAML keys)"
grep -q '^  "web":'         <<<"$out" || fail "missing service 'web'"
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
# Review F4 (REOPENED 2026-08-16 by REVIEW-phase3.md P3-1): the exported compose
# file is a publish site — it exists to be run — so a BARE host:container spec must
# carry the loopback default, exactly as the quadlet's PublishPort= and every `run`
# path do.  Before this, the same spec bound 127.0.0.1 through `up` and 0.0.0.0
# (plus [::]) through the artifact, and AUDIT.md's F4 row claimed "every publish
# site routes through it".
grep -q '"127\.0\.0\.1:18097:80"' <<<"$out" \
    || fail "REGRESSION: web: a bare published port was exported without the F4 loopback default; got: $(grep -A1 'ports:' <<<"$out")"
# Control: an explicitly-bound port is the opt-in to a wider bind and must be left
# alone — the fix must not rewrite what the author already decided.
grep -q '"0\.0\.0\.0:18096:81"' <<<"$out" \
    || fail "an explicit 0.0.0.0 bind was rewritten; explicit binds are the opt-in and must round-trip unchanged"
note "ports present, with the F4 loopback default applied only to the bare form"

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
grep -q '"front":'          <<<"$out" || fail "missing network 'front' (network names now quoted as YAML keys)"
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
# This block used to end in `|| note "(soft-failed — inspect manually)"`, which made
# it an assertion that could not fail: a compose file the parser REJECTED printed a
# friendly note and the test passed.  An all-PASS result is indistinguishable from one
# that checks nothing.  Either compose validates the artifact, or the test says why it
# could not check — never "checked and shrugged".
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    tmp_yml="$tmp/out.yml"
    "$LAB_PODMAN" export "$lab" --format compose > "$tmp_yml" \
        || fail "export --format compose failed when re-run for schema validation"
    cfg_err="$(docker compose -f "$tmp_yml" config --quiet 2>&1)" \
        || fail "the exported compose file is not valid compose: $cfg_err"
    note "docker compose config validated the exported file"
else
    note "UNKNOWN: docker compose not present — the exported file was NOT schema-validated"
fi

pass "compose export OK (image, container_name, ports, env, volumes, command, healthcheck, depends_on)"
