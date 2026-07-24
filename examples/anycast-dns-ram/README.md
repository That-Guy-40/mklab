# Anycast DNS on a net-booted, RAM-resident node

A **stateless authoritative-DNS node** that boots its OS **entirely into RAM**
over the network — no disk — and **announces its anycast address via BGP only
while it is actually healthy**, withdrawing the route the instant DNS stops
answering. Reboot the node and it re-pulls the **newest *verified*** image;
update centrally, reboot the fleet, done.

This is the **flagship** of the net-booted RAM-resident infrastructure family
(see [`../../RAM_INFRA_LAB_PLAN.md`](../../RAM_INFRA_LAB_PLAN.md)). It models
**Gandi's** production anycast-DNS design — RAM-booted OS, DNS from RAM,
health-gated BGP — archived byte-exact in
[`upstream-tutorial/`](upstream-tutorial/).

> ## The lessons
> - **Immutable infrastructure.** The node holds no durable OS state, so it is
>   disposable and always current — a reboot *is* the update mechanism. Only the
>   *zone data* is state, and it is externalized, never baked into the image.
> - **Anycast = health-gated routing.** One IP is advertised from many nodes;
>   traffic goes to the nearest one *that is up*. The magic is a node
>   **withdrawing its route when it can't serve** — otherwise anycast would
>   blackhole traffic into a dead node.
> - **"Newest" must mean "newest *verified*".** Booting executable code off the
>   network is a supply-chain surface. The payload is **signed** and the
>   bootloader **refuses anything it can't verify** — closing `AUDIT.md` **F2**.

---

## The two mechanics

| Mechanic | What it proves | Status |
|---|---|---|
| **Health-gated anycast announce** (ExaBGP + Knot + bird2 collector) | Node advertises the anycast VIP *only while DNS answers*; withdraws on failure; re-announces on recovery | ✅ **verified** — [`demo-anycast.sh`](demo-anycast.sh) (podman, no root/QEMU) |
| **Verified RAM boot + A/B rollback** (sign payload → iPXE `imgverify`) | Node boots only a fleet-signed kernel+initrd; a tampered image rolls back / is refused | ✅ **verified mechanism** — [`../../netboot/MANUAL_TESTING.md` §13](../../netboot/MANUAL_TESTING.md) |
| **The Knot-in-RAM node image** ([`anycast-dns-chroot.toml`](anycast-dns-chroot.toml)) | The above two, combined on one real RAM-booted node | ⏳ **author-run** (needs `sudo debootstrap`) |

**Honest scope.** `demo-anycast.sh` proves the announce/withdraw **mechanism**
observed at a real BGP peer — **not** global anycast (one IP live from many
sites, clients steered to the nearest), which needs real multi-site BGP
infrastructure. And the *trust root* here is a **snakeoil** signing key: it
proves the verify/rollback *mechanism and failure mode*, not a real chain — the
production anchor is your fleet's offline/HSM code-signing key.

---

## Architecture

```
                    ┌─────────────────── one RAM-resident node ───────────────────┐
  iPXE (imgverify)  │  /init → systemd → knotd (authoritative DNS, from RAM)       │
  verified A/B boot │                    exabgp ── health.py: dig SOA @localhost   │
  ───────────────►  │                             healthy? announce VIP/32         │
  newest *verified* │                             unhealthy? withdraw VIP/32       │
  kernel+initrd     └───────────────────────────────────┬──────────────────────────┘
                                                         │ BGP
                                              ┌──────────▼───────────┐
                                              │ bird2 route collector │  birdc show route
                                              │  (looking-glass)      │  → VIP appears/vanishes
                                              └───────────────────────┘
```

Part 1 (`demo-anycast.sh`) exercises the **node + collector** as two podman
containers on one network — the fast, sudo-free way to see the health-gate.
Part 2 (`anycast-dns-chroot.toml`) puts that same Knot+ExaBGP stack inside the
**signed initramfs** and boots it for real.

---

## Part 1 — the health-gated anycast demo (verified)

```bash
examples/anycast-dns-ram/demo-anycast.sh
```

Builds the image on first run, then in one shot:

1. starts a **bird2** collector (passive BGP looking-glass) and a **node**
   (Knot + ExaBGP) on a podman network;
2. **healthy** → the collector's `birdc show route` shows `10.89.7.100/32` via
   the node;
3. `knotc stop` (node goes unhealthy) → the route is **withdrawn** — gone from
   the collector;
4. restart Knot → the route **returns**.

One verdict:

```
PASS: health-gated anycast: 10.89.7.100/32 announced while healthy, withdrawn on DNS failure, re-announced on recovery
```

Full transcript + how to watch it live in [`MANUAL_TESTING.md`](MANUAL_TESTING.md).

---

## Part 2 — the verified RAM-resident node image (author-run)

[`anycast-dns-chroot.toml`](anycast-dns-chroot.toml) builds a full systemd Debian
rootfs with the Knot + ExaBGP stack, packed as an initramfs (the initramfs *is*
the root fs — [`../debian-http-boot/`](../debian-http-boot/)'s trick). Its header
carries the exact author-run pipeline: **create → export-initrd → `sign-payload.sh`
→ `build-ipxe.sh --imgverify` → serve → boot**. The verify/rollback half is
proven end-to-end in [`../../netboot/MANUAL_TESTING.md` §13](../../netboot/MANUAL_TESTING.md);
building the image itself needs `sudo debootstrap` (hence author-run here).

State externalization (the OS is ephemeral): the zone data is small and rides in
the verified image for this lab; larger roles mount state from ZFS/iSCSI/NFS —
see the sibling roles in [`../../RAM_INFRA_LAB_PLAN.md`](../../RAM_INFRA_LAB_PLAN.md).

---

## Mitigations / where the boundaries really are

- **Payload signing (F2).** `imgverify` + a fleet code-signing root is the line
  between "reboot pulls newest" and "reboot pulls *newest verified*". Without it,
  whoever controls the boot server controls the fleet.
- **HTTPS transport** adds confidentiality on top (the netboot pipeline's `--tls`);
  `imgverify` is what gives *authenticity* — keep both.
- **Snakeoil keys (F1)** are for the lab only. Real anchor = offline/HSM key.
- **Health-gate correctness** is a routing-safety boundary: a node that fails to
  withdraw on failure blackholes the anycast address.

---

## What's in here

| File | What |
|---|---|
| [`demo-anycast.sh`](demo-anycast.sh) | **verified** health-gated anycast demo (one PASS/FAIL) |
| [`Containerfile`](Containerfile) | node/collector image (Knot + ExaBGP + bird2) |
| [`conf/`](conf/) | `knot.conf` · `example.lab.zone` · `exabgp.conf` · `health.py` · `bird.conf` (sandbox templates) |
| [`anycast-dns-chroot.toml`](anycast-dns-chroot.toml) | the RAM-resident node image spec + author-run verified-boot pipeline |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | verified transcripts + live-watch + reproducers |
| [`upstream-tutorial/`](upstream-tutorial/) | Gandi *Booting an anycast DNS network*, vendored byte-exact |

## Provenance

Built from **Gandi, *Booting an anycast DNS network*** (2019) — vendored in
[`upstream-tutorial/`](upstream-tutorial/). The RAM-root-over-HTTP building block
is [`../debian-http-boot/`](../debian-http-boot/) (Kenneth Finnegan, cited).
Knot DNS, ExaBGP, and bird2 follow **official docs → cite, don't mirror**
(Knot 3.4, ExaBGP 4.2, bird 2.x; retrieved 2026-07-23).
