#!/usr/bin/env bash
# serve-netboot.sh — bring up (or tear down) the :8181 nginx netboot server that
# u-root `pxeboot` fetches the installer kernel/initrd (and kickstart/preseed) from.
#
# Reuses the repo's rootless netboot server verbatim: examples/podman-netboot-server.toml
# (nginx:alpine, ~/netboot → :8181, no sudo). The iPXE *script* itself
# (boot-<os>.ipxe) is handed to the guest by QEMU's built-in slirp TFTP in
# run-coreboot-pxe.sh; this server carries the big HTTP artifacts.
#
#   ./serve-netboot.sh [up|down|status]
#
# --tls (P2/P3) will serve HTTPS with a cert issued by examples/lab-ca/ — see
# PLAN-PXEBOOT.md §6b. Not wired yet (P1 is plain HTTP).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TOML="$REPO/examples/podman-netboot-server.toml"
LP="$REPO/phase4-podman/lab-podman.sh"

case "${1:-up}" in
  up)
    echo "==> bringing up :8181 netboot server (reuses podman-netboot-server.toml)"
    "$LP" up --config "$TOML"
    sleep 1
    curl -fsI http://127.0.0.1:8181/vmlinuz >/dev/null 2>&1 \
      && echo "==> :8181 serving ~/netboot" || echo "warn: :8181 not answering yet"
    ;;
  down)   "$LP" down --config "$TOML" ;;
  status) curl -fsI http://127.0.0.1:8181/vmlinuz >/dev/null 2>&1 \
            && echo ":8181 up" || { echo ":8181 not serving"; exit 1; } ;;
  *) echo "usage: $0 [up|down|status]" >&2; exit 1 ;;
esac
