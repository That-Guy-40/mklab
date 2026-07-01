#!/usr/bin/env bash
# fetch-go.sh — fetch a newer Go toolchain (no sudo) into $WORKDIR/go1.25.
#
# Why: the pxeboot track needs u-root *main* (not the pinned v0.14.0) — u-root
# v0.14.0's DHCP client emits no packets over QEMU slirp (fully diagnosed; see
# PLAN-PXEBOOT.md / RUNBOOK-pxeboot.md), and only main's `pxeboot -file` (which
# skips DHCP) gives us a working network boot. u-root main's go.mod requires
# Go >= 1.25, newer than the apt Go 1.22 used elsewhere in this lab. This grabs the
# official tarball and extracts it locally — the same no-sudo pattern as deps.sh's
# deb-extract, applied to go.dev/dl. (Go 1.25 is ALSO what System Transparency /
# stboot needs at P3.)
#
#   ./fetch-go.sh                 # → $WORKDIR/go1.25/bin/go
#   GOVER=1.25.7 ./fetch-go.sh    # pin a specific patch release
#
# Prints the PATH export the other scripts consume (they auto-detect $WORKDIR/go1.25).
set -euo pipefail
WORKDIR="${WORKDIR:-$HOME/linuxboot-lab}"
GOVER="${GOVER:-1.25.7}"
ARCH="${ARCH:-amd64}"
DEST="$WORKDIR/go1.25"
mkdir -p "$WORKDIR"

if [[ -x "$DEST/bin/go" ]] && "$DEST/bin/go" version 2>/dev/null | grep -q "go$GOVER"; then
  echo "==> Go $GOVER already present at $DEST"
else
  TARBALL="$WORKDIR/go$GOVER.linux-$ARCH.tar.gz"
  URL="https://go.dev/dl/go$GOVER.linux-$ARCH.tar.gz"
  echo "==> fetching $URL"
  curl -fSL -o "$TARBALL" "$URL"
  echo "==> extracting → $DEST (no sudo)"
  rm -rf "$DEST"; mkdir -p "$DEST"
  tar -C "$DEST" --strip-components=1 -xzf "$TARBALL"
fi

echo "==> $("$DEST/bin/go" version)"
echo "    Use it:  export PATH=\"$DEST/bin:\$PATH\"  GOTOOLCHAIN=local"
echo "    (build-coreboot.sh auto-uses \$WORKDIR/go1.25 when building u-root main.)"
