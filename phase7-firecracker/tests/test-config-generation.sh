#!/usr/bin/env bash
# §5.4's generator assertions.
#
# This test never boots anything — it runs `create --dry-run` and parses stdout — but it
# used to demand a real Firecracker and two caller-supplied artifacts, so it SKIPPED on
# every run, here and in CI, since the phase was written. `fc_fixtures` builds what it
# actually needs; see lib.sh for what the stand-in does and does not prove.
#
# To be exact about what its absence cost: this file's `json.load` would NOT have caught
# P7-2, because the spec here is benign and a benign spec produces valid JSON with or
# without escaping. What its absence meant is that no test in the phase had ever parsed a
# generated config at all — which is why nobody looked at how one was built. The escaping
# itself is asserted by test-config-json-escaping.sh, on hostile scalars.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
fc_fixtures; K="$FC_K"; R="$FC_R"

run_fc "$tmp/out" create --dry-run --name t1 --kernel "$K" --rootfs "$R" --memory 128M \
    || { cat "$tmp/out" >&2; fail "create --dry-run refused a spec built from the caller's own good artifacts"; }
sed -n '/^{/,/^}/p' "$tmp/out" > "$tmp/cfg.json"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp/cfg.json" \
    || fail "generated config.json is not valid JSON"

python3 - "$tmp/cfg.json" <<'PY' || exit 1
import json,sys
c=json.load(open(sys.argv[1])); a=c["boot-source"]["boot_args"]
roots=[d for d in c["drives"] if d.get("is_root_device")]
assert len(roots)==1, f"expected exactly one root drive, got {len(roots)}"
for tok in ("reboot=k","panic=1","console=ttyS0"):
    assert tok in a, f"missing {tok} in boot_args"
assert "root=" not in a, "generator emitted a root= — Firecracker appends its own and the kernel honours the last (plan E.4)"
assert c["machine-config"]["smt"] is False
assert "network-interfaces" not in c, "no tap was configured, so no NIC block should exist"
print("  - one root drive; reboot=k panic=1 console=ttyS0 present; no root=; no NIC block")
PY

grep -q 'WHAT THIS TOOL DID THAT YOU DID NOT TYPE' "$tmp/out" \
    || fail "create --dry-run did not print the provenance table — the slice-4 deliverable is missing"
grep -q '^  APPENDED .*root=/dev/vda' "$tmp/out" \
    || fail "provenance does not name Firecracker's appended root= — the one field the user cannot control"
note "provenance table present and names the appended root="

pass "generated config satisfies §5.4 and reports the provenance of every field it added"
