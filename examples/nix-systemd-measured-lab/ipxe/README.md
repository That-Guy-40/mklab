# iPXE glue — chainloading a UKI

This lab reuses the repo's shared iPXE pipeline
([`netboot/build-ipxe.sh`](../../../netboot/build-ipxe.sh)) but diverges in **one**
place: what iPXE hands control to.

## The one divergence: `chain` a UKI, not `kernel`+`initrd`

The distro-installer PXE labs (`almalinux-pxe-lab/`, `debian-pxe-lab/`) point
iPXE at an installer **kernel + initrd** pair:

```ipxe
kernel ${server}/vmlinuz ...
initrd ${server}/initrd.img
boot
```

A **UKI** (Unified Kernel Image) fuses kernel + initrd + cmdline + `os-release`
into a single signed EFI blob — so there is nothing to `initrd` separately.
[`boot.ipxe`](boot.ipxe) is a one-liner:

```ipxe
chain ${server}/installer.efi
```

That single blob is also what `systemd-stub` measures into **PCR 11** at boot
(Pillar 1) — the UKI is both the deploy unit and the measured unit.

## Files

| File | Purpose |
|---|---|
| [`boot.ipxe`](boot.ipxe) | The `#!ipxe` script served over TFTP; DHCPs then `chain`s the installer UKI. Hand-written (not the `build-ipxe.sh` kernel/initrd template). |
| [`build-boot-rom.sh`](build-boot-rom.sh) | Thin wrapper over `netboot/build-ipxe.sh --sign --use-snakeoil` to produce the signed `ipxe.efi` ROM, then stages `boot.ipxe` into `pxe_dir`. **[YOU-RUN-THIS]** (Docker + qemu-img). |

## The `{MAC}` token

`netboot/build-ipxe.sh` supports a literal `{MAC}` placeholder in `--append`,
rewritten to iPXE's runtime `${mac:hexhyp}` (e.g. `52-54-00-a1-9a-01`). This lab
doesn't need per-MAC kickstarts (the installer UKI is identical for every host —
Nix already fixed the image), so `boot.ipxe` uses only `${netX/mac}` to *print*
the booting NIC's MAC for the console log. Per-machine differences (the canary
tag, the machine-id) are applied **after** install by the fleet harness
([`../vm/run-fleet.sh`](../vm/run-fleet.sh)), not at PXE time.

## Boot chain (UEFI)

```
OVMF firmware → NIC iPXE ROM → (TFTP) boot.ipxe → (HTTP) chain installer.efi
   → installer initrd runs systemd-repart BlockDeviceReplace= → writes slot A
   → reboot → OVMF boots the on-disk UKI from the ESP (measured into PCR 11)
```

See [`../vm/nix-measured-deploy.toml`](../vm/nix-measured-deploy.toml) for the
`backend = "pxe-install"` + `firmware = "uefi"` VM that drives the first half,
and [`../vm/run-measured-vm.sh`](../vm/run-measured-vm.sh) for the swtpm-backed
on-disk boot.
