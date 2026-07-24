#!/usr/bin/env bash
# demo-cdn-state.sh — PROVE the cdn-edge state model (mechanic ③): the OS is
# ephemeral, but the ZFS-backed cache PERSISTS across a reboot. Warm the cache
# in edge A, "reboot" (a fresh throwaway OS = edge B), and have edge B serve the
# SAME cached content over HTTP — content it never fetched, only imported.
#
# Self-contained: rootful docker --privileged + the host's live /dev/zfs
# (world-rw, module 2.2.2). NO sudo, NO QEMU. The pool lives on a file-backed
# loop vdev in this dir; unique name + always export/destroy → no host pool left.
# One verdict (house rule).
#
# HONEST SCOPE: this proves the ephemeral-OS + durable-ZFS-state split and that
# the edge serves survivor content. It is NOT a real CDN (no origin pull, no
# cache eviction, no geo-steering) — the point is the state model.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG=cdn-edge-ram
POOL=cdnedge
VDEV="$HERE/.vdev.img"
MARK="cached at the edge BEFORE the reboot"

skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

run() { docker run --rm --privileged -v /dev:/dev -v "$HERE:/work" "$IMG" bash -c "$1"; }

cleanup() {
    run 'zpool destroy '"$POOL"' 2>/dev/null; zpool export '"$POOL"' 2>/dev/null;
         for l in $(losetup -j /work/.vdev.img -O NAME -n 2>/dev/null); do losetup -d "$l"; done; true' >/dev/null 2>&1 || true
    rm -f "$VDEV" "$HERE/.asset.sha"
}
trap 'rc=$?; cleanup; [[ $rc == 0 || $rc == 77 || $rc == 1 ]] || \
      printf "FAIL: demo exited early (rc=%s)\n" "$rc" >&2' EXIT

command -v docker >/dev/null 2>&1 || skip "docker not available"
docker info >/dev/null 2>&1 || skip "docker daemon not running"
[[ -e /dev/zfs ]] || skip "/dev/zfs absent (ZFS kernel module not loaded on host)"

if ! docker image inspect "$IMG" >/dev/null 2>&1; then
    note "building image $IMG (first run)"
    docker build -t "$IMG" -f "$HERE/Containerfile" "$HERE" >/dev/null 2>&1 \
        || fail "docker build failed for $IMG"
fi

rm -f "$VDEV"; truncate -s 200M "$VDEV" || fail "could not create the file vdev"

# ── edge A: warm the cache onto the ZFS pool, then export ────────────────────
run '
  set -e
  lo=$(losetup --find --show /work/.vdev.img)        # loop vdev (host-visible)
  zpool create -f -m /work/mnt '"$POOL"' "$lo"
  mkdir -p /work/mnt/cache
  printf "%s\n" "'"$MARK"'" > /work/mnt/cache/index.html
  dd if=/dev/urandom of=/work/mnt/cache/asset.bin bs=1M count=8 status=none
  sha256sum /work/mnt/cache/asset.bin | awk "{print \$1}" > /work/.asset.sha
  sync; zpool export '"$POOL"'; losetup -d "$lo"
' || fail "edge A could not warm the cache"
note "edge A: warmed the ZFS cache (index.html + 8 MiB asset), exported the pool"

# ── edge B: FRESH OS (rebooted). Import the pool, serve it over HTTP ─────────
out="$(run '
  set -e
  lo=$(losetup --find --show /work/.vdev.img)          # different loopN; import by LABEL
  zpool import -d /dev -R /work/altroot '"$POOL"'
  cache=/work/altroot/work/mnt/cache
  rm -rf /var/www/html && ln -s "$cache" /var/www/html
  nginx
  sleep 1
  echo "HTTP-INDEX: $(curl -s http://127.0.0.1/index.html)"
  echo "HTTP-ASSET-SHA: $(curl -s http://127.0.0.1/asset.bin | sha256sum | awk "{print \$1}")"
  echo "EXPECT-ASSET-SHA: $(cat /work/.asset.sha)"
  nginx -s stop 2>/dev/null || true
  zpool export '"$POOL"'; losetup -d "$lo"
')" || fail "edge B could not import + serve the pool"
echo "$out" | sed 's/^/    /' >&2

grep -q "$MARK" <<<"$out" \
    || fail "REGRESSION: edge B did not serve the pre-reboot cached index.html"
a_got="$(sed -n 's/^HTTP-ASSET-SHA: //p'   <<<"$out")"
a_exp="$(sed -n 's/^EXPECT-ASSET-SHA: //p' <<<"$out")"
[[ -n "$a_got" && "$a_got" == "$a_exp" ]] \
    || fail "REGRESSION: served asset sha ($a_got) != pre-reboot asset sha ($a_exp)"
note "edge B: served the surviving cache over HTTP (index text + 8 MiB asset sha match)"

pass "cdn-edge: ZFS-backed cache survived the ephemeral-OS reboot and was served by a fresh edge over HTTP"
