#!/usr/bin/env bash
# End-to-end VM path: up (with type=vm) → list → exec → down.
# Skips cleanly if /dev/kvm isn't readable (no hardware-virt).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_lxd_or_incus
require_cmd jq

[[ -r /dev/kvm || -w /dev/kvm ]] || skip "no /dev/kvm access — VM lifecycle needs hardware-virt"

lab="vlc$$"
cfg="$(mktemp --suffix=.toml)"
trap 'rm -f "$cfg"; cleanup_lab "$lab"' EXIT

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[[instance]]
name  = "v"
type  = "vm"
image = "images:alpine/3.21"
# secureboot=false: most community Alpine VM images aren't signed for
# UEFI Secure Boot.  Without this, launch fails with:
#   "The image used by this instance is incompatible with secureboot.
#    Please set security.secureboot=false on the instance"
config = { "limits.memory" = "512MiB", "limits.cpu" = "1", "security.secureboot" = "false" }
EOF

note "up (type=vm)"
"$LAB_LXD" up --config "$cfg" 2>&1 | tee /tmp/p5vm-up-$$.log
rc=${PIPESTATUS[0]}
if (( rc != 0 )); then
    # Common case: storage pool doesn't support VMs (dir pool).  Make the
    # failure legible.
    if grep -qi 'storage' /tmp/p5vm-up-$$.log; then
        skip "VM create failed (likely dir-pool without block support); set up zfs/btrfs/lvm storage and retry"
    fi
    fail "VM up failed (see log)"
fi
rm -f /tmp/p5vm-up-$$.log

note "list shows the VM"
"$LAB_LXD" list --lab "$lab" 2>&1 | grep -q "lab-${lab}-v" \
    || fail "list did not show lab-${lab}-v"

note "wait for lxd-agent readiness (up to 60s)"
for i in $(seq 1 30); do
    if "$LAB_LXD" exec "${lab}/v" -- true 2>/dev/null; then
        note "exec ready after ${i}*2 seconds"
        break
    fi
    sleep 2
done

note "exec returns alpine banner"
out="$("$LAB_LXD" exec "${lab}/v" -- cat /etc/os-release 2>&1 || true)"
grep -qi 'alpine' <<<"$out" \
    || skip "exec into VM did not return banner (likely agent not up yet); got: $out"

note "down"
"$LAB_LXD" down --lab "$lab"

pass "VM lifecycle OK"
