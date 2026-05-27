#!/usr/bin/env bash
# Unit test: every micro-linux kernel is built microvm-capable (virtio-mmio), so
# one kernel boots on q35/virt AND on QEMU's microvm machine.
#
#  (1) Behavioral — set_kconfig flips CONFIG_VIRTIO_MMIO on even when defconfig
#      already wrote "# CONFIG_VIRTIO_MMIO is not set".  This is the same
#      silent-drop trap that bit CONFIG_STATIC: a bare append would be dropped by
#      oldconfig's keep-first reassign, leaving a PCI-only (microvm-incapable)
#      kernel.  Tested against a fake .config — no kernel compile.
#  (2) Wiring — build_kernel actually SETS and ASSERTS CONFIG_VIRTIO_MMIO, so a
#      future edit that drops either fails the real build loudly.
# Network-free.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export MLBUILD_OUT_DIR="$tmp/out"        # keep any destructive op off the real tree
# shellcheck disable=SC1090
source "$MLBUILD"                        # mlbuild.sh is source-safe (see its header)

# ── (1) set_kconfig replaces the defconfig "is not set" line cleanly ────────
cfg="$tmp/.config"
cat >"$cfg" <<'CFG'
CONFIG_VIRTIO=y
# CONFIG_VIRTIO_MMIO is not set
CONFIG_VIRTIO_PCI=y
# CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES is not set
CFG
set_kconfig "$cfg" VIRTIO_MMIO y
set_kconfig "$cfg" VIRTIO_MMIO_CMDLINE_DEVICES y

grep -qx 'CONFIG_VIRTIO_MMIO=y' "$cfg" \
    || fail "set_kconfig did not enable CONFIG_VIRTIO_MMIO"
grep -qx 'CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y' "$cfg" \
    || fail "set_kconfig did not enable CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES"
if grep -q '# CONFIG_VIRTIO_MMIO is not set' "$cfg"; then
    fail "stale '# CONFIG_VIRTIO_MMIO is not set' survived — kernel would be PCI-only"
fi
[[ "$(grep -c '^CONFIG_VIRTIO_MMIO=' "$cfg")" == 1 ]] \
    || fail "CONFIG_VIRTIO_MMIO defined more than once (the reassign trap)"
# VIRTIO_PCI must be untouched: the kernel stays universal (PCI + MMIO).
grep -qx 'CONFIG_VIRTIO_PCI=y' "$cfg" || fail "set_kconfig clobbered CONFIG_VIRTIO_PCI"
note "set_kconfig flips VIRTIO_MMIO on cleanly, leaves VIRTIO_PCI intact"

# ── (2) build_kernel is wired to both set and assert VIRTIO_MMIO ────────────
bk="$(sed -n '/^build_kernel()/,/^}/p' "$MLBUILD")"
[[ -n "$bk" ]] || fail "could not extract build_kernel() from mlbuild.sh"
grep -q 'set_kconfig .* VIRTIO_MMIO y' <<<"$bk" \
    || fail "build_kernel no longer sets VIRTIO_MMIO — kernels would lose microvm support"
grep -qE 'want=\(.*CONFIG_VIRTIO_MMIO' <<<"$bk" \
    || fail "build_kernel no longer asserts CONFIG_VIRTIO_MMIO — a silent drop could ship"
note "build_kernel sets and asserts CONFIG_VIRTIO_MMIO"

pass "kernel is built microvm-capable (virtio-mmio set + asserted, PCI retained)"
