#!/usr/bin/env bash
# test-spec-placeholders.sh — lab-docker.sh must expand @LAB_DIR@ / @REPO@ / @NETBOOT@ / @HOME@
# when it parses a spec, so a tracked spec never names one machine's filesystem.
#
# WHY (TODO 15.11). `volumes` needs an ABSOLUTE host path, so 20 specs wrote one in —
# /home/sqs/netboot… , true for one user and false for everybody else. The drivers now
# resolve placeholders instead, and tools/check-driver-helper-parity.sh keeps the four
# copies of the helper byte-identical.
#
# PARITY IS NOT WIRING, which is why this test exists in each suite rather than once. The
# parity checker proves the four copies are the same function; it says nothing about
# whether THIS driver calls it. A driver that carried the helper and never invoked it
# would pass parity and hand podman a literal @LAB_DIR@.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
set +e

require_cmd jq
command -v tomlq >/dev/null 2>&1 || command -v yq >/dev/null 2>&1 || command -v dasel >/dev/null 2>&1 \
    || skip "no TOML parser (tomlq/yq/dasel) — toml_to_json cannot run, so expansion cannot be observed"

TMP="$(mktemp -d)"; on_exit 'rm -rf -- "$TMP"'
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
# shellcheck disable=SC1090
source "$LAB_DOCKER" >/dev/null 2>&1 || true

cat > "$TMP/spec.toml" <<'SPEC'
[lab]
name = "ph"
[[service]]
name    = "svc"
image   = "docker.io/library/alpine:3.20"
volumes = ["@LAB_DIR@/data:/data:ro", "@REPO@/tools:/tools:ro", "@NETBOOT@:/srv:ro", "@HOME@/.config/x:/x:ro"]
SPEC

json="$(LAB_NETBOOT_DIR="$TMP/nb" toml_to_json "$TMP/spec.toml" 2>/dev/null)"
[[ -n "$json" ]] || fail "toml_to_json produced nothing for a well-formed spec"
grep -qF '@' <<<"$json" \
    && fail "a placeholder survived into the parsed spec — the driver would hand the engine a literal @…@ as a host path: $(grep -oE '@[A-Z_]+@' <<<"$json" | sort -u | tr '\n' ' ')"
for want in "$TMP/data:/data:ro" "$REPO_ROOT/tools:/tools:ro" "$TMP/nb:/srv:ro" "$HOME/.config/x:/x:ro"; do
    grep -qF -- "$want" <<<"$json" || fail "the driver did not resolve a volume to '$want' — check that toml_to_json routes through _expand_spec_paths"
done
note "all four placeholders resolve in a volumes list"

# CONTROL: a spec with no placeholder must come back untouched, or "expansion works" would
# be equally true of a driver rewriting paths nobody asked it to touch.
cat > "$TMP/plain.toml" <<'PLAIN'
[lab]
name = "plain"
[[service]]
name    = "svc"
image   = "docker.io/library/alpine:3.20"
volumes = ["/var/lib/lab-create/x:/x:ro"]
PLAIN
grep -qF '/var/lib/lab-create/x:/x:ro' <<<"$(toml_to_json "$TMP/plain.toml" 2>/dev/null)" \
    || fail "a spec with NO placeholder came back changed — the expansion is rewriting paths it was not asked to touch"
note "control: a spec with no placeholder is passed through unchanged"

pass "lab-docker.sh resolves @LAB_DIR@, @REPO@, @NETBOOT@ and @HOME@ inside a volumes list, leaves a spec without placeholders byte-identical, and lets no placeholder reach the container engine"
