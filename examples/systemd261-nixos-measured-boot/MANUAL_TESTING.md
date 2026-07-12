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

## Spikes E–G — not yet run

See [`PLAN.md`](PLAN.md). Measured boot (swtpm PCRs, `ConditionSecurity=measured-os`),
`RestrictFileSystemAccess=`, the `ConditionFraction=` 3-VM fleet, and TPM2-sealed
LUKS + attestation land here as they are built — each with its captured signature
and the honest swtpm-is-not-a-trust-anchor caveat.
