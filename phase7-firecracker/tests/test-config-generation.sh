#!/usr/bin/env bash
# §5.4's generator assertions -- run only where a real boot could happen, because the
# generator refuses to emit a config for a spec whose gates fail (which is the point).
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd firecracker file python3
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "/dev/kvm not read-write for uid $EUID"

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
K="${FC_TEST_KERNEL:-}"; R="${FC_TEST_ROOTFS:-}"
[[ -r "$K" && -r "$R" ]] || skip "set FC_TEST_KERNEL and FC_TEST_ROOTFS to an ELF vmlinux and an ext4 image"

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
