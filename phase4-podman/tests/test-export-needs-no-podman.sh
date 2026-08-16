#!/usr/bin/env bash
# `export` must not consult podman on the two paths that do not use it — and must
# still consult it on the one that does.
#
# THE DEFECT THIS GUARDS. `cmd_export` ran `require_rootless` + `require_podman`
# ABOVE its `case "$fmt"`, so both gates fired before the format was ever looked at.
# Two consequences, both wrong, and neither visible where CI runs:
#
#   1. `export mylab --format bogus` answered **"podman not found"** on a host
#      without podman. The tool blamed the machine for the operator's typo. Every
#      other subcommand validates first — 13 sibling usage assertions pass fine on
#      the same podman-less run; `export` was the only one that did not.
#   2. `--format compose` NEVER CALLS PODMAN AT ALL. It reads the stored spec.toml
#      and prints YAML — a pure text transformation, gated on a container engine
#      and on being non-root. `test-compose-export.sh` has said "no live podman
#      needed" in its header since it was written; the code disagreed.
#
# Recorded as TODO.md item 8 from a 2026-08-03 health pass on a minimal container.
#
# WHY THIS TEST EXISTS WHEN test-validation.sh ALREADY ASSERTS THE MESSAGE.
# It does — and it is INERT wherever CI runs it. `expect_error "export bogus format"`
# only distinguishes the fixed code from the broken code on a host that HAS NO
# PODMAN. GitHub's runners ship podman, so that assertion passed identically before
# and after the fix and would never have caught the regression coming back. An
# assertion that cannot fail is not a guard. This one makes podman-presence
# OBSERVABLE instead of environmental, so it bites on every host.
#
# HOW. Run a copy of the tool with both gate functions replaced by tripwires that
# exit 9 by name. Then the question "did this path consult podman?" has a direct,
# recorded answer rather than depending on what happens to be installed.
#
# THE TWO CONTROLS, because a tripwire that is not wired proves nothing and a fix
# that deletes the gates outright would also pass a one-sided test:
#   - `logs` MUST trip it   (a subcommand that genuinely needs podman)
#   - `--format kube` MUST trip it (it really does call `podman kube generate`)
# If either stops tripping, this test fails — the fix went too far.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd sed jq

tmp="$(mktemp -d)"
on_exit 'rm -rf "$tmp"'

# ── the instrumented copy: same code, gates that announce themselves ────────
TW="$tmp/lab-podman-tripwire.sh"
sed -e 's|^require_rootless() {|require_rootless() { printf "TRIPWIRE require_rootless\\n" >\&2; exit 9;|' \
    -e 's|^require_podman() {|require_podman() { printf "TRIPWIRE require_podman\\n" >\&2; exit 9;|' \
    "$LAB_PODMAN" > "$TW"
chmod +x "$TW"
n_tw="$(grep -c 'TRIPWIRE' "$TW" || true)"
(( n_tw == 2 )) \
    || fail "expected to inject 2 tripwires, injected $n_tw — the gate functions were renamed or reshaped, so this test is no longer measuring what it claims"

# A lab whose spec.toml exists, so the compose path has something to render.
LAB="expo$$"
export LAB_STATE_DIR="$tmp/state"
mkdir -p "$LAB_STATE_DIR/podman/$LAB"
cat > "$LAB_STATE_DIR/podman/$LAB/spec.toml" <<TOML
[lab]
name = "$LAB"

[[service]]
name  = "web"
image = "nginx:alpine"
ports = ["18099:80"]
TOML

# run_tw <args...> — returns rc and leaves combined output in $TW_OUT.
TW_OUT=""
run_tw() {
    local rc
    if TW_OUT="$("$TW" "$@" 2>&1)"; then rc=0; else rc=$?; fi
    return "$rc"
}

# ── control A: the tripwire is live ────────────────────────────────────────
# Without this, every "did not trip" assertion below could be passing because the
# tripwire was never wired — the shape of green that proves nothing.
if run_tw logs somecontainer; then
    fail "'logs' exited 0 under the tripwire — it must consult a gate, so the tripwire is not wired and nothing below this line means anything"
fi
grep -q '^TRIPWIRE ' <<<"$TW_OUT" \
    || fail "'logs' did not trip the gate tripwire (got: ${TW_OUT//$'\n'/ }) — the tripwire is not wired, so this test cannot distinguish the fix from the defect"
note "control: the tripwire is live — 'logs' trips it, as a podman-needing subcommand must"

# ── control B: kube is still gated ─────────────────────────────────────────
# Deleting the gates entirely would satisfy assertions 1 and 2. It must not.
if run_tw export "$LAB" --format kube; then
    fail "'export --format kube' exited 0 without consulting podman — kube runs 'podman kube generate' and MUST still be gated; the fix removed a gate it should have kept"
fi
grep -q '^TRIPWIRE ' <<<"$TW_OUT" \
    || fail "'export --format kube' did not trip the gate tripwire (got: ${TW_OUT//$'\n'/ }) — kube genuinely needs podman and must still refuse without it"
note "control: '--format kube' still trips the gate — the podman-needing path kept its gate"

# ── 1. a usage error is diagnosable with no podman ─────────────────────────
if run_tw export "$LAB" --format bogus; then
    fail "'export --format bogus' exited 0 — an unknown format must be refused"
fi
if grep -q '^TRIPWIRE ' <<<"$TW_OUT"; then
    fail "REGRESSION: 'export --format bogus' consulted a host gate before validating its arguments (${TW_OUT//$'\n'/ }) — on a podman-less host the tool answers a typo with 'podman not found', blaming the machine for the operator's mistake"
fi
grep -qi 'unknown export format' <<<"$TW_OUT" \
    || fail "REGRESSION: 'export --format bogus' refused, but not by naming the format: ${TW_OUT//$'\n'/ }"
note "usage: an unknown --format is refused by name, with no host gate consulted"

# ── 2. compose export works with neither podman nor the root gate ──────────
run_tw export "$LAB" --format compose \
    || fail "REGRESSION: 'export --format compose' exited non-zero with the gates tripwired (${TW_OUT//$'\n'/ }) — compose reads spec.toml and prints YAML; it calls podman nowhere and must not require one"
if grep -q '^TRIPWIRE ' <<<"$TW_OUT"; then
    fail "REGRESSION: 'export --format compose' consulted a host gate (${TW_OUT//$'\n'/ }) — it never calls podman, so gating it on podman (or on being non-root) is a check that cannot fail for a real reason"
fi
# And it must have actually rendered, not merely exited 0 quietly.
grep -q '^services:' <<<"$TW_OUT" \
    || fail "'export --format compose' exited 0 but emitted no 'services:' block — a silent success is not a success: ${TW_OUT//$'\n'/ }"
# Parsed, not grepped: the emitter quotes container_name now (P4-5), and this
# assertion is about WHICH service was rendered, not how the value is spelled.
printf '%s\n' "$TW_OUT" > "$tmp/tw.yml"
twj="$(yaml_json "$tmp/tw.yml")" || skip "no YAML reader to verify the rendered export"
[[ "$(jq -r '.services.web.container_name' <<<"$twj")" == "lab-${LAB}-web" ]] \
    || fail "'export --format compose' emitted YAML without the expected service — it did not read the spec.toml it was given"
note "compose: renders the full spec with no podman and no rootless gate"

pass "export consults podman only where it uses it — usage errors and compose render on a podman-less host, while kube keeps its gate"
