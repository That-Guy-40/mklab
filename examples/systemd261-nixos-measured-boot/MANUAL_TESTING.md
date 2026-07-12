# MANUAL_TESTING — systemd-261 measured-boot NixOS lab

Verification log, spike by spike. Host: this repo's COLD_STORAGE host (rootless
podman + KVM). Each spike records the exact commands and the **captured** success
signature. See [`PLAN.md`](PLAN.md) for the roadmap and what's still ahead.

---

## Spike B — a Nix-built NixOS UEFI image boots under OVMF (✅ VERIFIED 2026-07-11)

### B.0 — systemd 261 is obtainable, no overlay needed

```
$ nix eval --raw github:NixOS/nixpkgs/nixos-26.05#systemd.version      → 260.2
$ nix eval --raw github:NixOS/nixpkgs/nixos-unstable#systemd.version   → 261
```

**Signature:** stable is 260.2; **`nixos-unstable` ships systemd 261**. The flake
pins `nixos-unstable` — no custom systemd overlay required. `flake.lock` pins the
exact commit (`0bb7ec5`, 2026-07-08).

### B.1 — the image builds (inside nix-build-box, KVM-assisted)

```
$ ./build-nixos-image.sh
--- systemd version baked into this image ---
261
… nixos-disk-image> Number  Start   End     Size    File system  Name   Flags
              1      8389kB  269MB   261MB   fat32   ESP    boot, esp
              2      269MB   4622MB  4353MB  ext4    primary
PASS: image built → out/nixos261.qcow2        # 2.2 GB qcow2
```

The build closure contains `…-systemd-261`, `…-systemd-minimal-261` (grep of the
build log). Kernel params baked in include **`lsm=landlock,yama,bpf`** — BPF-LSM is
on, which Spike D's `RestrictFileSystemAccess=` needs.

### B.2 — it boots under OVMF to systemd 261 (via lab-vm.sh)

```
$ phase2-qemu-vm/lab-vm.sh create --config examples/systemd261-nixos-measured-boot/vm-nixos261-uefi.toml
$ phase2-qemu-vm/lab-vm.sh start  nixos261        # OVMF (OVMF_CODE_4M.fd) + KVM
# drive the serial socket:
BdsDxe: starting Boot0001 "UEFI Misc Device" …
<<< Welcome to NixOS 26.11.20260708.0bb7ec5 (x86_64) - ttyS0 >>>
nixos261 login: root (automatic login)
root@nixos261:~]# grep PRETTY_NAME /etc/os-release; systemctl --version | head -1; uname -sr
PRETTY_NAME="NixOS 26.11 (Zokor)"
systemd 261 (261)
Linux 6.18.38
```

**Signature:** genuine OVMF (`BdsDxe: starting Boot0001`) launches the Nix-built
image to an autologin root shell on `ttyS0`; the running system reports **systemd
261**, kernel 6.18.38.

> **Gotchas found (both fixed / noted):**
> 1. `boot.loader.timeout` — the `qcow-efi` format already pins it to `0`; also
>    setting it → *"conflicting definition values"*. Don't redefine it.
> 2. **Serial-socket capture race.** `lab-vm.sh` wires the serial as a
>    `socket,server=on,wait=off` chardev, which **drops output produced before a
>    client connects**. KVM boot is fast and the autologin shell then sits idle
>    (emits nothing), so a naive reader that *waits to see a prompt* captures zero
>    bytes and looks like a dead VM. The image is fine — you must **drive** the
>    idle shell (send a command; read the reply), or capture from `t=0` with a
>    private `qemu … -serial file:` boot (how B.2's boot log above was obtained).

---

## Spike C — swtpm in lab-vm.sh + measured boot (✅ driver+plumbing VERIFIED 2026-07-11)

### C.1 — the shared-driver change (`phase2-qemu-vm/lab-vm.sh`)

A new opt-in `tpm = true` VM key wires an emulated **TPM 2.0** (swtpm sidecar +
`-tpmdev emulator` + `tpm-crb` on x86_64 / `tpm-tis-device` on aarch64). The
sidecar is started before QEMU and **reaped by recorded PID** (never by pattern —
CLAUDE.md) on `stop`/`destroy`.

```
$ bash phase2-qemu-vm/tests/test-tpm-args.sh
PASS: tpm selector: true → emulated TPM 2.0 (crb) wired; false/unset → none
$ bash phase2-qemu-vm/tests/test-firmware-mode.sh      # regression: my edits didn't break it
PASS: firmware selector: bios → SeaBIOS (no pflash), uefi → OVMF pflash
```

The test is `REGRESSION:`-guarded — an ordinary (`tpm=false`/unset) VM must never
silently acquire a TPM (it would change its measured-boot surface).

### C.2 — the guest gets a working TPM 2.0 (live, via lab-vm.sh)

With `tpm = true` in `vm-nixos261-uefi.toml`, `lab-vm.sh start` launches swtpm and
QEMU; driving the guest shell:

```
VIRT=kvm
TPM: /dev/tpm0 + /dev/tpmrm0, /sys/class/tpm/tpm0, tpm_version_major = 2
PCR7  = 0xB5710BF57D25623E4019027DA116821FA99F5C81E9E38B87671CC574F9281439   (measured, not zero)
systemd-analyze pcrs → 25 PCRs listed
```

On `lab-vm.sh stop`, the swtpm sidecar is **reaped by PID** (verified: pid gone,
`swtpm.sock`/`swtpm.pid` removed).

### C.3 — `ConditionSecurity=measured-os` is correctly NOT-MET (and why)

```
$ systemd-run -p ConditionSecurity=measured-os --wait --quiet /bin/sh -c 'touch /run/mflag'
$ test -e /run/mflag && echo MET || echo NOT-MET      → NOT-MET
# precise reason:
PCR11 = 0x000…000            (the systemd "OS" PCR — never extended)
systemd-pcrphase.service     = inactive / not-found
StubPcrKernelImage EFI var   = absent      → kernel NOT booted via systemd-stub
bootctl … stub:              = (empty)     → plain systemd-boot, no UKI
```

**This is the correct result, not a failure.** The Spike-B image boots a *plain*
systemd-boot kernel+initrd, so nothing measures the OS into PCR 11 and there is no
systemd-measured chain. `measured-os` becomes satisfiable only with a **UKI booted
by `systemd-stub`** (which extends PCR 11) — i.e. the Tier-B UKI/verity image built
in Spike D. So: the swtpm **plumbing** is done and verified here; the measured-os
**gate turns green in Spike D** when the UKI lands. (Honest framing throughout:
swtpm is a software TPM — plumbing, not a trust anchor.)

---

## Spike D — dm-verity + UKI golden image; measured-os MET (✅ 2026-07-11)

Built with `./build-nixos-image.sh --verity` (config: `image/verity.nix`, adapted
from nixpkgs' own boot-tested `appliance-repart-image-verity-store.nix`).

### D.1 — the image builds (systemd 261), structurally verified

```
PASS: verity image built → out/nixos261-verity.qcow2      (~1.3 GB)
# GPT (via fdisk/mtools — libguestfs can't run here):
  p1 ESP  vfat 100M   → /EFI/BOOT/BOOTX64.EFI  = a ~40 MB UKI (removable path)
  p2 "Linux /usr verity"  (type 77ff5f63-… usr-verity)
  p3 "Linux /usr"          (erofs data)
# UKI .cmdline: init=… console=ttyS0,115200 … usrhash=1174ca58…6beafb2b
# PARTUUIDs MATCH the roothash: data=1174ca58-… hash=9f0117f9-…  ✓
```

### D.2 — it boots under OVMF, verity active (via lab-vm.sh + swtpm)

```
device-mapper: verity: sha256 using "sha256-lib"
erofs (device dm-0): mounted with root inode @ nid 36
<<< Welcome to NixOS 26.11.20260708.0bb7ec5 (x86_64) - ttyS0 >>>
nixos261v login: root (automatic login)
# in the guest:
findmnt -no FSTYPE /               → tmpfs           (volatile root)
dmsetup info --target verity usr   → ACTIVE
df --output=source /nix/store      → /dev/mapper/usr (store on dm-verity)
systemctl --version                → systemd 261 (261)
```

> **Gotcha (cost a build cycle):** at `loglevel=4` the image booted *silently* and
> the serial stayed blank — it looked identical to a dead VM. The real cause was a
> stall in the initrd because the appliance initrd lacked the disk/fs drivers to
> read the verity store. Fix in `verity.nix`:
> `boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_scsi" "erofs" ]`
> plus `emergencyAccess = true` + a louder console so a future stall is *visible*.
> A `-kernel`-only probe is misleading here — with no EFI loader info, systemd's
> GPT-auto disk discovery can't run, so it hangs on by-partuuid device units that
> the real OVMF boot resolves fine. Diagnose verityStore under **OVMF**, not `-kernel`.

### D.3 — `ConditionSecurity=measured-os` is now MET (Spike-C seam closed)

```
systemd-analyze condition 'ConditionSecurity=measured-os'   → Conditions succeeded.  (MET)
tpm2_pcrread sha256:11        → 0x1C10E2D1…            (PCR 11 measured, no longer zero)
ls …/efivars | grep StubPcrKernelImage   → present    (booted via systemd-stub UKI)
test -s /run/log/systemd/tpm2-measure.log → present   (stub measurement event log)
```

Contrast Spike C's plain systemd-boot image: PCR 11 = 0, no stub → not measured.
The UKI at the removable ESP path is what `systemd-stub` measures into PCR 11.

> **Method note (corrects Spike C):** the authoritative check is
> `systemd-analyze condition 'ConditionSecurity=measured-os'`. The earlier
> `systemd-run -p ConditionSecurity=… touch /run/mflag` file-flag trick is
> **unreliable** (the transient unit's flag didn't propagate even when the
> condition passed) — don't use it. Spike C's conclusion still holds: that image
> had PCR 11 = 0 and no systemd-stub, so it is definitively not measured.

### D.4 — `RestrictFileSystemAccess=` is NOT available in nixpkgs' systemd 261 (honest gap)

```
systemd-analyze verify <unit with RestrictFileSystemAccess=yes>
  → Unknown key 'RestrictFileSystemAccess' in section [Service], ignoring.
strings …/systemd/systemd | grep -c RestrictFileSystemAccess   → 0
grep dm_verity.require_signatures /proc/cmdline                 → (none)
```

The directive exists in **upstream** systemd 261, but the nixpkgs build shipping in
`nixos-unstable` (commit `0bb7ec5`, 2026-07-08) does **not** compile it in — the
symbol is absent from the PID 1 binary, so the key is silently ignored. It also
requires the kernel booted with `dm_verity.require_signatures=1` + a *signed*
verity chain (this image uses the roothash-on-cmdline model, trusted via the
measured UKI, not kernel-keyring signatures). So the "execute only from signed
dm-verity" enforcement **cannot be demonstrated on this image today**. What IS in
place is the substrate it builds on: a dm-verity-protected `/usr`/store and BPF-LSM
(`lsm=…,bpf`). Enforcement is deferred pending the feature in a nixpkgs systemd
build (or a local systemd override that enables it) + a signed-verity image.

---

## Spike E, Tier A — iPXE → install NixOS to local disk (✅ VERIFIED 2026-07-11)

A real unattended NixOS install over the repo's `pxe-install` backend — the NixOS
analogue of the kickstart/preseed labs. `stage-netboot.sh` builds a **NixOS netboot
installer** (`image/installer.nix`) that auto-partitions `/dev/vda` and runs
`nixos-install`, laying down the target (`image/target.nix`, a BIOS/GRUB minimal
NixOS on systemd 261). **Offline + fast:** the target closure is baked into the
installer initrd (`system.extraDependencies`), so the install is a local store
copy, not a `cache.nixos.org` download.

### E.1 — stage + serve

```
$ ./stage-netboot.sh
PASS: staged → ~/netboot/nixos/{bzImage(13M),initrd(563M)} + ~/netboot/nixos-boot.ipxe
$ phase4-podman/lab-podman.sh up --config …/nixos-pxe-install.toml   # nginx :8181
$ curl -sI http://localhost:8181/nixos/bzImage | head -1            → HTTP/1.1 200 OK
```

`nixos-boot.ipxe` (hand-written; BIOS → QEMU's native iPXE NIC ROM runs it) mirrors
NixOS's generated netboot cmdline **plus `ip=dhcp`** — the slirp DHCP lease iPXE
gets is not inherited by the booted kernel:

```
kernel http://10.0.2.2:8181/nixos/bzImage init=…/init initrd=initrd \
       console=ttyS0,115200 console=tty0 nohibernate root=fstab loglevel=4 \
       lsm=landlock,yama,bpf ip=dhcp
initrd http://10.0.2.2:8181/nixos/initrd
```

### E.2 — install + boot the installed disk (via lab-vm.sh)

```
$ phase2-qemu-vm/lab-vm.sh create --config …/nixos-pxe-install.toml
$ phase2-qemu-vm/lab-vm.sh start  nixos261-pxe
# serial, chronologically:
SeaBIOS: Boot failed: not a bootable disk      → falls through to the NIC iPXE ROM
<<< Welcome to NixOS kexec-… - ttyS0 >>>       → the netboot installer
(journal) === SPIKE-E: partitioning /dev/vda ===   (vda1=2M bios_grub, vda2=20G ext4 "nixos")
(journal) === SPIKE-E: installing the (pre-built, local) target system ===
GNU GRUB version 2.12                          → after reboot, SeaBIOS boots vda → GRUB
nixos261disk login: root (automatic login)     → THE INSTALLED ON-DISK SYSTEM
```

Confirmed the running system is the on-disk install, not the RAM installer:

```
hostname                 → nixos261disk          (target, not "nixos-kexec")
systemctl --version      → systemd 261 (261)
findmnt -no SOURCE /     → /dev/vda2             (on disk, not tmpfs/squashfs)
findmnt -no FSTYPE /     → ext4     ·  lsblk LABEL /dev/vda2 → nixos
```

> **Gotcha (fixed):** the `auto-install` systemd service runs with a **restricted
> PATH** (services don't inherit the interactive PATH), and `nixos-install` shells
> out to `nix-env` → first run failed `nix-env: command not found`. Fix: add
> `config.nix.package` to the service `path`. The partition step had already
> succeeded, which is how the failure was pinpointed from the journal.

### E.3 — Tier B: lay the dm-verity GOLDEN image down over iPXE (✅ VERIFIED 2026-07-12)

The image-based-deploy counterpart: instead of installing package-by-package, dd
the whole **Spike-D dm-verity + UKI golden image** onto disk. UEFI (the image is a
UKI), so it needs UEFI PXE — a **custom `ipxe.efi` built via Nix**
(`pkgs.ipxe.override { embedScript = … }`, no docker) with the deploy boot-script
embedded. `image/deployer.nix` is a tiny netboot deployer that `curl | dd`s the raw
image, registers an NVRAM boot entry, and reboots.

```
$ ./build-nixos-image.sh --verity      # (Spike D golden image)
$ ./stage-netboot.sh --tier-b          # deployer + custom ipxe.efi + golden raw → ~/netboot
$ phase4-podman/lab-podman.sh up   --config …/nixos-pxe-deploy.toml
$ phase2-qemu-vm/lab-vm.sh create  --config …/nixos-pxe-deploy.toml   # UEFI + tpm=true
$ phase2-qemu-vm/lab-vm.sh start   nixos261-deploy
# serial:
BdsDxe: failed to load Boot0001 "UEFI Misc Device" … Not Found   → blank disk
BdsDxe: loading Boot0002 "UEFI PXEv4 (MAC:525400261106)"
iPXE 2.0.0 -- Open Source Network Boot Firmware                  → the custom ipxe.efi
… deployer: curl | dd the golden raw onto /dev/vda … reboot …
systemd-veritysetup-generator … for usr                         → the DEPLOYED disk booting
nixos261v login: root (automatic login)
```

The deployed on-disk system is the **measured** golden image:

```
hostname                 → nixos261v
systemctl --version      → systemd 261 (261)
dmsetup info … verity usr → ACTIVE   ·   df /nix/store → /dev/mapper/usr
systemd-analyze condition 'ConditionSecurity=measured-os'  → MET
lsblk /dev/vda           → vda1 ESP(100M) · vda2 usr-verity(75M) · vda3 usr erofs(1.1G)→/dev/mapper/usr
```

So **both Spike-E tiers are verified**: Tier A installs NixOS package-by-package
(`nixos-install`, BIOS); Tier B lays down a whole **measured, verity-sealed golden
image** (dd, UEFI) — and the deployed disk still satisfies `measured-os`. The
image-based tier needed no `RestrictFileSystemAccess=` to be meaningful — the
verity + measured chain travels with the image.

---

## Spike F — `ConditionFraction=` 3-VM mock fleet (✅ VERIFIED 2026-07-12)

`fleet.toml` boots the plain systemd-261 image as **3 VMs** (`fleet-1/2/3`); each
overlay generates its **own machine-id** at first boot (the image bakes none), so
they form a fleet of distinct nodes. `fleet-demo.sh` sweeps
`systemd-analyze condition 'ConditionFraction=N%'` on each.

> **Syntax gotcha:** `ConditionFraction=` takes a **percentage** — `ConditionFraction=99%`
> → *"succeeded"*. Decimals/ratios (`0.99`, `1/2`, `tag:0.5`) all give *"Invalid
> argument"*. (Unlike `RestrictFileSystemAccess=`, this one **is** in nixpkgs'
> systemd 261 and works.)

```
$ examples/systemd261-nixos-measured-boot/fleet-demo.sh
VM         machine-id   10%   25%   50%   75%   90%
fleet-1    78c6a566      ·     ·     ·     ·     ·
fleet-2    8e35f248      ·     ·    MET   MET   MET
fleet-3    2c09b3ee      ·     ·     ·    MET   MET
included (of 3):          0     0     1     2     2
```

**Signature:** distinct machine-ids; `ConditionFraction=` **partitions the fleet
deterministically** (each node has a fixed threshold from `hash(machine-id)`); and
widening the fraction is **monotonic** — machines only ever *join* (0→0→1→2→2). A
canary rollout ("50% catches fleet-2; widen to 75% adds fleet-3; fleet-1 is the
final cohort") driven entirely from a unit condition, **no external orchestrator**.
A real unit with `ConditionFraction=N%` gates on exactly this evaluation.

---

## Spike G — TPM2-sealed LUKS + attestation stub (✅ VERIFIED 2026-07-12)

> **Honest framing:** the TPM is **swtpm** (`TPM2_PT_MANUFACTURER` = `0x49424D00`
> = `"IBM"`, the emulator's default). This proves the plumbing, **not** that the
> node is trustworthy — see [`RUNBOOK-sealed-luks.md`](RUNBOOK-sealed-luks.md).

### G.1 — the mechanism, live on a measured VM

Driven with `sealed-luks-demo.sh` (host pushes `image/sealed-luks-demo.guest.sh`
over serial). The VM is `tpm=true` and measured (PCR 11 populated), so the seal
binds to real measured state. Run against the Spike-D verity VM (`nixos261v`):

```
$ examples/systemd261-nixos-measured-boot/sealed-luks-demo.sh nixos261v
== systemd 261 — TPM2-sealed LUKS + attestation (measured VM nixos261v) ==
  - TPM manufacturer: 0x49424D00 (0x49424D00='IBM' = swtpm; plumbing, NOT a trust anchor)
  - live PCRs sealing binds to:
      7 : 0xB5710BF57D25623E4019027DA116821FA99F5C81E9E38B87671CC574F9281439
      11: 0x509F86A14845BB390BE430883EC44DE1A1CA6C61EBFDFD633790617BA0B73F5C
  - LUKS2 volume created on /dev/loop0 (keyslot 0 = bootstrap passphrase)
  New TPM2 token enrolled as key slot 1.
  - TPM2 keyslot enrolled, sealed to PCR 7+11 (luks token count: 1)
  - UNSEALED by the TPM against live PCRs — /dev/mapper/sealeddemo opened, zero passphrase
  - attestation: AK-signed PCR 7+11 quote over nonce c3d4cab31ef6… VERIFIED (fresh + TPM-signed)
  -   caveat: this AK is rooted in swtpm's self-made EK — proves 'a TPM signed it', NOT 'genuine hardware'
  - after PCR 11 changed, the TPM REFUSED to unseal — the seal is bound to the measured OS ✅
PASS: TPM2-sealed LUKS: seal→unseal-on-good-PCRs→refuse-on-changed-PCRs, plus a verified AK PCR-quote
```

**Signature:** `systemd-cryptenroll --tpm2-pcrs=7+11` adds a TPM-sealed keyslot;
`systemd-cryptsetup … tpm2-device=auto,headless=true` opens the volume with **no
passphrase**; an AK-signed `tpm2_quote` over PCR 7+11 + a fresh nonce passes
`tpm2_checkquote`; and after `tpm2_pcrextend 11:…` the TPM **refuses** to unseal —
the seal is bound to *what booted*, not to mere possession of a chip.

### G.2 — the sealed golden image builds, boots measured, baked demo PASSes

```
$ examples/systemd261-nixos-measured-boot/build-nixos-image.sh --sealed
… PASS: sealed image built → out/nixos261-sealed.qcow2   (1.3G)

$ phase2-qemu-vm/lab-vm.sh create --config …/vm-nixos261-sealed.toml && lab-vm.sh start nixos261s
# on the guest (driven over serial):
nixos261s
systemd 261 (261)
-rwxr-xr-x 1 root root 5992 … /etc/lab/sealed-luks-demo
  - live PCRs sealing binds to:
      7 : 0xB5710BF57D25623E4019027DA116821FA99F5C81E9E38B87671CC574F9281439
      11: 0x3667A7BE9EE02B40A252FF7D1A77E52A1050871706D5A2CBD240F291E9863B2F
  …
PASS: TPM2-sealed LUKS: seal→unseal-on-good-PCRs→refuse-on-changed-PCRs, plus a verified AK PCR-quote
```

**Signature:** the *shipped* golden image (`image/sealed.nix`) boots as
`nixos261s` on systemd 261; PCR 11 is populated (**measured on its own**); the
baked `/etc/lab/sealed-luks-demo` proves the sealed chain against the image's own
measured state.

### G.3 — Tier-B reuse + declarative `/data` (author-run)

`stage-netboot.sh --sealed` + `nixos-pxe-sealed.toml` deploy the sealed image over
the **identical** custom-`ipxe.efi` → deployer → `dd` → `efibootmgr` path already
verified for the verity image in **E.3** (only the raw filename differs — the
sealed flake outputs evaluate to derivations, confirmed). Realizing the opt-in
`seal-data` `/data` on first boot needs a spare data device + a reboot. Both are
**author-run**; the crypto core they reuse is the mechanism verified in **G.1**.
