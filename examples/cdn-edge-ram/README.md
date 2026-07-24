# CDN edge on a net-booted, RAM-resident node

A **stateless CDN-edge node** whose OS boots **entirely into RAM** over the
network (verified — a reboot re-pulls the newest *signed* image), while its
**cache/content lives on a local ZFS pool that persists across reboots**. The
machine is disposable and always current; the data on it is durable. This is the
**ephemeral-OS + externalized-state** split — the second role in the RAM-resident
infrastructure family (see [`../../RAM_INFRA_LAB_PLAN.md`](../../RAM_INFRA_LAB_PLAN.md)).

> ## The lesson
> "Immutable infrastructure" does **not** mean "no state" — it means the *OS* is
> immutable and disposable while *state* is deliberately externalized. Here the
> line is drawn on the same box: the OS is in RAM (gone on reboot, re-fetched and
> re-verified), the cache is on a **ZFS pool on a local disk** (untouched by the
> reboot). Reboot to update the OS; the warm cache survives.

---

## Mechanics

| Mechanic | What it proves | Status |
|---|---|---|
| **ZFS state survives an ephemeral-OS reboot** | Warm the cache, "reboot" into a *fresh* OS, and it serves the **same** cached content — imported, not re-fetched | ✅ **verified** — [`demo-cdn-state.sh`](demo-cdn-state.sh) (docker + host ZFS; no root/QEMU) |
| **Verified RAM boot + A/B rollback** (mechanic ①) | The ephemeral OS only boots a fleet-signed image; a bad build rolls back / is refused | ✅ **verified mechanism** — [`../../netboot/MANUAL_TESTING.md` §13](../../netboot/MANUAL_TESTING.md) |
| **The CDN-edge node image** ([`cdn-edge-chroot.toml`](cdn-edge-chroot.toml)) | Both, combined on one real RAM-booted node with a ZFS data disk | ⏳ **author-run** (needs `sudo debootstrap` + a data disk + a zfs.ko for the image's kernel) |

**Honest scope.** `demo-cdn-state.sh` proves the **state model** — ephemeral OS,
durable ZFS cache, served over HTTP after a reboot. It is **not** a real CDN
(no origin pull, cache eviction, or geo-steering); the point is the persistence
boundary. The verify half uses **snakeoil** signing keys (mechanism, not a real
anchor).

---

## Part 1 — the state-survives-reboot demo (verified)

```bash
examples/cdn-edge-ram/demo-cdn-state.sh
```

1. **edge A** creates a ZFS pool on a file-backed loop vdev, warms the cache
   (an `index.html` + an 8 MiB asset), and **exports** the pool;
2. **edge B** — a *fresh* container (the ephemeral OS after a reboot) — **imports**
   the pool by label, points **nginx** at it, and serves the cached content;
3. the demo verifies the served `index.html` text **and** the 8 MiB asset's
   sha256 match what edge A wrote **before** the reboot.

One verdict:

```
PASS: cdn-edge: ZFS-backed cache survived the ephemeral-OS reboot and was served by a fresh edge over HTTP
```

It uses the host's live ZFS (`/dev/zfs`, module 2.2.2) via a rootful
`--privileged` container — **no sudo, no QEMU**. It uses a unique pool name on a
file vdev and always exports/destroys, so it never touches real disks and leaves
no host pool. Details + gotchas in [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

---

## Part 2 — the verified RAM-resident edge image (author-run)

[`cdn-edge-chroot.toml`](cdn-edge-chroot.toml) builds a systemd Debian rootfs
(nginx + ZFS) packed as an initramfs, with a `/init` that mounts the virtual
filesystems, **imports the cache pool (`||`-guarded** so a first boot with no
pool can't panic PID 1 — see CLAUDE.md), then hands off to systemd. Its header
carries the full author-run pipeline: **one-time `zpool create` on the data disk
→ create → export-initrd → `sign-payload.sh` → `build-ipxe.sh --imgverify` →
serve → boot**. Building it needs `sudo debootstrap`, a data disk, and a zfs.ko
for the image's kernel (Debian ships ZFS as DKMS — the spec builds it at
create time). The two halves it composes are each verified above.

---

## Where the boundaries are

- **State durability** is the ZFS pool, not the OS. Losing the OS (reboot, bad
  image) costs nothing; the cache is intact.
- **Payload signing (F2)** is what makes "reboot pulls newest" safe — the edge
  only runs a fleet-signed OS. Snakeoil keys here; real anchor = offline/HSM key.
- **`||`-guard the state mount.** An unguarded `mount`/`zpool import` in `/init`
  (which runs `set -e`) panics PID 1 on the first boot before the pool exists.

## What's in here

| File | What |
|---|---|
| [`demo-cdn-state.sh`](demo-cdn-state.sh) | **verified** ZFS-cache-survives-reboot demo (one PASS/FAIL) |
| [`Containerfile`](Containerfile) | edge image (ubuntu:24.04 — zfsutils matches the host module — + nginx) |
| [`cdn-edge-chroot.toml`](cdn-edge-chroot.toml) | the RAM-resident edge image spec + author-run pipeline |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | verified transcript + gotchas + reproducers |

## Provenance

The **ZFS-backed persistent-state on an otherwise-ephemeral node** pattern
follows the design named in [`../../RAM_INFRA_LAB_PLAN.md`](../../RAM_INFRA_LAB_PLAN.md)
(§4b) and modeled on Gandi's RAM-boot design (vendored in the flagship
[`../anycast-dns-ram/upstream-tutorial/`](../anycast-dns-ram/upstream-tutorial/)).
ZFS on Linux and nginx follow **official docs → cite, don't mirror**
(OpenZFS 2.2, nginx; retrieved 2026-07-23). The RAM-root-over-HTTP building block
is [`../debian-http-boot/`](../debian-http-boot/).
