#!/usr/bin/env bash
# Unit test: build_qemu_argv honors the v0.2 CPU-topology + network-mode knobs
# (no QEMU launched).  Sources lab-vm.sh via its guard and inspects QEMU_ARGV.

# render() sets globals consumed by the sourced build_qemu_argv (dynamic scope),
# and $LAB_VM is a dynamic source path — both are false positives here.
# shellcheck disable=SC1090,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd qemu-system-x86_64 jq

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export LAB_STATE_DIR="$tmp/state" LAB_CACHE_DIR="$tmp/cache"

source "$LAB_VM"

render() {
    name=t arch=x86_64 microvm=false accel=tcg memory=512M cpus="$1" \
        cores="$2" threads="$3" cpu_pin="" disk="" install_target="" seed="" \
        mac="" kernel=/k initrd=/i append="" ssh_port=2222 firmware="" \
        network_mode="$4" bridge="$5" tap="$6"
    build_qemu_argv
    printf '%s' "${QEMU_ARGV[*]}"
}
has() { grep -Fq -- "$2" <<<"$1"; }

# CPU topology
has "$(render 4 2 2 user '' '')" '-smp 4,cores=2,threads=2' || fail "cores+threads → -smp topology"
has "$(render 2 0 0 user '' '')" '-smp 2'                    || fail "no topology → plain -smp N"
if has "$(render 2 0 0 user '' '')" 'cores='; then fail "plain -smp must not carry a topology"; fi
note "SMP topology vs plain OK"

# Network modes
has "$(render 2 0 0 user '' '')"      '-netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22' || fail "user-mode netdev"
has "$(render 2 0 0 bridge br0 '')"   '-netdev bridge,id=net0,br=br0'                       || fail "bridge netdev"
has "$(render 2 0 0 tap '' tap9)"     '-netdev tap,id=net0,ifname=tap9,script=no,downscript=no' || fail "tap netdev (named)"
has "$(render 2 0 0 tap '' '')"       '-netdev tap,id=net0,script=no'                       || fail "tap netdev (auto ifname)"
# default bridge name when unset
has "$(render 2 0 0 bridge '' '')"    '-netdev bridge,id=net0,br=virbr0'                    || fail "bridge default br=virbr0"
note "network modes user/bridge/tap OK"

# Regression: a vanilla VM is still user-mode + plain smp + virtio-net device.
a="$(render 2 0 0 user '' '')"
has "$a" 'virtio-net-pci,netdev=net0' || fail "NIC device still attached"
note "vanilla regression OK"

pass "build_qemu_argv CPU-topology + network-mode OK"
