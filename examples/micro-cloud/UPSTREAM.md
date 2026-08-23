# Upstream sources — cite, don't mirror

This lab operationalizes **Firecracker's official documentation and upstream code**, not a
single blog post. Per the repo's provenance rule that puts it in the **cite-don't-mirror**
tier — like [`zfsbootmenu-boot-environments/UPSTREAM.md`](../zfsbootmenu-boot-environments/UPSTREAM.md)
— so there is no `upstream-tutorial/` here and these citations *are* the record.
Plan reference: [`MICRO_CLOUD_LAB_PLAN.md` §12](../../MICRO_CLOUD_LAB_PLAN.md#12-provenance--and-the-hand-walk-now-proven).

**Retrieved / as-of: 2026-08-23.** Every URL below was fetched and returned **HTTP 200** on
that date, from this host, before it was written down. That check is the point: the repo has
already enshrined an error page's `sha256` as "the tutorial" once, and a citation nobody
resolved is a claim, not a record.

## The pinned artifact

| | |
|---|---|
| Version pinned by the lab | **v1.16.1** (`FC_PINNED_VERSION` in [`phase7-firecracker/lab-fc.sh`](../../phase7-firecracker/lab-fc.sh)) |
| Release page | <https://github.com/firecracker-microvm/firecracker/releases/tag/v1.16.1> |
| Staged copy this host measured | `~/.local/state/lab-create/micro-cloud-s3/firecracker` |
| `--version` says | `Firecracker v1.16.1` |
| **sha256 of the staged binary** | `2fd0171309af7e24cf8dafc8a6f921c1434c49b5f9349bb996b7ed0a4deb8aa7` |

> **What that digest is and is not.** It is the sha256 of the binary **on this host on
> 2026-08-23**, computed from the bytes, not copied from anywhere. It is **not** a claim
> about what upstream publishes: the release's own `.sha256` file was not re-fetched and
> compared here, so treat this as *"the thing these transcripts ran against"* rather than
> *"the authentic upstream artifact"*. Binding it to its subject is the whole point — a
> version string is not an identity, and two builds of one release print the same
> `--version`. `lab-fc.sh preflight` compares the version; nothing yet compares this digest.
> Closing that is [`DEFERRED.md`](DEFERRED.md) item 4, which is where the fetch-and-verify
> step is already written down.

## Documentation cited (all HTTP 200 on 2026-08-23)

| What this lab took from it | URL |
|---|---|
| **Getting started** — the API-driven boot this lab's first RUNBOOK follows by hand | <https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md> |
| **Network setup** — tap-per-VM, the model `fabric.sh` implements with a bridge and NAT | <https://github.com/firecracker-microvm/firecracker/blob/main/docs/network-setup.md> |
| **Jailer** — chroot + uid/gid drop; the isolation tier in §5.6 | <https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md> |
| **MMDS user guide** — the metadata service, and why v2 needs a PUT for a token | <https://github.com/firecracker-microvm/firecracker/blob/main/docs/mmds/mmds-user-guide.md> |
| **Snapshotting** — snapshot/restore and the clone hazards §5.8 is about | <https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md> |
| **The API spec** (swagger) — the authority for every verb `lab-fc.sh` issues | <https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/src/firecracker/swagger/firecracker.yaml> |
| Project home / docs index | <https://firecracker-microvm.github.io/> |

## What this lab adapted, one line each

- **Boot over the API rather than `--config-file` alone.** Upstream shows both; this lab
  needs the API because pause, `snapshot/create` and `snapshot/load` are **API-only** —
  the finding that unblocked slice 8 was `--no-api`, not a missing verb.
- **A tap per VM, named from the instance.** Upstream's network-setup describes one tap; the
  fabric derives the MAC **from the name** so that two tools cannot disagree about a node's
  identity, which they had for three slices.
- **Jailer staged paths are relative to the new chroot.** Upstream says so; §5.6's sharp edge
  is that this means staging the kernel and rootfs *inside* the jail and writing a second
  in-chroot config.
- **A snapshot carries memory, devices AND the disk from one pause.** Upstream documents the
  parts; the lab's rule — restore over a rootfs that moved on is corruption with a clean exit
  code — is the operational consequence, enforced by refusing a changed snapshot by digest.
- **MMDS v2 needs a PUT to get a token**, which `busybox wget` cannot issue; the lab uses
  `nc`. That is a divergence from every example that assumes `curl` is present.

## Not vendored, deliberately

No page here is archived byte-exact. Firecracker's docs are a multi-page site tracking
upstream code, which is the repo's stated boundary for citing rather than mirroring: an
archive would be a second copy that starts drifting the day it is written, and the digest
above already binds the thing that actually matters — the binary these transcripts ran
against.
