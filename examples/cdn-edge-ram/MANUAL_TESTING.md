# cdn-edge-ram — Manual Testing

## Part 1 — ZFS cache survives an ephemeral-OS reboot  ✅ verified (docker + host ZFS, 2026-07-23)

### The one-shot proof

```bash
examples/cdn-edge-ram/demo-cdn-state.sh
# → PASS: cdn-edge: ZFS-backed cache survived the ephemeral-OS reboot and was
#         served by a fresh edge over HTTP
```

Real run (host ZFS module 2.2.2, ubuntu:24.04 zfsutils, nginx):

```
  - edge A: warmed the ZFS cache (index.html + 8 MiB asset), exported the pool
    HTTP-INDEX: cached at the edge BEFORE the reboot
    HTTP-ASSET-SHA: b14304470a20fe4c0ea5a92509410566e544135c306b1034119ae1bea6352504
    EXPECT-ASSET-SHA: b14304470a20fe4c0ea5a92509410566e544135c306b1034119ae1bea6352504
  - edge B: served the surviving cache over HTTP (index text + 8 MiB asset sha match)
PASS: cdn-edge: ZFS-backed cache survived the ephemeral-OS reboot and was served by a fresh edge over HTTP
```

`edge A` and `edge B` are **separate throwaway containers** — B is the "OS after
a reboot": it never wrote the content, it only `zpool import`ed the pool A left
behind and served it. That is the ephemeral-OS + durable-state split.

### Watch it by hand

```bash
# edge A — warm + export:
docker run --rm --privileged -v /dev:/dev -v "$PWD/examples/cdn-edge-ram:/work" cdn-edge-ram bash -c '
  lo=$(losetup --find --show /work/.vdev.img); zpool create -f -m /work/mnt cdnedge "$lo"
  echo hello-edge > /work/mnt/cache/index.html; zpool export cdnedge; losetup -d "$lo"'
# edge B — fresh container, import + serve:
docker run --rm --privileged -v /dev:/dev -v "$PWD/examples/cdn-edge-ram:/work" cdn-edge-ram bash -c '
  lo=$(losetup --find --show /work/.vdev.img); zpool import -d /dev -R /work/altroot cdnedge
  ln -sf /work/altroot/work/mnt/cache /var/www/html; nginx; sleep 1; curl -s localhost/index.html'
```

### Gotchas (learned building this)

- **The ZFS vdev MUST be a loop device inside a container.** The zfs *kernel*
  module runs in the host namespace and opens vdevs by path *there* — a bare
  `/work/vdev.img` (a container-only path) makes `zpool create` fail with the
  misleading `cannot create 'pool': no such pool or dataset`. `losetup --find
  --show <file>` gives a `/dev/loopN` that is identical in both namespaces.
- **Import by label, not path.** After a "reboot" the file may attach to a
  *different* `loopN`; `zpool import -d /dev <pool>` scans device labels and
  finds it regardless. (A symlink directory is *not* scanned — use `/dev`.)
- **Match userland to the host module.** `ubuntu:24.04`'s `zfsutils-linux` is
  2.2.2 — the same as this host's loaded module. A mismatch can refuse pool ops.
- **No sudo needed**: host `/dev/zfs` is world-rw and the module is loaded, so a
  rootful `--privileged` docker container drives real pool ops. The demo uses a
  unique pool name on a file vdev and always `zpool export`/`destroy` +
  `losetup -d`, so it never touches real disks and leaves no host-global pool.
- **Kill/stop by lifecycle verb, not pattern** — `nginx -s stop`, `zpool export`,
  `losetup -d`; containers are `--rm`.

---

## Part 2 — verified RAM-resident edge image  ⏳ author-run

Building the node image needs `sudo debootstrap`, a real ZFS **data disk**, and a
`zfs.ko` for the image's kernel (Debian ships ZFS as DKMS — the spec builds it at
create time). Both halves it composes are verified: the **state model** here in
Part 1, the **verify/rollback boot** in
[`../../netboot/MANUAL_TESTING.md` §13](../../netboot/MANUAL_TESTING.md). The exact
pipeline is in the header of [`cdn-edge-chroot.toml`](cdn-edge-chroot.toml):

```
zpool create (once, on the data disk)  →  create (sudo)  →  export-initrd
  →  sign-payload.sh  →  build-ipxe.sh --imgverify  →  serve  →  boot
```

Success signature once booted: the node's `/init` `modprobe zfs` + `zpool import
-a` (guarded) brings the cache pool up, systemd starts nginx, and
`curl http://<node>/` serves content that was on the pool **before** this boot —
then reboot into a *new* verified image and the cache is still there.

---

## Cleanup

`demo-cdn-state.sh` cleans up on exit: exports/destroys the pool, detaches the
loop device, removes the file vdev. To drop the image:

```bash
docker image rm cdn-edge-ram
```
