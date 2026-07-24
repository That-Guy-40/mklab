# Package mirror on a net-booted, RAM-resident node

A **stateless package-mirror node** whose OS boots **entirely into RAM** over the
network (verified — a reboot re-pulls the newest *signed* image), while the
**multi-GB Debian mirror tree lives on separate network storage** (NFS or iSCSI)
and is mounted at boot. The tree is far too big to ship in the image, so the
image stays tiny and the OS stays ephemeral; the mirror data lives on a storage
server that outlives any node. Third role in the RAM-resident infrastructure
family (see [`../../RAM_INFRA_LAB_PLAN.md`](../../RAM_INFRA_LAB_PLAN.md) §4c).

> ## The lesson
> The externalized state doesn't have to be a *local* disk (that's the
> [`../cdn-edge-ram/`](../cdn-edge-ram/) ZFS role) — it can be **network** block
> or file storage. A stateless node too small to hold the data mounts it from
> elsewhere at boot: NFS (file) or iSCSI (block). The image is tiny and
> disposable; the mirror is big and durable, on its own server.

---

## Mechanics

| Mechanic | What it proves | Status |
|---|---|---|
| **Guarded network-state mount** (`state-mount.sh`) | The mirror mount is `\|\|`-guarded — a missing/unreachable store serves an empty tree instead of **panicking PID 1**; a working store is mounted | ✅ **verified** — [`tests/test-state-mount-guard.sh`](tests/test-state-mount-guard.sh) (host-only, no docker/root) |
| **Verified RAM boot + A/B rollback** (mechanic ①) | The ephemeral OS only boots a fleet-signed image | ✅ **verified mechanism** — [`../../netboot/MANUAL_TESTING.md` §13](../../netboot/MANUAL_TESTING.md) |
| **The live NFS/iSCSI mirror mount + node image** ([`package-mirror-chroot.toml`](package-mirror-chroot.toml)) | The mirror is mounted from a real storage server and served | ⏳ **author-run** (see below) |

**Why the live mount is author-run (honest).** Exercising a real NFS or iSCSI
mount touches **host-global kernel state** — the kernel NFS server, the iSCSI
initiator's global session table — and this project's dev host is *itself*
serving NFS. Unlike the ZFS role (whose pool ops are cleanly isolated on a file
vdev), a live network-storage round-trip can't be safely sandboxed here without
risking the host, so it is **author-run** with ready-to-run recipes below. What
*is* cleanly verifiable — the load-bearing **`||`-guard** invariant that keeps a
bad mount from panicking `/init` — is proven docker-free by the unit test.

---

## Part 1 — the guarded state-mount (verified)

```bash
examples/package-mirror-ram/tests/test-state-mount-guard.sh
# → PASS: state-mount.sh: network-storage mount is ||-guarded (failures never
#         panic /init), success mounts, idempotent
```

[`state-mount.sh`](state-mount.sh) is what `/init` calls to attach the mirror. Its
whole point is that it **always exits 0**: under `/init`'s `set -e` an unguarded
failing mount (unreachable store, first boot before the target exists, an
already-mounted tree) would panic PID 1 (CLAUDE.md: *"set -e panics PID 1"*). The
test stubs `mount`/`iscsiadm`/`mountpoint` and proves: a failed NFS mount → exit
0 + WARN; a good mount → a real `mount -t nfs4 …`; a failed iSCSI attach → exit 0;
already-mounted → no re-mount. A degraded edge serving an empty tree beats a
kernel panic — the mount retries next boot.

---

## Part 2 — the RAM-resident mirror node image + live storage (author-run)

[`package-mirror-chroot.toml`](package-mirror-chroot.toml) builds a systemd Debian
rootfs (nginx + `nfs-common` + `open-iscsi`) whose `/init` runs `state-mount.sh`
then hands off to systemd. Its header carries the full pipeline: **stand up the
storage → create → install `state-mount.sh` → export-initrd → `sign-payload.sh`
→ `build-ipxe.sh --imgverify` (state config on the kernel cmdline) → serve →
boot**. The reset config is passed as `--append "STATE_KIND=nfs
STATE_SRC=server:/srv/mirror"` (or `STATE_KIND=iscsi ISCSI_PORTAL=… ISCSI_TARGET=…`).

The two live storage recipes (NFS via **nfs-ganesha**, iSCSI via **tgt**) are in
[`MANUAL_TESTING.md`](MANUAL_TESTING.md). The verify/rollback boot half is proven
in [`../../netboot/MANUAL_TESTING.md` §13](../../netboot/MANUAL_TESTING.md).

---

## Where the boundaries are

- **The mirror is not on the node.** Losing a node (reboot, bad image) costs
  nothing; the mirror is on its storage server. This is the point of the split.
- **`||`-guard the mount.** The single most important correctness property — an
  unguarded mount in `/init` panics PID 1. Verified in Part 1.
- **Read-only, `soft` mounts.** `state-mount.sh` mounts the mirror `ro` and (NFS)
  `soft` so a flaky storage server degrades the node instead of hanging it.
- **Payload signing (F2)** keeps "reboot pulls newest" safe (snakeoil keys here;
  real anchor = offline/HSM key).

## What's in here

| File | What |
|---|---|
| [`state-mount.sh`](state-mount.sh) | the **`\|\|`-guarded** network-state mount (NFS/iSCSI) `/init` calls |
| [`tests/test-state-mount-guard.sh`](tests/test-state-mount-guard.sh) | **verified** host-only guard test (one PASS/FAIL) |
| [`package-mirror-chroot.toml`](package-mirror-chroot.toml) | the RAM mirror-node image spec + author-run pipeline |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | the live NFS (ganesha) + iSCSI (tgt) recipes, author-run |

## Provenance

Follows the design named in [`../../RAM_INFRA_LAB_PLAN.md`](../../RAM_INFRA_LAB_PLAN.md)
(§4c), modeled on Gandi's RAM-boot design (vendored in the flagship
[`../anycast-dns-ram/upstream-tutorial/`](../anycast-dns-ram/upstream-tutorial/)).
NFS-Ganesha, tgt/open-iscsi, apt-mirror and nginx follow **official docs → cite,
don't mirror** (retrieved 2026-07-23). RAM-root building block:
[`../debian-http-boot/`](../debian-http-boot/).
