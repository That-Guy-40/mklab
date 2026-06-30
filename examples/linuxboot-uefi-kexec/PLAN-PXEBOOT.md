# PLAN — LinuxBoot **pxeboot + verified provisioning**

> Status: **DESIGN plan** (pre-implementation). A forward extension of this lab's
> verified Tiers A/B/C + disk finale. Sibling to [`PLAN.md`](PLAN.md) (the original
> three-tier design); this file plans the **network-boot / provisioning** track.
> Decisions captured from the planning session are in §1.

## 1. Context — why

The lab proves "boot Linux to boot Linux" three ways (Tier C `-kernel`, Tier B
OVMF/UEFI+UKI, Tier A coreboot ROM) and a finale where the coreboot ROM's u-root
`boot`s a **local disk's OS** via `kexec`. The natural next capability is the *other*
real LinuxBoot boot policy: **`pxeboot`** — boot/provision an OS **over the network** —
and to harden it into a **strict, signed, HTTPS boot policy**. This turns the lab from
"boot what's here" into "**fetch, verify, and provision an OS from the network, from
the ROM, automatically**" — the actual reason LinuxBoot exists at scale.

**Decisions (planning session):** two OSes from different families = **Rocky 9
(RHEL/kickstart) + Kali (Debian/preseed)**; strict tier = **full System Transparency
(stboot)**; automation = **both** a verified *typed* path and a hands-off *auto* path.

## 2. The load-bearing finding (shapes everything)

- **u-root `pxeboot`** = network boot client: DHCP → fetch a boot config (it parses
  **iPXE *and* PXELINUX** scripts) → fetch kernel+initrd over HTTP/HTTPS → `kexec`.
  The repo **already has** the exact artifact it consumes: `/home/sqs/netboot/boot.ipxe`
  (`#!ipxe … kernel http://10.0.2.2:8181/vmlinuz inst.ks=… ; initrd …; boot`). So
  **u-root `pxeboot` drops in where the iPXE NIC ROM is today** — same script, same
  server, same kickstart/preseed cmdline. Maximum reuse.
- **System Transparency `stboot` is UEFI-only today** — it's a **UEFI executable
  packaged as a UKI** (the very thing our **Tier B** builds with `ukify`); upstream
  says coreboot support "will likely be added in a later release," and the build
  **requires Go 1.23**. ⇒ **Resolution:** the **pxeboot tiers run from the coreboot
  ROM (Tier A)**; **System Transparency runs on the genuine-UEFI / OVMF + UKI path
  (Tier B)** — its *native* deployment model. coreboot-native ST is documented as an
  upstream-future frontier.
- The **Go 1.23** stboot needs is the *same* newer Go that unlocks the **hands-off
  `uinit=pxeboot`** (gated to u-root *main*). One no-sudo Go tarball serves both.

## 3. Boot chains we'll build

```
P1/P2  coreboot ROM ─► Linux + u-root ─► pxeboot ─► DHCP ─► (HTTP|HTTPS) fetch installer
                                                       └─► kexec ─► Rocky Anaconda / Kali d-i ─► AUTO-INSTALL
P3     OVMF/UEFI ─► stboot UKI ─► host_config (net) ─► HTTPS fetch SIGNED OSPKG
                                       └─► verify Ed25519 sigs (≥threshold) vs baked-in root cert
                                            └─► kexec ─► the (signed) Rocky/Kali installer ─► AUTO-INSTALL
```

## 4. Tiers (escalating strictness)

| Tier | Front-end | Policy | Transport | Signing | Verifiable here? |
|---|---|---|---|---|---|
| **P1** | coreboot ROM | u-root `pxeboot` | **HTTP** | none | ✅ fully |
| **P2** | coreboot ROM | u-root `pxeboot` | **HTTPS** (lab CA) | none (TLS only) | ✅ fully |
| **P3** | OVMF/UEFI + UKI | **stboot** (System Transparency) | **HTTPS** | **signed OSPKG** (Ed25519, N-of-M) | ⚠️ mostly; coreboot-native ST = author-run frontier |

Each tier provisions **both** Rocky 9 and Kali (two boot.ipxe / two OSPKGs).

## 5. Reuse map (what we lean on, with paths)

| Need | Reuse | Path |
|---|---|---|
| coreboot ROM + u-root payload | **Tier A** build, extended | `build-coreboot.sh` + `coreboot-qemu-q35-linuxboot.config` |
| add NIC drivers to payload kernel | the **driver-append pattern** already there for disks (§3a of the script) | append `VIRTIO_NET`/`E1000` next to the existing `VIRTIO_BLK`… block |
| UKI / OVMF machinery (hosts stboot) | **Tier B** | `build-uki.sh` (ukify), `run-uefi-linuxboot.sh`, `/usr/share/OVMF/*` |
| RHEL-family installer + kickstart | **rocky-pxe-lab** | `../rocky-pxe-lab/` (fetch script, `.ks`, the `inst.ks=`/`inst.repo=` cmdline) |
| Debian-family installer + preseed | **kali-pxe-lab** | `../kali-pxe-lab/` (`fetch-kali-installer.sh`, `kali-preseed.cfg`, the `preseed/url=` cmdline) |
| HTTP netboot server (`:8181`) | **podman/docker netboot server** | `../podman-netboot-server.toml` / `../docker-examples/docker-netboot-server.toml` (nginx:alpine, `~/netboot` → `:8181`) |
| the iPXE script u-root pxeboot parses | existing **`boot.ipxe`** + builder | `/home/sqs/netboot/boot.ipxe`; `netboot/build-ipxe.sh --server … --append '<cmdline>'` |
| DHCP+TFTP for `pxeboot` | **QEMU slirp** built-in (no dnsmasq) | `-netdev user,tftp=/home/sqs/netboot,bootfile=boot.ipxe`; VM reaches host at `10.0.2.2` |
| serial-drive the u-root shell | **the finale's driver** | `drive-boot.py` (generalize to type `pxeboot`) |
| no-sudo toolchain trick | the lab's deb-extract pattern | mirror for a **Go 1.23 tarball** (`go.dev/dl`, extract, PATH) — needed by ST + hands-off uinit |

## 6. New / changed components (per tier)

**P1 — pxeboot over HTTP, from the coreboot ROM**
- `build-coreboot.sh`: add NIC drivers to the payload kernel (extend the §3a block:
  `CONFIG_VIRTIO_NET=y` + `CONFIG_E1000=y`/`CONFIG_E1000E=y` for the slirp NIC), and add
  **`pxeboot`** to `CONFIG_LINUXBOOT_UROOT_COMMANDS` (currently `"boot coreboot-app"` →
  `"boot coreboot-app pxeboot"`, or `"core boot …"`).
- `fetch-netboot-os.sh` (thin wrapper): call the `rocky-pxe-lab` + `kali-pxe-lab`
  fetchers to stage Rocky's `vmlinuz`/`initrd.img`(+stage2) and Kali's `linux`/`initrd.gz`
  into `~/netboot/`, and render **two** boot.ipxe variants (`boot-rocky.ipxe`,
  `boot-kali.ipxe`) via `build-ipxe.sh` with the reused `inst.ks=` / `preseed/url=`
  cmdlines (pointed at `:8181`).
- `serve-netboot.sh`: bring up the `:8181` nginx container (reuse the podman netboot
  TOML) bind-mounting `~/netboot`.
- `run-coreboot-pxe.sh <rocky|kali>`: raw qemu = `-bios coreboot.rom` +
  `-netdev user,id=n,tftp=$HOME/netboot,bootfile=boot-<os>.ipxe -device virtio-net,netdev=n`
  + serial socket; drive `pxeboot` via `drive-boot.py` (typed). Capture → assert the
  installer kernel boots (Anaconda/d-i banner) and the auto-install starts.
- Reuses the finale's COW-overlay target disk so the install has somewhere to land.

**P2 — pxeboot over HTTPS (lab CA)**
- `make-lab-ca.sh`: generate a lab CA + a server cert for `10.0.2.2`/`netboot.lab`.
- `serve-netboot.sh --tls`: nginx serves `https://…:8181` (or `:8443`) with the cert.
- bake the **lab CA** into the payload (kernel CA keyring and/or a CA bundle in the
  u-root initramfs via `LINUXBOOT_UROOT_FILES`) so u-root `pxeboot` trusts HTTPS;
  flip the boot.ipxe URLs to `https://`. Document the cert-trust gotcha.

**P3 — System Transparency (stboot), the signed/strict tier**
- `fetch-go.sh`: Go 1.23 via no-sudo tarball (also enables hands-off uinit).
- `build-st.sh`: clone System Transparency (`git.glasklar.is/system-transparency` /
  `github.com/system-transparency/stboot`, `stmgr`), build the **stboot UKI** with
  `contrib/stboot/build-stboot <provisioning-URL> keys/rootcert.pem`.
- `make-st-keys.sh`: `stmgr keygen certificate --isCA` → `rootcert.pem`/`rootkey.pem`;
  leaf signing cert/key. (Ed25519.)
- `make-ospkg.sh <rocky|kali>`: wrap the **reused installer** (kernel+initrd+the
  kickstart/preseed cmdline) into an OSPKG —
  `stmgr ospkg create --kernel … --initramfs … --cmdline '…inst.ks=…' --url https://…/os.zip --out os.zip`
  then `stmgr ospkg sign --cert … --key … --ospkg os` → `os.json` + `os.zip`.
- `serve-netboot.sh` also serves the OSPKG (`.json`+`.zip`) over **HTTPS** (with
  `tls_roots.pem` in the trust policy).
- `run-stboot.sh <rocky|kali>`: OVMF + the stboot UKI (reuse the `run-uefi-linuxboot.sh`
  pattern) → stboot fetches the OSPKG over HTTPS, **verifies signatures**, kexecs the
  signed installer. Negative test: tamper a byte / wrong key → **stboot refuses to boot**.
- Document coreboot-native ST as upstream-future (and the edk2-`UefiPayload`-on-coreboot
  chain as the eventual "ST from a coreboot ROM" route).

**Automation (cross-cutting, the "both" decision)**
- *Typed/verified:* `drive-boot.py` types `pxeboot` (P1/P2) — proven mechanism from the
  disk finale; works on the pinned **u-root v0.14.0 / Go 1.22** build.
- *Hands-off:* a second coreboot config building **u-root main on Go 1.23** so
  `CONFIG_SPECIFIC_BOOTLOADER_PXEBOOT` wires **`uinit=pxeboot`** to auto-run at ROM boot
  — zero keystrokes (the genuine "from ROM, fully automated"). Same Go 1.23 ST uses.

## 7. Deliverable file shape (under `examples/linuxboot-uefi-kexec/`)

```
PLAN-PXEBOOT.md            # THIS plan
build-coreboot.sh          # (edit) + NIC drivers, + pxeboot in UROOT_COMMANDS
fetch-netboot-os.sh        # stage Rocky + Kali installers via the pxe-lab fetchers; render 2 boot.ipxe
serve-netboot.sh           # :8181 nginx (reuse podman netboot TOML); --tls for P2/P3
run-coreboot-pxe.sh        # P1/P2: coreboot ROM + slirp DHCP/TFTP/HTTP, drive pxeboot
make-lab-ca.sh             # P2: lab CA + server cert
fetch-go.sh build-st.sh make-st-keys.sh make-ospkg.sh run-stboot.sh   # P3 (System Transparency)
RUNBOOK-pxeboot.md MANUAL_TESTING-pxeboot.md   # (later) by-hand walk + real transcripts
```
(+ 00-INDEX note, README/SHOWCASE "Going further" updates, `link_check` green.)

## 8. Verification (honest split)

- **P1**: from the coreboot ROM, drive `pxeboot` → Rocky **and** Kali installers netboot
  from `:8181` and run their **automated** kickstart/preseed install to the overlay disk.
  Capture serial (Anaconda/d-i banners + "starting automated install"). Also verify the
  **hands-off** (Go 1.23 / u-root main) build auto-runs `uinit=pxeboot`.
- **P2**: same over **HTTPS**; prove plain-HTTP is refused without the CA and HTTPS works
  with the lab CA baked in.
- **P3**: stboot (OVMF) fetches a **signed** OSPKG over HTTPS, verifies, kexecs the
  installer; **negative test** — tampered/unsigned OSPKG is **rejected**. coreboot-native
  ST documented as frontier (author-run / not-in-session).
- `tools/link_check.py` green; reuse the finale's PID-kill + COW-overlay hygiene.

## 9. Risks / open questions

- **u-root main build** (hands-off + Go 1.23) may need pinning/patches — keep the v0.14.0
  typed path as the always-green fallback.
- **HTTPS trust in u-root pxeboot**: confirm whether the CA goes in the kernel keyring vs a
  userspace CA bundle in the initramfs; spike early.
- **ROM/initramfs size**: NIC drivers + CA + extra u-root commands inflate the payload
  (16 MB ROM budget) — watch it, bump `COREBOOT_ROMSIZE` only if needed.
- **System Transparency moving target** (glasklar.is); pin a release (st-1.x) and date it.
- **Provisioning vs install loop**: the OSPKG/iPXE boots an *installer*; ensure the
  kickstart/preseed `reboot`→`poweroff` so we don't reinstall-loop (the galleries already
  patch this — reuse).

## 10. Implementation sequencing (spike-first)

0. Spike: add NIC drivers + `pxeboot`; from the ROM, type `pxeboot`, watch slirp DHCP →
   fetch `boot.ipxe` → kexec **one** installer (Rocky). Gate the rest.
1. P1 both OSes (Rocky+Kali), typed; then the hands-off Go-1.23/main build.
2. P2 HTTPS (lab CA).
3. P3 System Transparency: Go 1.23 → build stboot + stmgr → keys → signed OSPKG
   (wrapping an installer) → OVMF run → verify + negative test.
4. Docs (RUNBOOK/MANUAL_TESTING/SHOWCASE/00-INDEX), vendoring (cite ST + u-root, date-pinned), `link_check`.

## 11. Upstream / vendoring

- **u-root** + **System Transparency** (docs.system-transparency.org, glasklar.is) are
  living multi-page projects → **cite with a retrieved/as-of date, don't mirror**
  (per CLAUDE.md). Pin the ST release (e.g. **st-1.x**) and the u-root commit.
- If a single specific stboot/pxeboot how-to page is followed, vendor *that page*
  byte-exact under `upstream-tutorial/` with provenance + sha256.
