# POC-PXEBOOT-P3 — System Transparency: boot only a SIGNED OS, verified vs a lab CA

> **Status: PROVEN, positive + negative, on genuine UEFI (OVMF)** (Ubuntu 24.04 + QEMU
> 8.2.2 / KVM). A from-source **stboot** bootloader, running as PID 1 in a UKI that OVMF
> launches, fetches an AlmaLinux installer packaged as a **System Transparency OS package
> (OSPKG)** over **HTTPS**, verifies the package's **Ed25519 signature against a root baked
> into its initramfs** (the shared [`examples/lab-ca`](../lab-ca/README.md)), and only then
> `kexec`s it — and a **rogue-signed package is refused**. P3 of
> [`PLAN-PXEBOOT.md`](PLAN-PXEBOOT.md). P1 (HTTP) is [`POC-PXEBOOT.md`](POC-PXEBOOT.md);
> P2 (HTTPS transport) is [`POC-PXEBOOT-P2.md`](POC-PXEBOOT-P2.md).

## What P3 adds over P1/P2

P1 fetched an installer over HTTP; P2 verified the **transport** (HTTPS against the lab
CA). P3 verifies the **artifact itself**: the thing being booted is a *signed* OS package,
and the bootloader refuses anything not signed by a trusted key. That is the whole thesis
of [System Transparency](https://www.system-transparency.org/) — a machine boots *only*
operating systems whose provenance it can cryptographically check.

**Why this runs on OVMF, not the coreboot ROM.** `stboot` is a **UEFI executable packaged
as a UKI** — exactly what the lab's **Tier B** already builds (`ukify`) and boots under
OVMF. So P3 uses stboot's *native* deployment model. Booting stboot *from a coreboot ROM*
(via an edk2 UEFI payload) is the documented stretch frontier **P3b** (§2/§6 of the plan).

## The pieces (all built from source, no sudo)

| Piece | How |
|---|---|
| **stmgr / stboot** | cloned at `v0.7.0` from git.glasklar.is, built with the lab's Go 1.25 (`GOTOOLCHAIN=local`); `stboot` is `CGO_ENABLED=0` **static** so it can be PID 1 (`build-st.sh`) |
| **stboot kernel** | the AlmaLinux pxeboot **EFISTUB** vmlinuz (same kernel Tier B boots), + **`e1000.ko`** extracted from its initrd (u-root's `libinit` flat-loads it and decompresses the `.xz`) |
| **trust policy** | `/etc/trust_policy/{trust_policy.json, ospkg_signing_root.pem, tls_roots.pem}` baked into the stboot initramfs; both roots are the **one shared `lab-ca.crt`** (the §6b payoff) |
| **host config** | `/etc/host_configuration.json` — **static** IP `10.0.2.15/24` (see gotcha #1), OSPKG pointer `https://10.0.2.2:8443/stboot-ospkg.json` |
| **OSPKG** | `stmgr ospkg create` wraps the **same** installer kernel+initrd+cmdline as P1/P2 (from `boot-<os>.ipxe`); `stmgr ospkg sign` signs it with the **lab-CA Ed25519 leaf** (`make-ospkg.sh`) |
| **server** | `serve-netboot.sh --tls` (rootless nginx :8443, lab-CA server cert) serves the `.json`+`.zip`; :8181 still serves the installer's own stage2/kickstart |
| **run** | `run-stboot.sh <os> [--negative]` — OVMF + the stboot UKI, capture serial, read the verdict |

One stboot UKI is **OS-agnostic** (fixed OSPKG URL); `make-ospkg.sh <os>` decides which
installer that URL resolves to — the same "one artifact, any OS" property as the P1 ROM.

## Positive — verified on OVMF (AlmaLinux 9.8)

`./build-st.sh` once, then `./run-stboot.sh alma`:

```
stboot: Reading "/etc/trust_policy/ospkg_signing_root.pem", cert #0 expires at: 2036-...
stboot: Reading "/etc/trust_policy/tls_roots.pem",         cert #0 expires at: 2036-...
stboot: eth0: IP configuration successful                        ← static 10.0.2.15/24
stboot: Loading OS package via network
stboot: Downloading "https://10.0.2.2:8443/stboot-ospkg.json"    ← TLS verified vs lab-ca
stboot: Validating descriptor
stboot: Downloading "https://10.0.2.2:8443/stboot-ospkg.zip"
stboot: Signatures: 1 found, 1 valid, 1 required                 ← Ed25519 sig vs lab-CA root
stboot: OS package passed verification
stboot: Handing over control - kexec
Welcome to AlmaLinux 9.8 (Olive Jaguar)!
anaconda ... for AlmaLinux 9.8 started.
Starting automated install.
```

The signature verified, the package passed, and stboot `kexec`'d straight into the
unattended AlmaLinux install — a signed boot, end to end.

## Negative — a rogue-signed package is refused

`./run-stboot.sh alma --negative` re-signs the OSPKG with a **throwaway Ed25519 cert that
does not chain to the lab CA**, boots the same UKI:

```
stboot: Loading OS package via network
stboot: Downloading "https://10.0.2.2:8443/stboot-ospkg.json"
stboot: Downloading "https://10.0.2.2:8443/stboot-ospkg.zip"
stboot: skip signature 1: invalid certificate: x509: certificate signed by unknown authority
stboot: Verifying OS package: not enough valid signatures: 1 found, 0 valid, 1 required
stboot: booting configured OS package failed: boot failed
stboot: Recover ...
```

stboot refused the package (its cert does not chain to the trusted root), booted nothing,
and dropped into recovery — verification is **real**, not skip-verify.

## Gotchas discovered (each cost a boot cycle — captured so you don't repeat them)

1. **stboot's DHCP is dead over QEMU slirp — use `network_mode: static`.** stboot's
   `dhcp` mode calls `github.com/u-root/u-root/pkg/dhclient` — the *exact* client whose
   AF_PACKET broadcast emits **0 packets** over slirp (the P1 blocker). P1 dodged it with
   kernel `ip=dhcp`, but stboot configures the NIC itself in Go userspace (no kernel-cmdline
   escape hatch). Its **static** path (`configureStatic`) is pure netlink (`AddrAdd`+`IfUp`+
   `RouteAdd`, no DHCP send) and works over slirp exactly like a manual `ip addr add`. So the
   host config is static `10.0.2.15/24`, gw `10.0.2.2`.
2. **The signing leaf must NOT carry `codeSigning`-only EKU.** stboot's `descriptor.Verify`
   builds `x509.VerifyOptions` with **`KeyUsages` unset**, so Go x509 defaults to requiring
   **`ExtKeyUsageServerAuth`** on the leaf. A `codeSigning`-only leaf is rejected with
   *"x509: certificate specifies an incompatible key usage"*. Fix: mint the leaf with **no
   EKU extension** (Go treats no-EKU as valid for any usage). `issue-signing-cert.sh` was
   updated accordingly (the root has no EKU either, so the chain is unconstrained).
3. **A mixed chain is fine: ECDSA root → Ed25519 leaf.** The shared `lab-ca.crt` is an
   **ECDSA P-256** root; the OSPKG signing leaf is **Ed25519** (what ST requires for the
   signature). stboot's x509 verify accepts the ECDSA-CA-signs-Ed25519-leaf chain — so the
   *one* lab root anchors both the TLS transport and the artifact signature.
4. **`stmgr ospkg create` writes the package `0600` → rootless nginx returns 403.** The
   containerized nginx user can't read owner-only files. `make-ospkg.sh` `chmod 0644`s the
   `.zip`+`.json` after signing (a `403` on the OSPKG but `200` on `vmlinuz` is the tell).
5. **e1000 over virtio-net.** u-root's `libinit.InstallAllModules` flat-loads every `.ko`
   in `/lib/modules` (decompressing `.xz` itself). `e1000` is a single module with no
   loadable deps; `virtio_net` needs a `virtio`/`virtio_ring`/`virtio_pci` chain that the
   flat loader can misorder. So the VM gets an `-device e1000` NIC.

## Scope — what P3 verifies (and what it doesn't)

P3 verifies the **OS package** the machine boots: signature (Ed25519, threshold ≥1) **and**
transport (HTTPS vs the lab CA). The kexec'd installer's *own* later downloads — Anaconda's
`inst.stage2`/`inst.ks` — still ride plain **http :8181** (same split as P2; teaching
Anaconda/d-i to trust the lab CA is a separate distro exercise). What stboot hands control
to is a **verified** kernel+initramfs; the userspace install that follows is out of scope.

## Files

| File | Role |
|---|---|
| [`build-st.sh`](build-st.sh) | build stmgr+stboot from source; assemble the OS-agnostic stboot UKI + ESP (lab-CA trust policy) |
| [`make-ospkg.sh`](make-ospkg.sh) | wrap the P1/P2 installer into an OSPKG + sign with the lab-CA leaf (`--rogue` = negative) |
| [`run-stboot.sh`](run-stboot.sh) | OVMF-boot the stboot UKI; positive verdict, or `--negative` refusal |
| [`fetch-go.sh`](fetch-go.sh) | Go 1.25 (shared with u-root main; ST needs ≥1.24) |
| [`../lab-ca/`](../lab-ca/README.md) | shared root CA — `issue-signing-cert.sh` (OSPKG leaf) + `issue-server-cert.sh` (TLS leaf) |
| [`serve-netboot.sh`](serve-netboot.sh) | `--tls` nginx :8443 serves the signed OSPKG |

## Upstream

[System Transparency](https://docs.system-transparency.org/) — `stboot`/`stmgr` **v0.7.0**,
git.glasklar.is/system-transparency/core, retrieved **2026-07-02**. Living multi-page
project → cited + date-pinned, not mirrored (per CLAUDE.md).
